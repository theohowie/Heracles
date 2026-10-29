/// **git 工具行为测试**（2026-10-27，Step 2）。
///
/// ## 测什么
///
/// 工具层只做三件事（见 `tool_factory.dart` 的核心原则）：
/// 1. JSON Schema 声明 → **这里验 schema 形状**
/// 2. 参数类型化取值 → **这里验"模型传错类型会怎样"**
/// 3. 调能力层 + 结果翻译 → **这里验"能力返回什么，工具就吐什么"**
///
/// ## 不测什么
///
/// 不测真实 git 行为（那是 `GitService` + 真机探针的事）。
/// 本文件全部用假实现，毫秒级。
library;

import 'package:dart_agent_core/dart_agent_core.dart' show Tool;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';
import 'support/tool_result.dart';

/// 记账式假 git：记录被调用的方法与参数，返回预设结果。
class _RecordingGit implements GitCapability {
  final calls = <String>[];

  /// 让某个方法返回失败（验失败翻译）。
  CapabilityResult? nextResult;

  CapabilityResult _ret(String tag) {
    calls.add(tag);
    return nextResult ?? CapabilitySuccess('OK: $tag');
  }

  @override
  Future<bool> isRepository(String path) async {
    calls.add('isRepository($path)');
    return true;
  }

  @override
  Future<CapabilityResult> status(String path) async => _ret('status($path)');

  @override
  Future<CapabilityResult> log(String path,
          {int limit = 20, String? branch}) async =>
      _ret('log($path, limit=$limit)');

  @override
  Future<CapabilityResult> diff(String path,
          {bool staged = false, String? file}) async =>
      _ret('diff($path, staged=$staged, file=$file)');

  @override
  Future<CapabilityResult> branches(String path) async => _ret('branches($path)');

  @override
  Future<CapabilityResult> showCommit(String path, {required String id}) async =>
      _ret('showCommit($path, $id)');

  @override
  Future<CapabilityResult> init(String path,
          {String defaultBranch = 'main'}) async =>
      _ret('init($path, $defaultBranch)');

  @override
  Future<CapabilityResult> stage(String path,
          {List<String> paths = const []}) async =>
      _ret('stage($path, ${paths.isEmpty ? 'all' : paths.join('|')})');

  @override
  Future<CapabilityResult> unstage(String path,
          {List<String> paths = const []}) async =>
      _ret('unstage($path, ${paths.isEmpty ? 'all' : paths.join('|')})');

  @override
  Future<CapabilityResult> commit(String path,
          {required String message,
          String? authorName,
          String? authorEmail}) async =>
      _ret('commit($path, "$message")');

  @override
  Future<CapabilityResult> checkout(String path,
          {required String branch, bool create = false}) async =>
      _ret('checkout($path, $branch, create=$create)');

  @override
  Future<CapabilityResult> clone(
          {required String url,
          required String destPath,
          String? token,
          int? depth,
          void Function(String message)? onProgress}) async =>
      _ret('clone($url, $destPath)');

  @override
  Future<CapabilityResult> pull(String path, {String? token}) async =>
      _ret('pull($path)');

  @override
  Future<CapabilityResult> push(String path,
          {String? token, bool setUpstream = false}) async =>
      _ret('push($path, upstream=$setUpstream)');

  @override
  Future<CapabilityResult> fetch(String path, {String? token}) async =>
      _ret('fetch($path)');
}

