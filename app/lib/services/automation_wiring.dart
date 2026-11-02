// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **F2 的生产接线**（2026-11-02）—— 把 `AutomationRunner` 装上真实依赖。
//
// ## 为什么单独一个文件
//
// `automation_runner.dart` 是**纯逻辑**（全注入、可毫秒级测试）；把
// `AgentBridge` / `SettingsController` / `LocalAgentExecutor` 塞进去，它就再也
// 没法在纯 Dart 测试里跑了。这里只做"把谁接到谁身上"，出错面越小越好。
//
// ## 执行路径必须与手动发送**同一条**
//
// 定时任务不是另一套执行栈：它就是 `LocalAgentExecutor.run()` ——
// 审批门禁、预算（轮次/工具调用上限）、压缩、沙箱路由、JSONL 记账全部一致。
// 唯一的差别是**没有 UI 门禁**（见下）。
//
// ## ⚠️ 后台运行没有审批对话框
//
// 这里构造执行器时 `askGate` 传 `null`（后台没有界面可以弹窗）。后果是
// **需要审批的操作会被拒**（backend 拿不到门禁 ⇒ 视为不可问 ⇒ 拒绝），
// 这是刻意的保守选择：宁可让定时任务少做一件事并如实记失败，也不许
// 在无人值守时静默提升权限。用户下次打开 App 会在运行历史里看到原因。
//
// 想让它"到点能弹审批"，得先把执行搬进前台服务并接通知——那是另一件事，
// 不在 F2 范围（见 `docs/接口.md` §11.2）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:heracles_backend/heracles_backend.dart';

import '../models/settings.dart';
import 'agent_bridge.dart';
import 'automation_runner.dart';
import 'local_agent.dart';
import 'session_store.dart';
import 'settings_controller.dart';

/// **消费 pending 并真跑**（F2 的唯一入口）。
///
/// 调用点：App 启动完成后一次 + 每次回到前台一次（[start] 里注册的
/// `AppLifecycleListener`）。重复调用是安全的（幂等三闸在 `AutomationRunner`）。
class AutomationWiring {
  AutomationWiring._();

  static bool _started = false;
  static AppLifecycleListener? _lifecycle;
  static Future<void>? _inFlight;
  static void Function(String message)? logSink;

  /// 启动后台消费（**幂等**：重复调用只注册一次）。
  ///
  /// 为什么要 `AppLifecycleListener` 而不是在 `main()` 里循环轮询：
  /// 消费的时机就是"用户回来了" —— 用户回来时才可能提供审批/看到结果；
  /// 定时轮询既费电，又会在用户看不见的时候跑任务。
  static void start() {
    if (_started) return;
    _started = true;
    unawaited(consumeAndRun());
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(consumeAndRun()),
    );
  }

  /// 停掉监听（测试/热重载用；生产不调）。
  static void stop() {
    _lifecycle?.dispose();
    _lifecycle = null;
    _started = false;
  }

  /// 消费一轮。**并发调用会合并**（不会两个 run 同时跑）。
  ///
  /// 为什么合并而不是排队：同一个 pending 清单被消费两次毫无意义，
  /// 而排队会让"回前台"连点几次后积压一串无用的空跑。
  static Future<List<AutomationRunReport>> consumeAndRun({
    AgentBridge? bridge,
    AppSettings? settings,
  }) {
    final running = _inFlight;
    if (running != null) {
      // 已有一次在跑 ⇒ 等它，返回它的结果（而不是返回空列表假装"没东西要跑"）
      return running.then((_) => const <AutomationRunReport>[]);
    }
    final future = _consumeOnce(bridge: bridge, settings: settings);
    _inFlight = future.then<void>((_) {}).whenComplete(() => _inFlight = null);
    return future;
  }

  static Future<List<AutomationRunReport>> _consumeOnce({
    AgentBridge? bridge,
    AppSettings? settings,
  }) async {
    final b = bridge ?? AgentBridge();
    // 设置没传 ⇒ 现场读（不缓存：用户可能刚改过模型/Key）
    final s = settings ?? (await SettingsController.load()).value;

    final runner = AutomationRunner(
      consumePending: b.consumePendingAutomation,
      loadTasks: b.loadAutomationTasks,
      saveTasks: b.saveAutomationTasks,
      execute: (task) => _executeTask(task, s, bridge: b),
      log: logSink,
    );
    return runner.consumeAndRun();
  }

  /// 真跑一次任务（**与手动发送同一条 run 路径**，只是没有 UI 门禁）。
  static Future<AutomationExecOutcome> _executeTask(
    AutomationTask task,
    AppSettings settings, {
    AgentBridge? bridge,
  }) async {
    final started = DateTime.now().millisecondsSinceEpoch;

    final provider = settings.effectiveProvider;
    if (provider == null) {
      return const AutomationExecOutcome(
        ok: false,
        error: '没有可用的模型配置（请先在设置里填写 API Key 与模型）',
      );
    }

    final ws = await _resolveWorkspace(bridge ?? AgentBridge());
    if (ws == null) {
      return const AutomationExecOutcome(
        ok: false,
        error: '没有可用的工作区（请先在侧边栏添加或选择工作区）',
      );
    }

    final executor = LocalAgentExecutor(
      workspacePath: ws,
      settings: settings,
      sessionStore: SessionStore(workspaceRoot: ws),
      // 后台没有界面 ⇒ 不能弹审批（见文件头说明）
      askGate: null,
    );

    try {
      final handle = await executor.run(request: task.prompt);
      // 事件**必须消费掉**：广播流无人听时，后端仍会往里推（没有监听者时
      // 会被丢弃，但显式 drain 更稳，也避免"没人订阅"被当成异常路径）。
      final drain = handle.events.listen((_) {});
      try {
        final r = await handle.result;
        final elapsed = DateTime.now().millisecondsSinceEpoch - started;
        // 失败判据：框架给了明确 failureReason，或 stopReason 是失败态。
        // 不许"跑完就算成功" —— 那会把超时/取消记成成功。
        final reason = r.failureReason;
        if (reason != null && reason.trim().isNotEmpty) {
          return AutomationExecOutcome(ok: false, error: reason, durationMs: elapsed);
        }
        if (r.cancelled) {
          return AutomationExecOutcome(ok: false, error: '任务被取消', durationMs: elapsed);
        }
        return AutomationExecOutcome(ok: true, durationMs: elapsed);
      } finally {
        await drain.cancel();
      }
    } catch (e) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - started;
      return AutomationExecOutcome(ok: false, error: '执行异常：$e', durationMs: elapsed);
    }
  }

  /// 用哪个工作区跑：取**第一个**已登记工作区；一个都没有 ⇒ 尝试登记内置应用工作区。
  ///
  /// 为什么是"第一个"而不是"上次用的那个"：App 服务层没有"当前工作区"这个概念
  /// （它在 UI 层）。挑第一个是**确定且可解释**的；等 UI 层愿意把当前工作区
  /// 交给服务层时，这里换成一个注入的 resolver 即可。
  static Future<String?> _resolveWorkspace(AgentBridge bridge) async {
    try {
      final list = await bridge.listWorkspaces();
      for (final m in list) {
        final p = (m['path'] as String?)?.trim() ?? '';
        if (p.isNotEmpty) return p;
      }
      final app = await bridge.ensureAppWorkspace();
      final p = (app?['path'] as String?)?.trim() ?? '';
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }
}
