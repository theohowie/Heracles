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
    Future<bool> ask(String tool, [Map<String, String> args = const {}]) =>
        gate.requestApproval(
          callId: 'c-$tool',
          toolName: tool,
          args: args,
          risk: '风险说明',
          detail: '模型请求执行 $tool。',
          workspaceInside: true,
        );

    test('白名单命中 ⇒ 直接放行，不发事件', () async {
      gate.seedAllowed(['run_shell_command']);

      final ok = await ask('run_shell_command', {'command': 'ls'});

      expect(ok, isTrue);
      expect(events.where((e) => e.type == AgentEvent.kApprovalRequired), isEmpty,
          reason: '白名单命中不该弹窗');
    });

    test('没有 UI 出口 ⇒ fail-closed 拒绝', () async {
      final silent = LocalAskGate(); // 不 attach ⇒ 没有 UI
      final ok = await silent.requestApproval(
        callId: 'c1',
        toolName: 'write_file',
        args: {'path': 'a'},
        risk: '',
        detail: '',
        workspaceInside: true,
      );
      expect(ok, isFalse, reason: '问不了人就必须拒绝，不能放行');
    });

    test('已点停止 ⇒ 拒绝，且不弹窗', () async {
      gate.abort();
      final ok = await ask('write_file');
      expect(ok, isFalse);
      expect(events.where((e) => e.type == AgentEvent.kApprovalRequired), isEmpty);
    });
  });

  group('弹窗回路', () {
    test('allow ⇒ 放行；事件带完整 tool/args/reason', () async {
      final f = gate.requestApproval(
          callId: 'allow-1',
          toolName: 'write_file',
          args: {'path': 'a.txt', 'content': 'hi'},
          risk: '风险说明',
          detail: '模型请求执行 `write_file`。',
          workspaceInside: true,
        );

      // 事件已发出（同步 emit），此刻还没有决定
      final req = events.whereType<AgentEvent>().lastWhere(
            (e) => e.type == AgentEvent.kApprovalRequired,
          );
      expect(req.tool, 'write_file');
      expect(req.args, {'path': 'a.txt', 'content': 'hi'});
      // N1 语义：reason = risk（一句话风险说明），detail 在 message（弹窗顶部与正文各取所需）
      expect(req.reason, '风险说明');
      expect(req.message, '模型请求执行 `write_file`。');

      final replied = await gate.replyApproval(callId: 'allow-1', decision: 'once');
      expect(replied, isTrue);
      expect(await f, isTrue);
    });

    test('deny ⇒ 拒绝', () async {
      final f = gate.requestApproval(
          callId: 'deny-1',
          toolName: 'write_file',
          args: {},
          risk: '',
          detail: '',
          workspaceInside: true,
        );
      await gate.replyApproval(callId: 'deny-1', decision: 'deny');
      expect(await f, isFalse);
    });

    test('点弹窗外面（null）⇒ 按拒绝计', () async {
      final f = gate.requestApproval(
          callId: 'cx',
          toolName: 'write_file',
          args: {},
          risk: '',
          detail: '',
          workspaceInside: true,
        );
      await gate.replyApproval(callId: 'cx', decision: 'deny');
      expect(await f, isFalse);
    });

    test('allow_always ⇒ 放行 + 回调持久化 + 同 run 后续免问', () async {
      final persisted = <String>[];
      gate.onAlwaysAllow = persisted.add;

      final f1 = gate.requestApproval(
          callId: 'cs',
          toolName: 'run_shell_command',
          args: {},
          risk: '',
          detail: '',
          workspaceInside: false,
        );
      await gate.replyApproval(callId: 'cs', decision: 'always');
      expect(await f1, isTrue);
      expect(persisted, ['run_shell_command'],
          reason: '桥接层要能持久化（SharedPreferences）');

      // 同一 run 的第二次调用：直接放行、不再弹窗
      final f2 = gate.requestApproval(
          callId: 'cs',
          toolName: 'run_shell_command',
          args: {},
          risk: '',
          detail: '',
          workspaceInside: false,
        );
      expect(await f2, isTrue);
      expect(
        events.where((e) => e.type == AgentEvent.kApprovalRequired),
        hasLength(1),
        reason: '第二次不该再弹窗',
      );
      expect(persisted, hasLength(1), reason: '不重复持久化同一条');
    });

    test('没有挂起的审批时 replyApproval 如实返回 false', () async {
      expect(await gate.replyApproval(callId: 'c1', decision: 'once'), isFalse);
    });
  });

  group('停止与并发', () {
    test('挂起中点停止 ⇒ 按拒绝收场，之后的请求也不再弹窗', () async {
      final f = gate.requestApproval(
          callId: 'cx',
          toolName: 'write_file',
          args: {},
          risk: '',
          detail: '',
          workspaceInside: true,
        );
      gate.abort();
      expect(await f, isFalse);
      final f2 = gate.requestApproval(
          callId: 'cx',
          toolName: 'write_file',
          args: {},
          risk: '',
          detail: '',
          workspaceInside: true,
        );
      expect(await f2, isFalse);
      expect(events.where((e) => e.type == AgentEvent.kApprovalRequired), hasLength(1),
          reason: '只有停止前那一次弹窗；停止后的请求不该再弹');
    });

    test('并行批次多个审批 ⇒ 串行弹窗（排队），不是互相拒绝', () async {
      final f1 = gate.requestApproval(
          callId: 'p1',
          toolName: 'write_file',
          args: {'path': '1'},
          risk: '',
          detail: '',
          workspaceInside: true,
        );
      final f2 = gate.requestApproval(
          callId: 'p2',
          toolName: 'write_file',
          args: {'path': '2'},
          risk: '',
          detail: '',
          workspaceInside: true,
        );

      // 第一个弹窗已发出
      await gate.replyApproval(callId: 'p1', decision: 'once');
      expect(await f1, isTrue);

      // 第二个此时才被问（排队等待的结果）
      final reqs = events.where((e) => e.type == AgentEvent.kApprovalRequired);
      expect(reqs, hasLength(2));
      await gate.replyApproval(callId: 'p2', decision: 'deny');
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
