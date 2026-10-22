/// **`HeraclesAgent.run()` 的端到端测试**（2026-10-22 补）。
///
/// ## 为什么这个文件必须存在
///
/// `HeraclesAgent` 是 backend 的**组装层**（512 行）：建 client、包工具、
/// 传参数给 `StatefulAgent`、把框架事件翻成 [HeraclesEvent]。
/// 它此前**一条测试都没有** —— 因为要跑它就得有真的 LLM。
///
/// 交接时 backend-fixer 明确留了这条账：
///
/// > `HeraclesAgent.run()` 的事件桥（含审计 §3.2 那条死锁修法）
/// > **一行都没被执行过**，因为它需要真实 LLM client。
///
/// 这个文件用一个**假 LLM client** 补上：不发一个网络请求，但把
/// `run()` → `_drive()` → 事件桥 → `Stream` 这条链**真的跑一遍**。
///
/// ## 它锁住的是哪几件事
///
/// 1. **事件桥不再死锁**（审计 §3.2 的原 bug：`await bridge.close()` 在
///    没有监听者时永不完成 ⇒ 一个事件都播不出来）。今天若有人把
///    `unawaited(bridge.close())` 改回 `await`，这条测试会**超时失败**。
/// 2. **终态一定有事件**：`run()` 要么给 `HeraclesFinished`，要么给
///    `HeraclesFailed` —— 不许"流关了但什么都没说"（UI 会永远转圈）。
/// 3. **工具调用的往返**：模型请求工具 → 工具真的执行 → 结果回填 →
///    模型拿到结果给出正文。
/// 4. **预算是真预算**：`maxToolCalls` 超限会中止（不是"记录一下"）。
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

// ============================================================================
// 假 LLM client —— 按脚本吐出预设的轮次
// ============================================================================

/// 一轮预设：要么请求工具，要么给正文。
class _ScriptedTurn {
  const _ScriptedTurn.text(this.text)
      : toolName = null,
        toolArgs = null;
  const _ScriptedTurn.tool(this.toolName, this.toolArgs) : text = null;

  final String? text;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
}

/// 按脚本回应的 client。**不发任何网络请求**。
class _ScriptedClient implements LLMClient {
  _ScriptedClient(this.script, {this.repeatLast = false});

  final List<_ScriptedTurn> script;

  /// 脚本用完后是否重复最后一轮（用于"预算应当中止"这类测试）。
  final bool repeatLast;

  int calls = 0;

  /// 每次调用收到的工具名列表（用来验证"工具确实递给模型了"）。
  final List<List<String>> seenTools = [];

  /// 每次调用收到的完整消息（用来验证"工具结果回填了"）。
  final List<List<LLMMessage>> seenMessages = [];

  _ScriptedTurn _next() {
    final i = calls - 1;
    if (i < script.length) return script[i];
    if (repeatLast && script.isNotEmpty) return script.last;
    return const _ScriptedTurn.text('（脚本已用尽）');
  }

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    calls++;
    seenTools.add([for (final t in tools ?? const <Tool>[]) t.name]);
    seenMessages.add(List.of(messages));
    return _build();
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    calls++;
    seenTools.add([for (final t in tools ?? const <Tool>[]) t.name]);
    seenMessages.add(List.of(messages));
    final msg = _build();
    // 逐字吐：一个 chunk 一个字符的正文。真实流式就是多 chunk。
    final text = msg.textOutput ?? '';
    return Stream<StreamingMessage>.fromIterable([
      for (final ch in text.split(''))
        StreamingMessage(modelMessage: ModelMessage(model: 'test-model', textOutput: ch)),      StreamingMessage(modelMessage: msg),
    ]);
  }

  ModelMessage _build() {
    final turn = _next();
    if (turn.toolName != null) {
      return ModelMessage(
        model: 'test-model',
        // ⚠️ `stopReason` 必须给：框架在校验 `stopReason == null` 时
        //    会判定"模型返回空停止原因"并**重试 3 次**，然后抛
        //    `loopDetection`。真实 provider 一定会填这个字段
        //    （OpenAI 的 `finish_reason` / Anthropic 的 `stop_reason`），
        //    假 client 漏了它就会造出"假的重试/假的循环"。
        stopReason: turn.toolName != null ? 'tool_calls' : 'stop',
        functionCalls: [
          FunctionCall(
            id: 'call-${_id++}',
            name: turn.toolName!,
            arguments: _encode(turn.toolArgs ?? const {}),
          ),
        ],
      );
    }
    return ModelMessage(model: 'test-model', stopReason: 'stop', textOutput: turn.text ?? '');
  }

  int _id = 0;

  static String _encode(Map<String, dynamic> m) {
    final parts = m.entries.map((e) => '"${e.key}":${_val(e.value)}');
    return '{${parts.join(',')}}';
  }

  static String _val(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return '$v';
    return '"$v"';
  }
}

