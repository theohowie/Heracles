// Copyright (C) 2026 The Heracles Authors
//
// **App 宿主记忆 wiring 端到端探针**（2026-10-29，task-8b）。
//
// ============================================================================
// 这条探针测什么（以及不测什么）
// ============================================================================
// 测的是**宿主编排层**（`LocalAgentExecutor`）把三作用域记忆接到 backend 的
// 那条链路：
//
//   三 scope 读取（并发 + 各自超时 + global 开关）
//     → MemoryContext（结构化三段）
//     → backend renderMemoryContext（排序/预算/渲染的唯一实现）
//     → system prompt 段落顺序 global → workspace → session（session 最后）
//
// **不测**：作用域存储/墓碑/淘汰（那是 task-9 的 `ScopedMemoryService`
// 专项测试）、backend 预算边界（那是 backend `memory_prompt_test.dart`）。
//
// 用 `memoryContextForTest` 注入假读取函数：不碰 MethodChannel、不联网，
// 但走的仍是生产路径上的同一段编排代码。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/global_memory.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/memory_service.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles_backend/heracles_backend.dart';

const String _sid = 's1791611845161';
const String _ws = '/ws/demo';

ScopedMemoryEntry entry(
  String text,
  MemoryScope scope, {
  String? sid,
  String source = 'agent',
  int createdAt = 1,
}) =>
    ScopedMemoryEntry(
      id: 'm-${scope.wireName}-$text',
      scope: scope,
      sid: sid,
      kind: 'other',
      text: text,
      source: source,
      createdAt: createdAt,
    );

