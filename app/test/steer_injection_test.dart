// Copyright (C) 2026 The Heracles Authors
//
// **P0 插队发送（2026-10-30）**：`AgentBridge.interruptRun` 真的入队 +
// `LocalAgentExecutor` 的轮间插话队列。
//
// ============================================================================
// 语义（与"停止"完全不同）
// ============================================================================
// · 在途 run：`interruptRun` 把话放进该 run 的队列（≤4、trim、去重、满拒绝）
//   并发一条 `interrupted` 事件让 UI 立刻渲染用户消息 ⇒ 返回 true；
// · 没有在途 run ⇒ false（调用方走正常发送，绝不静默丢）；
// · backend 在**当前轮完整结束之后**把它注入成 `UserMessage`（不打断在途流）；
// · run 收尾清队列；**未消费项发一条"插话未送达"提示**（不静默丢）。
library;

import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles_backend/heracles_backend.dart';

AppSettings _settings() => AppSettings(
      permission: PermissionMode.fullAccess,
      providers: [
        AppSettings.defaultProviders.first
            .copyWith(apiKey: 'k', enabled: true, isDefault: true),
      ],
    );

class _FakeWs implements WorkspaceCapability {
  final files = <String, String>{};

  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return CapabilitySuccess('已写入 $path');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);
  @override
  Future<CapabilityResult> read(String path,
          {int offset = 1, int limit = 0}) async =>
      CapabilitySuccess(files[path] ?? '');
  @override
  Future<CapabilityResult> edit(
          String path, String oldText, String newText) async =>
      const CapabilitySuccess('已替换');
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('已应用');
  @override
  Future<CapabilityResult> delete(String path,
          {bool recursive = false}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> mkdir(String path) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> findFiles(String pattern,
          {int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> grepFiles(String pattern,
          {String pathFilter = '', int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> move(String from, String to) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> copy(String from, String to) async =>
      const CapabilitySuccess('');
}

/// 第 0 次调用：等测试放行后返回一个工具调用；之后给最终回答。
///
/// "等测试放行"是为了**确定性**地模拟"用户在第一轮跑着的时候插话"：
/// 测试看到 [started] 后调用 `interruptRun`，再放行 —— 插话一定在
/// 第一轮结束（hook 取件）之前入队。
class _BlockingClient implements LLMClient {
  final started = Completer<void>();
  final release = Completer<void>();
  final messages = <List<LLMMessage>>[];
  int calls = 0;

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    if (i == 0) {
      return ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'c1',
            name: 'write_file',
            arguments: '{"path":"a.txt","content":"x"}',
          ),
        ],
      );
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }

  Future<ModelMessage> _next(ModelConfig mc) async {
    final i = calls;
    if (i == 0) {
      if (!started.isCompleted) started.complete();
      await release.future; // 测试在这里插话/或故意让它失败
    }
    return _r(mc);
  }

  @override
  Future<ModelMessage> generate(List<LLMMessage> messages,
      {List<Tool>? tools,
      ToolChoice? toolChoice,
      required ModelConfig modelConfig,
      bool? jsonOutput,
      dynamic cancelToken}) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return _next(modelConfig);
  }

  @override
  Future<Stream<StreamingMessage>> stream(List<LLMMessage> messages,
      {List<Tool>? tools,
      ToolChoice? toolChoice,
      required ModelConfig modelConfig,
      bool? jsonOutput,
      dynamic cancelToken}) async {
    this.messages.add(List<LLMMessage>.of(messages));
    final m = await _next(modelConfig);
    return Stream<StreamingMessage>.fromIterable(
        [StreamingMessage(modelMessage: m)]);
  }
}