// ============================================================================
// 一个只在内存里的工作区能力（不碰文件系统）
// ============================================================================

class _MemWorkspace implements WorkspaceCapability {
  _MemWorkspace([Map<String, String>? initial]) : files = {...?initial};

  final Map<String, String> files;

  /// 每次调用的记录（验工具真的被执行了）。
  final List<String> calls = [];

  @override
  Future<CapabilityResult> list(String path, {bool recursive = false, int maxEntries = 200}) async {
    calls.add('list:$path');
    final names = files.keys.where((k) => k.startsWith(path.isEmpty ? '' : '$path/')).toList();
    return CapabilitySuccess(names.isEmpty ? '（空目录）' : names.join('\n'));
  }

  @override
  Future<CapabilityResult> read(String path, {int offset = 1, int limit = 0}) async {
    calls.add('read:$path');
    final v = files[path];
    if (v == null) return CapabilityFailure('文件不存在：$path');
    return CapabilitySuccess(v);
  }

  @override
  Future<CapabilityResult> write(String path, String content) async {
    calls.add('write:$path');
    files[path] = content;
    return CapabilitySuccess('已写入 $path（${content.length} 字符）');
  }

  @override
  Future<CapabilityResult> edit(String path, String oldText, String newText) async {
    calls.add('edit:$path');
    final v = files[path];
    if (v == null) return CapabilityFailure('文件不存在：$path');
    final n = oldText.allMatches(v).length;
    if (n == 0) return CapabilityFailure('没找到要替换的文本');
    if (n > 1) return CapabilityFailure('匹配到 $n 处，不唯一，拒绝替换');
    files[path] = v.replaceFirst(oldText, newText);
    return CapabilitySuccess('已替换 1 处');
  }

  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      CapabilityFailure('本测试不覆盖 applyPatch');