LocalAgentExecutor executor({
  bool globalEnabled = true,
  bool pooling = false,
}) =>
    LocalAgentExecutor(
      workspacePath: _ws,
      settings: AppSettings(
        memoryGlobalEnabled: globalEnabled,
        memoryPooling: pooling,
      ),
      sessionStore: SessionStore(workspaceRoot: _ws),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('★★★ 三作用域读取 → 渲染段落顺序 global→workspace→session（session 最后）', () async {
    String? sessionSidSeen;
    final ctx = await executor().memoryContextForTest(
      sessionId: _sid,
      read: (scope, sid) async {
        if (scope == MemoryScope.session) sessionSidSeen = sid;
        return switch (scope) {
          MemoryScope.global => [entry('全局条目 G', MemoryScope.global)],
          MemoryScope.workspace => [entry('工作区条目 W', MemoryScope.workspace)],
          MemoryScope.session => [
            entry('会话条目 S', MemoryScope.session, sid: sid),
          ],
        };
      },
    );

    // 1) 编排层真的把三段分好了（不是把三段混进一段）
    expect(ctx.global.single.text, '全局条目 G');
    expect(ctx.workspace.single.text, '工作区条目 W');
    expect(ctx.session.single.text, '会话条目 S');
    expect(ctx.session.single.scope, MemoryScope.session,
        reason: '会话段条目的 scope 必须保留（backend 据此渲染段头/来源）');
    // session 段寻址必须带本轮 sid（backend 的 MemoryRecord 不带 sid：
    // sid 是**寻址**锚点，读时已由 service 校验过，不随条目进 prompt）
    expect(sessionSidSeen, _sid,
        reason: '★ 会话段读取必须用本轮解析出的 sid 寻址（串台防线）');

    // 2) backend 渲染的段落顺序（这是"假 agent 捕获 system prompt"里
    //    真正进 system 的那段文字）
    final out = renderMemoryContext(
      ctx,
      task: '条目',
      windowTokens: 128000,
    );
    final iGlobal = out.indexOf(globalMemorySectionTitle);
    final iWorkspace = out.indexOf(workspaceMemorySectionTitle);
    final iSession = out.indexOf(sessionMemorySectionTitle);
    expect(iGlobal, greaterThanOrEqualTo(0));
    expect(iWorkspace, greaterThan(iGlobal),
        reason: '★ 工作区段必须在全局段之后');
    expect(iSession, greaterThan(iWorkspace),
        reason: '★ session 必须是最后一段（最易变 ⇒ 缓存损失最小）');
    expect(out.indexOf('全局条目 G'), lessThan(out.indexOf('工作区条目 W')));
    expect(out.indexOf('工作区条目 W'), lessThan(out.indexOf('会话条目 S')));

    // 3) 跨层冲突尾注全篇只出现一次，且在最末
    expect(RegExp('以当前对话为准').allMatches(out).length, 1);
    expect(out.trimRight().endsWith(memoryConflictRule), isTrue);
  });

  test('★★★ global 开关关 ⇒ 不读 global 段（数据保留但不注入）', () async {
    final readScopes = <MemoryScope>[];
    final ctx = await executor(globalEnabled: false).memoryContextForTest(
      sessionId: _sid,
      read: (scope, sid) async {
        readScopes.add(scope);
        return [entry('${scope.wireName} 条目', scope, sid: sid)];
      },
    );

    expect(readScopes, isNot(contains(MemoryScope.global)),
        reason: '★ 关掉开关就不该**读** global（不只是不渲染）');
    expect(ctx.global, isEmpty);
    expect(ctx.globalEnabled, isFalse);
    expect(ctx.workspace, hasLength(1));
    expect(ctx.session, hasLength(1));

    final out = renderMemoryContext(ctx, task: '', windowTokens: 128000);
    expect(out, isNot(contains(globalMemorySectionTitle)));
    expect(out, contains(workspaceMemorySectionTitle));
    expect(out, contains(sessionMemorySectionTitle));
  });

  test('★★★ 某段读挂住 ⇒ 该段超时为空、其它段照常（记忆绝不冻住主链路）', () async {
    final sw = Stopwatch()..start();
    final ctx = await executor().memoryContextForTest(
      sessionId: _sid,
      timeoutMs: 60,
      read: (scope, sid) async {
        if (scope == MemoryScope.session) {
          // 模拟真机事故：通道调用"永不返回"
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        return [entry('${scope.wireName} ok', scope, sid: sid)];
      },
    );
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(1000),
        reason: '★ 三段必须并发 + 各自超时；串行/无超时会让首字延迟变成"卡死"');
    expect(ctx.global.single.text, 'global ok');
    expect(ctx.workspace.single.text, 'workspace ok');
    expect(ctx.session, isEmpty,
        reason: '★ 超时那段为空、不阻断运行（最差退化成"这轮没有该段记忆"）');
  });

  test('★★ MemoryEntry 转换保留 scope/sid/source/createdAt（只增字段不丢）', () async {
    final ctx = await executor().memoryContextForTest(
      sessionId: _sid,
      read: (scope, sid) async => [
        entry('带字段的条目', scope,
            sid: sid, source: MemoryRecord.sourcePromoted, createdAt: 42),
      ],
    );
    final rec = ctx.session.single;
    expect(rec.source, MemoryRecord.sourcePromoted);
    expect(rec.createdAt, 42);
    expect(rec.scope, MemoryScope.session);
    expect(rec.id, contains('session'));
    expect(rec.isUserConfirmed, isTrue,
        reason: 'promoted 算"用户已确认" ⇒ 注入时优先');
  });

  test('★★ 记忆能力：agent 写 global 恒失败并指路 propose_global_memory', () async {
    final cap = ScopedMemoryCapability(
      workspacePath: _ws,
      service: ScopedMemoryService(),
      sessionId: _sid,
    );

    expect(cap.defaultWriteScope, MemoryScope.session,
        reason: 'save_memory 默认写会话私有（写错作用域影响最小）');

    final denied = await cap.appendScoped(MemoryScope.global, '用户偏好简洁');
    expect(denied, isA<CapabilityFailure>());
    expect((denied as CapabilityFailure).reason, contains('全局记忆只读'));
    expect(denied.reason, contains('propose_global_memory'),
        reason: '★ 拒绝必须指路，否则模型会反复重试直写');
    expect(denied.isRetryable, isFalse);
  });

  test('★★ 记忆能力：没有 sid 时会话写入 fail-closed（不偷偷落工作区/全局）', () async {
    final cap = ScopedMemoryCapability(
      workspacePath: _ws,
      service: ScopedMemoryService(),
    );
    final r = await cap.appendScoped(MemoryScope.session, '一条约定');
    expect(r, isA<CapabilityFailure>());
    expect((r as CapabilityFailure).reason, contains('会话 id'),
        reason: '★ 缺寻址就明确失败（不静默纠正作用域）');
    expect(r.isRetryable, isFalse);
  });

  // ---------------------------------------------------------------------------
  // 迁移触发点（设计稿 §3.7.2 步骤 0：App 启动后、首轮读取之前 best-effort）
  // ---------------------------------------------------------------------------
  group('旧 memory.md 迁移触发点', () {
    const memoryChannel = MethodChannel(DeviceChannelClient.channelName);
    var calls = 0;

    setUp(() {
      calls = 0;
      resetMemoryMigrationForTest();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(memoryChannel, null);
    });

    void mockMigrate(Map<String, Object?> Function() reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(memoryChannel, (call) async {
        if (call.method != 'memory.migrate') return <String, Object?>{'ok': true};
        calls++;
        return reply();
      });
    }

    test('★★ AgentBridge.migrateMemory 正确解析正常态（migrated / no-legacy-file）', () async {
      mockMigrate(() => <String, Object?>{
            'ok': true,
            'migrated': true,
            'entries': 7,
            'backup': '/bak/memory.md.1',
          });
      final r = await AgentBridge().migrateMemory();
      expect(r.ok, isTrue);
      expect(r.migrated, isTrue);
      expect(r.entries, 7);
      expect(r.backup, '/bak/memory.md.1');
      expect(calls, 1);

      mockMigrate(() => <String, Object?>{'ok': true, 'reason': 'no-legacy-file'});
      final r2 = await AgentBridge().migrateMemory();
      expect(r2.ok, isTrue, reason: '没有旧文件是正常态，不是错误');
      expect(r2.noLegacyFile, isTrue);
      expect(r2.migrated, isFalse);
    });

    test('★★ 迁移失败只回传人话原因、不抛（绝不阻断主链路）', () async {
      mockMigrate(
          () => <String, Object?>{'ok': false, 'error': 'E_MIGRATE_FAILED：备份写不进去'});
      final r = await AgentBridge().migrateMemory();
      expect(r.ok, isFalse);
      expect(r.error, contains('E_MIGRATE_FAILED'));
    });

    test('★★ 首轮自动迁移是**一次性**：第二次不再打通道', () async {
      mockMigrate(() => <String, Object?>{'ok': true, 'migrated': true, 'entries': 1});

      final first = await runMemoryMigrationOnce();
      expect(first.ok, isTrue);
      expect(first.migrated, isTrue);
      expect(calls, 1);

      final second = await runMemoryMigrationOnce();
      expect(second.alreadyMigrated, isTrue);
      expect(calls, 1,
          reason: '★ 迁移是启动级动作：进程内一次性标记，不许每轮打通道');
    });
  });
}