List<String> _userTexts(List<LLMMessage> messages) => [
      for (final m in messages)
        if (m is UserMessage)
          m.contents.whereType<TextPart>().map((p) => p.text).join(),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalAgentExecutor 插话队列（单元）', () {
    LocalAgentExecutor ex() => LocalAgentExecutor(
          workspacePath: '/ws/fake',
          settings: _settings(),
          sessionStore: SessionStore(workspaceRoot: '/ws/fake'),
        );

    test('① 入队/取件 FIFO；空串拒绝；去重（accepted 但不再 added）', () {
      final e = ex();
      expect(e.enqueueSteer('  '), isFalse, reason: '空串/纯空白不入队');
      expect(e.enqueueSteer('第一句'), isTrue);
      expect(e.enqueueSteer('第二句'), isTrue);
      expect(e.takeSteer(), '第一句', reason: 'FIFO');
      // 去重：重复的那句"已接受但不再新增"
      final dup = e.steerEnqueue('第二句');
      expect(dup.accepted, isTrue);
      expect(dup.added, isFalse, reason: '重复插话不再新增（也不多发一条 UI 消息）');
      expect(e.takeSteer(), '第二句');
      expect(e.takeSteer(), isNull, reason: '取空返回 null（= 本轮无插话）');
    });

    test('② 队列上限 4：第 5 条**拒绝**（不丢最旧，调用方走正常发送）', () {
      final e = ex();
      for (var i = 0; i < LocalAgentExecutor.steerQueueMax; i++) {
        expect(e.enqueueSteer('插话$i'), isTrue);
      }
      expect(e.enqueueSteer('第5条'), isFalse,
          reason: '★ 满了就拒绝并如实返回 false（消息由调用方正常发送，不静默丢）');
      expect(e.steerQueueLength, LocalAgentExecutor.steerQueueMax);
    });

    test('③ clearSteer / takeAllSteer：收尾清空 + 取走未消费项', () {
      final e = ex();
      e.enqueueSteer('A');
      e.enqueueSteer('B');
      final all = e.takeAllSteer();
      expect(all, ['A', 'B']);
      expect(e.steerQueueLength, 0);
      e.enqueueSteer('C');
      e.clearSteer();
      expect(e.steerQueueLength, 0);
    });
  });

  group('AgentBridge.interruptRun（端到端）', () {
    late _BlockingClient client;
    late LocalAgentExecutor executor;

    setUp(() {
      client = _BlockingClient();
      executor = LocalAgentExecutor(
        workspacePath: '/ws/fake',
        settings: _settings(),
        sessionStore: SessionStore(workspaceRoot: '/ws/fake'),
        clientForTest: client,
        capabilitiesForTest: Capabilities(workspace: _FakeWs()),
      );
      AgentBridge.executorFactoryForTest = ({
        required String workspacePath,
        required AppSettings settings,
        required SessionStore sessionStore,
        AskGate? askGate,
      }) =>
          executor;
    });

    tearDown(() => AgentBridge.executorFactoryForTest = null);

    test('★★★ 在途 ⇒ true：插话进下一轮历史 + 立即发 kInterrupted（UI 渲染用户消息）', () async {
      final bridge = AgentBridge();
      final events = <AgentEvent>[];
      final sub = bridge.events.listen(events.add);
      final fut = bridge.run(
        workspacePath: '/ws/fake',
        request: '原任务',
        settings: _settings(),
      );
      await client.started.future;

      final accepted = await bridge.interruptRun('改用 B 方案');
      expect(accepted, isTrue, reason: '★ 在途 run 必须接受插话（旧实现恒 false）');

      client.release.complete();
      await fut;
      await sub.cancel();

      // 1) backend 侧：下一轮请求历史里真的出现这句话
      final last = client.messages.last;
      expect(_userTexts(last).any((t) => t.contains('改用 B 方案')), isTrue,
          reason: '★ 插话必须作为 UserMessage 进入下一轮请求（模型看得到）');
      // 2) UI 侧：立刻收到一条 interrupted（渲染成用户消息）
      final interrupted =
          events.where((e) => e.type == AgentEvent.kInterrupted).toList();
      expect(interrupted, hasLength(1));
      expect(interrupted.single.message, '改用 B 方案',
          reason: '★ UI 读 `message` 字段渲染这条用户消息（chat_screen kInterrupted）');
      // 3) 收尾清队列
      expect(executor.steerQueueLength, 0);
    });

    test('★★ 没有在途 run ⇒ false（调用方走正常发送）', () async {
      final bridge = AgentBridge();
      expect(await bridge.interruptRun('随便一句'), isFalse);
    });

    test('★★ 重复插话：只渲染一次（accepted=true 但不重复发事件）', () async {
      final bridge = AgentBridge();
      final events = <AgentEvent>[];
      final sub = bridge.events.listen(events.add);
      final fut = bridge.run(
        workspacePath: '/ws/fake',
        request: '原任务',
        settings: _settings(),
      );
      await client.started.future;

      expect(await bridge.interruptRun('同一句'), isTrue);
      expect(await bridge.interruptRun('同一句'), isTrue,
          reason: '重复视为已接受（不让调用方误判为失败而再发一遍）');
      client.release.complete();
      await fut;
      await sub.cancel();

      final interrupted =
          events.where((e) => e.type == AgentEvent.kInterrupted).toList();
      expect(interrupted, hasLength(1), reason: '★ 同一句不许重复渲染');
    });

    test('★★ 未消费项不静默丢：run 收尾时仍在队列 ⇒ 一条"插话未送达"提示', () async {
      late LocalAgentExecutor ex2;
      // 第一轮模型调用时先入队一条插话、随即抛错（轮完成 hook 没机会取件）
      // ⇒ 收尾时队列里一定还剩一条。
      final c2 = _ThrowAfterEnqueueClient(() => ex2.enqueueSteer('没赶上的一句'));
      ex2 = LocalAgentExecutor(
        workspacePath: '/ws/fake',
        settings: _settings(),
        sessionStore: SessionStore(workspaceRoot: '/ws/fake'),
        clientForTest: c2,
        capabilitiesForTest: Capabilities(workspace: _FakeWs()),
      );
      AgentBridge.executorFactoryForTest = ({
        required String workspacePath,
        required AppSettings settings,
        required SessionStore sessionStore,
        AskGate? askGate,
      }) =>
          ex2;

      final bridge = AgentBridge();
      final events = <AgentEvent>[];
      final sub = bridge.events.listen(events.add);
      await bridge.run(
        workspacePath: '/ws/fake',
        request: '原任务',
        settings: _settings(),
      );
      // 事件投递是异步的：先让收尾事件流完，再退订（否则最后一条会丢）。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();

      expect(events.any((e) => e.type == AgentEvent.kFailed), isTrue,
          reason: '前提：这次 run 确实失败了');
      final notices = events
          .where((e) =>
              e.type == AgentEvent.kInterrupted &&
              (e.message ?? '').contains('插话未送达'))
          .toList();
      expect(notices, hasLength(1),
          reason: '★ 未消费项不得静默丢 —— 用一条带前缀的提示告知用户');
      expect(notices.single.message, contains('没赶上的一句'));
      expect(ex2.steerQueueLength, 0);
    });  });
}

/// 第一轮模型调用：先入队一条插话（模拟"用户刚插话、run 就失败"），再抛错。
class _ThrowAfterEnqueueClient implements LLMClient {
  _ThrowAfterEnqueueClient(this.onFirstCall);

  final bool Function() onFirstCall;

  @override
  Future<ModelMessage> generate(List<LLMMessage> messages,
      {List<Tool>? tools,
      ToolChoice? toolChoice,
      required ModelConfig modelConfig,
      bool? jsonOutput,
      dynamic cancelToken}) async {
    onFirstCall();
    throw StateError('模拟失败');
  }

  @override
  Future<Stream<StreamingMessage>> stream(List<LLMMessage> messages,
      {List<Tool>? tools,
      ToolChoice? toolChoice,
      required ModelConfig modelConfig,
      bool? jsonOutput,
      dynamic cancelToken}) async {
    onFirstCall();
    throw StateError('模拟失败');
  }
}