  @override
  Future<CapabilityResult> mkdir(String path) async {
    calls.add('mkdir:$path');
    return const CapabilitySuccess('已创建');
  }

  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async {
    calls.add('delete:$path');
    files.remove(path);
    return const CapabilitySuccess('已删除');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<CapabilityResult> findFiles(String pattern, {int maxResults = 200}) async =>
      CapabilitySuccess(files.keys.where((k) => k.contains(pattern)).join('\n'));

  @override
  Future<CapabilityResult> grepFiles(String pattern, {String pathFilter = '', int maxResults = 200}) async =>
      CapabilitySuccess('（无匹配）');

  @override
  Future<CapabilityResult> move(String from, String to) async {
    final v = files.remove(from);
    if (v == null) return const CapabilityFailure('源不存在');
    files[to] = v;
    return const CapabilitySuccess('已移动');
  }

  @override
  Future<CapabilityResult> copy(String from, String to) async {
    final v = files[from];
    if (v == null) return const CapabilityFailure('源不存在');
    files[to] = v;
    return const CapabilitySuccess('已复制');
  }
}

// ============================================================================
// 工具函数
// ============================================================================

HeraclesAgent _agent({
  required LLMClient client,
  WorkspaceCapability? workspace,
  RunOptions options = const RunOptions(maxTurns: 6, maxToolCalls: 20),
}) =>
    HeraclesAgent(
      config: const BackendConfig(
        apiKey: 'test-not-used',
        modelName: 'test-model',
        baseUrl: 'http://127.0.0.1:1', // 假 client 不会真的连它
      ),
      capabilities: Capabilities(workspace: workspace ?? _MemWorkspace()),
      options: options,
      client: client,
    );

/// 收集整个事件流，带超时。**超时就是失败** —— 那正是死锁的现形。
Future<List<HeraclesEvent>> _collect(
  Stream<HeraclesEvent> s, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final out = <HeraclesEvent>[];
  await for (final e in s.timeout(timeout)) {
    out.add(e);
  }
  return out;
}

void main() {
  group('事件桥（审计 §3.2 的死锁回归）', () {
    test('★★ run() 必须能播出事件，且以 Finished 收尾（死锁则超时）', () async {
      final client = _ScriptedClient([const _ScriptedTurn.text('你好，我是 Heracles。')]);
      final agent = _agent(client: client);

      // 10s 超时：原 bug（await close 无监听者）会永久挂住 ⇒ 这里超时失败。
      final events = await _collect(agent.run('打个招呼'));

      expect(events, isNotEmpty,
          reason: '★ 事件桥死锁的原 bug：一个事件都收不到、界面永远转圈');
      expect(events.any((e) => e is HeraclesFinished), isTrue,
          reason: '终态必须是 HeraclesFinished（否则 UI 不知道跑完了）');
      final fin = events.whereType<HeraclesFinished>().single;
      expect(fin.finalText, contains('Heracles'));
    });

    test('★★ 消费端提前取消也要收尾（不留悬空 run）', () async {
      final client = _ScriptedClient([const _ScriptedTurn.text('abc')]);
      final agent = _agent(client: client);

      // 只取第一个事件就走人 —— 模拟 UI 在 dispose 里 cancel 订阅。
      final sub = agent.run('x').listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      // 没有抛异常、没有挂住，就是通过。这里再等一小会儿确认没有未捕获异常。
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('工具调用往返：请求工具 → 真的执行 → 结果回填给模型', () async {
      final ws = _MemWorkspace({'a.txt': '原始内容'});
      final client = _ScriptedClient([
        const _ScriptedTurn.tool('read_file', {'path': 'a.txt'}),
        const _ScriptedTurn.text('文件里写的是：原始内容'),
      ]);
      final agent = _agent(client: client, workspace: ws);

      final events = await _collect(agent.run('看看 a.txt'));

      // ① 工具真的被执行了（不是只发了一轮文字）
      expect(ws.calls, contains('read:a.txt'),
          reason: '模型请求了 read_file，能力层必须真的被调用');

      // ② 有工具事件（UI 靠它画卡片）
      expect(events.whereType<HeraclesToolRequested>(), isNotEmpty);
      expect(events.whereType<HeraclesToolFinished>(), isNotEmpty);

      // ③ 第二次调用模型时，历史里必须有工具结果
      expect(client.calls, greaterThanOrEqualTo(2),
          reason: '模型要多跑一轮才能拿到工具结果');
      final second = client.seenMessages[1];
      final hasResult = second.any((m) => m is FunctionExecutionResultMessage);
      expect(hasResult, isTrue,
          reason: '★ 工具结果没回填 ⇒ 模型会重复调用同一个工具直到预算耗尽');

      // ④ 最终正文来自第二轮
      final fin = events.whereType<HeraclesFinished>().single;
      expect(fin.finalText, contains('原始内容'));
    });

    test('★★ 工具失败必须如实回填（不许谎称成功）', () async {
      final ws = _MemWorkspace(); // 空工作区 → 读必然失败
      final client = _ScriptedClient([
        const _ScriptedTurn.tool('read_file', {'path': '不存在.txt'}),
        const _ScriptedTurn.text('那个文件不存在。'),
      ]);
      final agent = _agent(client: client, workspace: ws);

      final events = await _collect(agent.run('读不存在的文件'));

      final fin = events.whereType<HeraclesToolFinished>().single;
      expect(fin.isError, isTrue, reason: '读不存在的文件必须标成失败');
      expect(fin.output, contains('不存在'));
    });
  });

  group('预算（ADR-033 的真预算）', () {
    test('★★ maxToolCalls 超限必须中止并说明"任务未完成"', () async {
      // 脚本让模型无限请求同一个工具
      final ws = _MemWorkspace({'a.txt': 'x'});
      final client = _ScriptedClient(
        [const _ScriptedTurn.tool('read_file', {'path': 'a.txt'})],
        repeatLast: true,
      );
      final agent = _agent(
        client: client,
        workspace: ws,
        options: const RunOptions(maxTurns: 50, maxToolCalls: 3),
      );

      final events = await _collect(agent.run('无限读同一个文件'));

      final failed = events.whereType<HeraclesFailed>();
      expect(failed, isNotEmpty,
          reason: '★ 预算超限必须以失败收尾，不能悄悄停（UI 会以为任务正常结束）');
      expect(failed.single.reason, contains('上限'),
          reason: '要说清是"到了上限"，不是"检测到循环"（那是另一种终止）');
      expect(failed.single.reason, contains('未完成'),
          reason: '必须明确告诉用户任务没做完');
    });

    test('预算内不误杀（3 次工具调用 + 上限 20 ⇒ 正常完成）', () async {
      final ws = _MemWorkspace({'a.txt': 'x'});
      final client = _ScriptedClient([
        const _ScriptedTurn.tool('read_file', {'path': 'a.txt'}),
        const _ScriptedTurn.tool('read_file', {'path': 'a.txt'}),
        const _ScriptedTurn.text('读完了。'),
      ]);
      final agent = _agent(client: client, workspace: ws);

      final events = await _collect(agent.run('读两次'));

      expect(events.whereType<HeraclesFailed>(), isEmpty);
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
    });
  });

  group('工具面', () {
    test('★★ 工具确实递给模型（不是"组装了但没传"）', () async {
      final client = _ScriptedClient([const _ScriptedTurn.text('ok')]);
      final agent = _agent(client: client);

      await _collect(agent.run('x'));

      expect(client.seenTools.first, isNotEmpty,
          reason: '★ 没传 tools ⇒ 模型永远不知道有哪些工具（旧审计 §3.3 #10 那类问题）');
      // 抽查几个关键工具名（21 个工具里的代表）
      expect(client.seenTools.first, containsAll(<String>['read_file', 'write_file', 'run_shell_command']));
    });

    test('能力缺失时工具仍可见、调用即失败并说明原因', () async {
      // 不传 apk 能力
      final client = _ScriptedClient([
        const _ScriptedTurn.tool('build_apk', {'projectDir': '.'}),
        const _ScriptedTurn.text('构建不可用。'),
      ]);
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm', baseUrl: 'http://127.0.0.1:1'),
        capabilities: Capabilities(workspace: _MemWorkspace()),
        options: const RunOptions(maxTurns: 6, maxToolCalls: 20),
        client: client,
      );

      final events = await _collect(agent.run('构建一个 APK'));

      final fin = events.whereType<HeraclesToolFinished>();
      expect(fin, isNotEmpty, reason: '工具应当"可见但调用即失败"，而不是干脆消失');
      expect(fin.single.isError, isTrue);
      expect(fin.single.output, contains('不支持'),
          reason: '失败原因要写"环境不支持"，不是"参数错"（模型才可能换路）');
    });
  });

  group('会话状态', () {
    test('同一实例里历史只增不减（第 2 次 run 不覆盖第 1 次）', () async {
      final ws = _MemWorkspace({'a.txt': 'x'});
      final client = _ScriptedClient([
        const _ScriptedTurn.tool('read_file', {'path': 'a.txt'}),
        const _ScriptedTurn.text('done'),
      ]);
      final agent = _agent(client: client, workspace: ws);

      await _collect(agent.run('第 1 次'));
      final h1 = agent.state!.history.messages.length;
      expect(h1, greaterThan(1), reason: '一次 run 结束后历史里应当有用户 + 模型 + 工具结果');

      // 同一实例再跑一次（脚本已用尽 ⇒ 返回"（脚本已用尽）"）
      await _collect(agent.run('第 2 次'));
      final h2 = agent.state!.history.messages.length;

      expect(h2, greaterThan(h1),
          reason: '★ 第二次 run 必须**追加**到同一份历史，不能把第一次覆盖掉');
    });
  });
}
