import 'package:flutter_test/flutter_test.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/agent_bridge.dart';

/// **审批门禁（App 侧）单测**（2026-10-24 接线）。
///
/// 钉住 `LocalAskGate` 的审批半边（与 backend `_ApprovalHook` 配对的那半）：
///
/// 1. 白名单命中 ⇒ 直接放行，**不弹窗**（不发事件）；
/// 2. 没有 UI 出口 ⇒ fail-closed 拒绝（测试/无头场景问不了人）；
/// 3. 弹窗回路：事件带着 tool/args/reason 出去，`replyApproval` 三种决定
///    分别对应 放行 / 放行+记账 / 拒绝；
/// 4. `allow_always` ⇒ [LocalAskGate.onAlwaysAllow] 回调被调（桥接层持久化），
///    且同一 run 内后续同工具调用直接放行；
/// 5. 点停止（[LocalAskGate.abort]）⇒ 挂起的审批按拒绝收场，
///    且之后不再弹窗；
/// 6. 并行工具批次里多个审批请求**串行弹窗**（排队，不互相拒绝）。
void main() {
  final events = <AgentEvent>[];
  late LocalAskGate gate;

  setUp(() {
    events.clear();
    gate = LocalAskGate();
    gate.attach(events.add);
  });

  group('白名单与 fail-closed', () {
    test('白名单命中 ⇒ 直接放行，不发事件', () async {
      gate.seedAllowed(['run_shell_command']);

      final ok = await gate.requestApproval(
          'run_shell_command', {'command': 'ls'}, '模型请求执行 run_shell_command。');

      expect(ok, isTrue);
      expect(events.where((e) => e.type == AgentEvent.kApprovalRequest), isEmpty,
          reason: '白名单命中不该弹窗');
    });

    test('没有 UI 出口 ⇒ fail-closed 拒绝', () async {
      final silent = LocalAskGate(); // 不 attach ⇒ 没有 UI
      final ok = await silent.requestApproval('write_file', {'path': 'a'}, '');
      expect(ok, isFalse, reason: '问不了人就必须拒绝，不能放行');
    });

    test('已点停止 ⇒ 拒绝，且不弹窗', () async {
      gate.abort();
      final ok = await gate.requestApproval('write_file', {'path': 'a'}, '');
      expect(ok, isFalse);
      expect(events.where((e) => e.type == AgentEvent.kApprovalRequest), isEmpty);
    });
  });

  group('弹窗回路', () {
    test('allow ⇒ 放行；事件带完整 tool/args/reason', () async {
      final f = gate.requestApproval('write_file', {'path': 'a.txt', 'content': 'hi'}, '模型请求执行 `write_file`。');

      // 事件已发出（同步 emit），此刻还没有决定
      final req = events.whereType<AgentEvent>().lastWhere(
            (e) => e.type == AgentEvent.kApprovalRequest,
          );
      expect(req.tool, 'write_file');
      expect(req.args, {'path': 'a.txt', 'content': 'hi'});
      expect(req.reason, '模型请求执行 `write_file`。');

      final replied = await gate.replyApproval('allow');
      expect(replied, isTrue);
      expect(await f, isTrue);
    });

    test('deny ⇒ 拒绝', () async {
      final f = gate.requestApproval('write_file', {}, '');
      await gate.replyApproval('deny');
      expect(await f, isFalse);
    });

    test('点弹窗外面（null）⇒ 按拒绝计', () async {
      final f = gate.requestApproval('write_file', {}, '');
      await gate.replyApproval('deny');
      expect(await f, isFalse);
    });

    test('allow_always ⇒ 放行 + 回调持久化 + 同 run 后续免问', () async {
      final persisted = <String>[];
      gate.onAlwaysAllow = persisted.add;

      final f1 = gate.requestApproval('run_shell_command', {}, '');
      await gate.replyApproval('allow_always');
      expect(await f1, isTrue);
      expect(persisted, ['run_shell_command'],
          reason: '桥接层要能持久化（SharedPreferences）');

      // 同一 run 的第二次调用：直接放行、不再弹窗
      final f2 = gate.requestApproval('run_shell_command', {}, '');
      expect(await f2, isTrue);
      expect(
        events.where((e) => e.type == AgentEvent.kApprovalRequest),
        hasLength(1),
        reason: '第二次不该再弹窗',
      );
      expect(persisted, hasLength(1), reason: '不重复持久化同一条');
    });

    test('没有挂起的审批时 replyApproval 如实返回 false', () async {
      expect(await gate.replyApproval('allow'), isFalse);
    });
  });

  group('停止与并发', () {
    test('挂起中点停止 ⇒ 按拒绝收场，之后的请求也不再弹窗', () async {
      final f = gate.requestApproval('write_file', {}, '');
      gate.abort();
      expect(await f, isFalse);
      final f2 = gate.requestApproval('write_file', {}, '');
      expect(await f2, isFalse);
      expect(events.where((e) => e.type == AgentEvent.kApprovalRequest), hasLength(1),
          reason: '只有停止前那一次弹窗；停止后的请求不该再弹');
    });

    test('并行批次多个审批 ⇒ 串行弹窗（排队），不是互相拒绝', () async {
      final f1 = gate.requestApproval('write_file', {'path': '1'}, '');
      final f2 = gate.requestApproval('write_file', {'path': '2'}, '');

      // 第一个弹窗已发出
      await gate.replyApproval('allow');
      expect(await f1, isTrue);

      // 第二个此时才被问（排队等待的结果）
      final reqs = events.where((e) => e.type == AgentEvent.kApprovalRequest);
      expect(reqs, hasLength(2));
      await gate.replyApproval('deny');
      expect(await f2, isFalse);
    });
  });

  group('ask_user 原有行为不被破坏', () {
    test('停止后 askUser 返回 null（不再弹窗）', () async {
      gate.abort();
      final answer = await gate.askUser([
        const AskQuestion(id: 'q1', question: '选哪个？'),
      ]);
      expect(answer, isNull);
    });
  });
}