void main() {
  late _RecordingGit git;
  late List<Tool> tools;
  late Map<String, Tool> byName;

  setUp(() {
    git = _RecordingGit();
    final caps = Capabilities(git: git);
    tools = buildGitTools(ToolFactory(caps), caps);
    byName = {for (final t in tools) t.name: t};
  });

  /// 调一个工具并返回它吐给模型的值。
  ///
  /// `Tool.executable` 在 object 模式下的签名是 `(Map<String, dynamic>)`，
  /// 这里统一包一层，避免每个用例都写一遍 Function.apply。
  Future<dynamic> invoke(String name, [Map<String, dynamic> args = const {}]) async {
    final tool = byName[name]!;
    final fn = tool.executable!;
    // 工具返回 AgentToolResult（带 UI 用的 metadata）；这里取文本给断言用。
    return textOf(await fn(args));
  }

  group('工具清单与 schema 形状', () {
    test('★ git 工具恰好 11 个（数量变动必须显式改这条）', () {
      expect(tools.length, 11,
          reason: '实际：${tools.map((t) => t.name).join(", ")}');
    });

    test('★ 工具名不重复', () {
      expect(byName.length, tools.length);
    });

    test('★ 每个工具都有描述（>15 字符）且声明了参数 schema', () {
      for (final t in tools) {
        expect(t.description.length, greaterThan(15), reason: '${t.name} 描述太短');
        expect(t.parameters['type'], 'object', reason: '${t.name} 参数必须是 object');
      }
    });

    test('★ 只读工具的 path 参数有默认值 `.`（模型可以不传）', () {
      for (final name in [
        'git_status', 'git_log', 'git_diff', 'git_branches', 'git_show_commit'
      ]) {
        final props = byName[name]!.parameters['properties'] as Map;
        final path = props['path'] as Map;
        expect(path['default'], '.', reason: '$name 的 path 应有默认值');
      }
    });

    test('★ 改状态的工具把 path 也设为可选（默认工作区根）', () {
      // git_stage/commit/checkout 的 path 不是必填 —— 默认 `.` 即可，
      // 减少模型填错的机会。
      for (final name in ['git_stage', 'git_unstage', 'git_commit', 'git_checkout']) {
        final req = (byName[name]!.parameters['required'] as List).cast<String>();
        expect(req.contains('path'), isFalse,
            reason: '$name 的 path 不该是必填（默认 `.` 更省事）');
      }
    });

    test('★ 必填参数正确：commit 要 message、checkout 要 branch', () {
      expect((byName['git_commit']!.parameters['required'] as List).cast<String>(),
          contains('message'));
      expect((byName['git_checkout']!.parameters['required'] as List).cast<String>(),
          contains('branch'));
      expect((byName['git_show_commit']!.parameters['required'] as List).cast<String>(),
          contains('id'));
    });

    test('★ git_log 的 limit 有下限与上限（与契约常量一致）', () {
      final props = byName['git_log']!.parameters['properties'] as Map;
      final limit = props['limit'] as Map;
      expect(limit['minimum'], 1);
      expect(limit['maximum'], ContractGit.maxLogLimit);
      expect(limit['default'], ContractGit.defaultLogLimit);
    });

    test('★ git_init 的默认分支名来自契约常量', () {
      final props = byName['git_init']!.parameters['properties'] as Map;
      expect((props['default_branch'] as Map)['default'],
          ContractGit.defaultBranch);
    });
  });

  group('参数传递：模型填什么，能力层就收到什么', () {
    test('path 不传 ⇒ 能力层收到 `.`', () async {
      await invoke('git_status');
      expect(git.calls.last, 'status(.)');
    });

    test('path 传了 ⇒ 原样透传', () async {
      await invoke('git_status', {'path': 'sub/dir'});
      expect(git.calls.last, 'status(sub/dir)');
    });

    test('★ git_log 不传 limit ⇒ 用契约默认值', () async {
      await invoke('git_log');
      expect(git.calls.last, contains('limit=${ContractGit.defaultLogLimit}'));
    });

    test('git_log 传 limit ⇒ 原样透传', () async {
      await invoke('git_log', {'limit': 5});
      expect(git.calls.last, contains('limit=5'));
    });

    test('★ git_stage 不传 paths ⇒ 全量（能力层收到空列表）', () async {
      await invoke('git_stage');
      expect(git.calls.last, 'stage(., all)');
    });

    test('git_stage 传 paths ⇒ 原样透传', () async {
      await invoke('git_stage', {
        'paths': ['a.txt', 'b.txt']
      });
      expect(git.calls.last, 'stage(., a.txt|b.txt)');
    });

    test('★ 模型把 paths 写成单个字符串 ⇒ 被 schema 挡下（不是静默宽容）', () async {
      // 实测纠偏：原本想宽容（"a.txt" 当成 ["a.txt"]），但 schema 校验在
      // 更早一层就按 `type: array` 拒绝了。那条**正是我们要的** ——
      // 与 optionalInt 的立场一致：明确报类型错，模型一轮就能改对；
      // 静默宽容会让它一直错下去。
      final r = await invoke('git_stage', {'paths': 'a.txt'});
      expect(r as String, startsWith('未执行：'));
      expect(r, contains('paths'));
      expect(r, contains('array'));
      expect(git.calls, isEmpty, reason: '★ 类型错误不该进能力层');
    });

    test('git_commit 的 message 原样透传', () async {
      await invoke('git_commit', {'message': '修好了登录页的 Bug'});
      expect(git.calls.last, 'commit(., "修好了登录页的 Bug")');
    });

    test('git_checkout 的 create 默认 false', () async {
      await invoke('git_checkout', {'branch': 'dev'});
      expect(git.calls.last, 'checkout(., dev, create=false)');
    });

    test('git_checkout create=true 传到能力层', () async {
      await invoke('git_checkout', {'branch': 'dev', 'create': true});
      expect(git.calls.last, 'checkout(., dev, create=true)');
    });

    test('git_push 的 set_upstream 默认 false', () async {
      await invoke('git_push');
      expect(git.calls.last, 'push(., upstream=false)');
    });
  });

  group('参数校验：不该进能力层的输入被挡在工具层', () {
    // ★ 实测纠偏：参数错误**不抛异常**，而是返回 `未执行：…` 文本。
    //
    // 原因在 `tool_factory.dart` 的 `build()` —— schema 校验与 `run()` 都包在
    // try/catch 里，异常被转成 `_fail(...)` 的字符串。这是**对的**：
    // 模型读得懂"参数错在哪"，读不懂 `ArgumentError` 栈。
    // 而 `_looksLikeFailure` 认得 `未执行：` 前缀 ⇒ 框架仍会标 isError=true。
    //
    // 所以这里断言的是**文本**，不是 throws。
    test('★ git_commit 缺 message ⇒ 返回"未执行"并指明缺哪个参数', () async {
      final r = await invoke('git_commit') as String;
      expect(r, startsWith('未执行：'));
      expect(r, contains('message'));
      expect(git.calls, isEmpty, reason: '★ 参数错误不该进能力层');
    });

    test('★ git_checkout 缺 branch ⇒ 返回"未执行"', () async {
      final r = await invoke('git_checkout') as String;
      expect(r, startsWith('未执行：'));
      expect(r, contains('branch'));
      expect(git.calls, isEmpty);
    });

    test('★ git_show_commit 缺 id ⇒ 返回"未执行"', () async {
      final r = await invoke('git_show_commit') as String;
      expect(r, startsWith('未执行：'));
      expect(r, contains('id'));
      expect(git.calls, isEmpty);
    });

    test('★ git_log 的 limit 传字符串 ⇒ 被 schema 拒绝（不静默转换）', () async {
      final r = await invoke('git_log', {'limit': '5'}) as String;
      expect(r, startsWith('未执行：'));
      expect(r, contains('limit'));
      expect(r, contains('integer'));
      expect(git.calls, isEmpty,
          reason: '★ 类型错误要明确拒绝，宽容会让模型一直错下去');
    });

    test('★ git_diff 的 staged 传字符串 ⇒ 被 schema 拒绝', () async {
      final r = await invoke('git_diff', {'staged': 'true'}) as String;
      expect(r, startsWith('未执行：'));
      expect(r, contains('staged'));
    });

    test('★ 未知参数名 ⇒ 被 schema 拒绝（防模型编造参数）', () async {
      final r = await invoke('git_status', {'reop': '.'}) as String;
      expect(r, startsWith('未执行：'));
      expect(r, contains('reop'));
    });
  });

  group('结果翻译：成功与失败都如实回给模型', () {
    test('成功 ⇒ 原样返回能力层的文本（不加 JSON 信封）', () async {
      final r = await invoke('git_status');
      expect(r, 'OK: status(.)');
    });

    test('★ 失败 ⇒ 原样返回失败原因（模型读得懂）', () async {
      git.nextResult = const CapabilityFailure('不是 git 仓库', isRetryable: true);
      final r = await invoke('git_status');
      expect(r, contains('不是 git 仓库'));
      expect(r, contains('可换个方式重试'),
          reason: 'isRetryable=true ⇒ 前缀要告诉模型这条路可以重试');
    });

    test('★ 可重试与不可重试的失败都被翻译（前缀由 ToolFactory 统一加）', () async {
      git.nextResult =
          const CapabilityFailure('这条路不通', isRetryable: false);
      final r = await invoke('git_status');
      expect(r, contains('这条路不通'));
    });
  });

  group('能力缺失：工具仍在列表里，调用即失败并明说原因', () {
    test('★ 没有 git 能力 ⇒ 工具仍然被构建出来（11 个都在）', () {
      const caps = Capabilities(); // 没有 git
      final t = buildGitTools(const ToolFactory(caps), caps);
      expect(t, hasLength(11),
          reason: '★ 缺能力也要列出来 —— 否则模型会凭记忆乱调，报"未知工具"更难查');
    });

    test('★ 调用时给出"环境不支持"而不是崩', () async {
      const caps = Capabilities();
      final t = buildGitTools(const ToolFactory(caps), caps);
      final status = t.firstWhere((x) => x.name == 'git_status');
      final r = textOf(await status.executable!(<String, dynamic>{}));
      expect(r, contains('不支持'));
      expect(r, contains('git'), reason: '要说清是"不支持 git"而不是别的');
    });
  });
}
