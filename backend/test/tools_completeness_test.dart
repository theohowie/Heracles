import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';
import 'support/tool_result.dart';

/// **工具完整性门禁** —— 32 个工具都要在、Schema 都要对。
///
/// ## 为什么这条测试重要
///
/// 工具是智能体唯一的"手"。少一个工具，模型就有一类任务做不了；
/// Schema 写错，模型填的参数会被拒。这类错误**不会崩溃**，
/// 只会表现为"模型好像有点笨" —— 所以必须有断言。
void main() {
  /// 全能力版（模拟真机环境）
  final fullCaps = Capabilities(
    workspace: _FakeWorkspace(),
    shell: _FakeShell(),
    deviceHealth: _FakeHealth(),
    apk: _FakeApk(),
    web: _FakeWeb(),
    memory: _FakeMemory(),
    git: _FakeGit(),
  );

  final factory = ToolFactory(fullCaps);
  final allTools = [
    ...buildFileTools(factory, fullCaps),
    ...buildShellTools(factory, fullCaps),
    ...buildFileManageTools(factory, fullCaps),
    ...buildInfoTools(factory, fullCaps),
    ...buildApkTools(factory, fullCaps),
    ...buildInteractionTools(
        factory, askGate: _FakeAskGate(), caps: fullCaps),
    ...buildGitTools(factory, fullCaps),
  ];
  final byName = {for (final t in allTools) t.name: t};

  group('工具数量与覆盖', () {
    test('★★★ 必须恰好 32 个工具（少一个就是一类任务做不了）', () {
      expect(allTools.length, 32,
          reason: '实际：${allTools.map((t) => t.name).join(", ")}');
    });

    test('★★★ 关键工具一个都不能少', () {
      const required = [
        // 文件读写
        'read_file', 'write_file', 'edit', 'apply_patch',
        'list_files', 'mkdir', 'find_files', 'grep_files',
        // 执行
        'run_shell_command',
        // 文件管理
        'delete_path', 'move_path', 'copy_path',
        // 信息
        'web_fetch', 'check_device_state',
        // APK
        'build_apk', 'apk_decompile', 'apk_recompile', 'apk_sign', 'install_apk',
        // 交互
        'ask_user', 'save_memory',
        // git（2026-10-27）：5 只读 + 4 改本地 + push + init
        'git_status', 'git_log', 'git_diff', 'git_branches', 'git_show_commit',
        'git_stage', 'git_unstage', 'git_commit', 'git_checkout',
        'git_push', 'git_init',
      ];
      for (final name in required) {
        expect(byName.containsKey(name), isTrue, reason: '缺少工具：$name');
      }
    });

    test('★★ 工具名不重复（重复会让模型不知道调哪个）', () {
      expect(byName.length, allTools.length);
    });

    test('★ 每个工具都有非空描述', () {
      for (final t in allTools) {
        expect(t.description.trim(), isNotEmpty, reason: '${t.name} 描述为空');
        expect(t.description.length > 15, isTrue,
            reason: '${t.name} 描述太短，模型无法判断何时用它');
      }
    });
  });

  group('Schema 类型正确性', () {
    test('★★★ 所有 integer 参数声明为 integer', () {
      final checks = {
        'read_file': ['offset', 'limit'],
        'list_files': ['max_entries'],
        'find_files': ['max_results'],
        'grep_files': ['max_results'],
        'run_shell_command': ['timeout_seconds'],
        'web_fetch': ['max_chars'],
      };
      for (final e in checks.entries) {
        final props = (byName[e.key]!.parameters['properties'] as Map)
            .cast<String, dynamic>();
        for (final p in e.value) {
          expect((props[p] as Map)['type'], 'integer',
              reason: '${e.key}.$p 必须是 integer');
        }
      }
    });

    test('★★★ 所有 boolean 参数声明为 boolean', () {
      final props =
          (byName['list_files']!.parameters['properties'] as Map).cast<String, dynamic>();
      expect((props['recursive'] as Map)['type'], 'boolean');

      final del =
          (byName['delete_path']!.parameters['properties'] as Map).cast<String, dynamic>();
      expect((del['recursive'] as Map)['type'], 'boolean');
    });

    test('★★★ ask_user 的 questions 是 array-of-object（深层类型）', () {
      final props =
          (byName['ask_user']!.parameters['properties'] as Map).cast<String, dynamic>();
      final questions = props['questions'] as Map;
      expect(questions['type'], 'array');
      final items = questions['items'] as Map;
      expect(items['type'], 'object');
      final itemProps = (items['properties'] as Map).cast<String, dynamic>();
      expect((itemProps['question'] as Map)['type'], 'string');
      expect((itemProps['options'] as Map)['type'], 'array');
      expect((itemProps['multi'] as Map)['type'], 'boolean');
    });
  });

  group('能力缺失时的行为', () {
    test('★★★ 没有 workspace ⇒ 文件工具仍可见，但调用即失败并说明原因', () async {
      final noWs = const Capabilities();
      final f = ToolFactory(noWs);
      final tools = buildFileTools(f, noWs);
      final read = tools.firstWhere((t) => t.name == 'read_file');

      final result = await read.executable!({'path': 'a.txt'});
      expect(textOf(result), contains('未执行'));
      expect(textOf(result), contains('不支持文件访问'),
          reason: '必须说清是"环境不支持"，不是"参数错"');
    });

    test('★★ 没有 askGate ⇒ ask_user 告知模型"自己决定"', () async {
      final f = ToolFactory(fullCaps);
      final tools = buildInteractionTools(f, askGate: null, caps: fullCaps);
      final ask = tools.firstWhere((t) => t.name == 'ask_user');

      final result = await ask.executable!({
        'questions': [
          {'question': '要覆盖吗？'}
        ]
      });
      expect(textOf(result), contains('未执行'));
      expect(textOf(result), contains('请自行做出合理决定'),
          reason: '要引导模型自己决策，而不是卡住');
    });
  });

  group('ask_user 的参数校验', () {
    Future<dynamic> call(Map<String, dynamic> args) async {
      final f = ToolFactory(fullCaps);
      final tools =
          buildInteractionTools(f, askGate: _FakeAskGate(answer: 'OK'), caps: fullCaps);
      return tools.firstWhere((t) => t.name == 'ask_user').executable!(args);
    }

    test('★★ questions 为空数组 ⇒ 报错', () async {
      final r = await call({'questions': []});
      expect(textOf(r), contains('非空数组'));
    });

    test('★★ question 缺失 ⇒ 报错并指出下标', () async {
      final r = await call({
        'questions': [
          {'options': ['a']}
        ]
      });
      expect(textOf(r), contains('questions[0]'));
    });

    test('★★ 用户没回答 ⇒ 明确说"没回答"，不编造', () async {
      final f = ToolFactory(fullCaps);
      final tools =
          buildInteractionTools(f, askGate: _FakeAskGate(answer: null), caps: fullCaps);
      final r = await tools
          .firstWhere((t) => t.name == 'ask_user')
          .executable!({
        'questions': [
          {'question': '选哪个？'}
        ]
      });
      expect(textOf(r), contains('用户没有回答'));
      // 必须引导它自己决策，而不是卡住或编一个答案
      expect(textOf(r), contains('最合理的决定'));
    });
  });

  group('APK 工具', () {
    test('★★ 没有 apk 能力 ⇒ 5 个 APK 工具都提示不支持', () async {
      final noApk = const Capabilities();
      final f = ToolFactory(noApk);
      final tools = buildApkTools(f, noApk);
      expect(tools.length, 5);
      for (final t in tools) {
        final r = await t.executable!({
          'project_dir': 'x',
          'apk_path': 'x.apk',
          'out_dir': 'out',
          'src_dir': 'src',
          'out_apk': 'out.apk',
        });
        expect(textOf(r), contains('未执行'), reason: '${t.name} 应提示未执行');
      }
    });
  });
}

// ============================================================================
// 测试替身
// ============================================================================

class _FakeWorkspace implements WorkspaceCapability {
  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> read(String path,
          {int offset = 1, int limit = 0}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> write(String path, String content) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> edit(String path, String o, String n) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> mkdir(String path) async => const CapabilitySuccess('');
  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async =>
      const CapabilitySuccess('');
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<CapabilityResult> findFiles(String pattern, {int maxResults = 200}) async =>
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

class _FakeShell implements ShellCapability {
  @override
  Future<CapabilityResult> run(String command,
          {Duration timeout = const Duration(minutes: 5),
          void Function(String chunk)? onOutput}) async =>
      const CapabilitySuccess('ok');
}

class _FakeHealth implements DeviceHealthCapability {
  @override
  Future<int?> batteryPercent() async => 80;
  @override
  Future<double?> temperatureCelsius() async => 35.0;
  @override
  Future<bool> isCharging() async => false;
}

class _FakeApk implements ApkCapability {
  @override
  Future<CapabilityResult> build({required String projectDir,
          void Function(String step)? onStep}) async =>
      const CapabilitySuccess('built');
  @override
  Future<CapabilityResult> decompile(String apkPath, String outDir) async =>
      const CapabilitySuccess('decompiled');
  @override
  Future<CapabilityResult> recompile({required String smaliDir,
          required String outApkPath,
          void Function(String step)? onStep}) async =>
      const CapabilitySuccess('recompiled');
  @override
  Future<CapabilityResult> sign(String apkPath) async =>
      const CapabilitySuccess('signed');
  @override
  Future<CapabilityResult> install(String apkPath) async =>
      const CapabilitySuccess('installed');
}

class _FakeWeb implements WebCapability {
  @override
  Future<CapabilityResult> fetch(String url, {int maxChars = 50000}) async =>
      const CapabilitySuccess('page');
}

class _FakeMemory implements MemoryCapability {
  @override
  Future<String> read() async => '';
  @override
  Future<CapabilityResult> append(String note) async =>
      const CapabilitySuccess('saved');
}

/// 假 git 能力（只为让工具"可用"，不验证行为）。
///
/// 行为验证在 `git_tools_test.dart`；这里只关心"工具存在且 schema 合法"。
class _FakeGit implements GitCapability {
  @override
  Future<bool> isRepository(String path) async => true;
  @override
  Future<CapabilityResult> status(String path) async =>
      const CapabilitySuccess('分支：main');
  @override
  Future<CapabilityResult> log(String path,
          {int limit = 20, String? branch}) async =>
      const CapabilitySuccess('1 条提交');
  @override
  Future<CapabilityResult> diff(String path,
          {bool staged = false, String? file}) async =>
      const CapabilitySuccess('1 项改动');
  @override
  Future<CapabilityResult> branches(String path) async =>
      const CapabilitySuccess('- main');
  @override
  Future<CapabilityResult> showCommit(String path,
          {required String id}) async =>
      const CapabilitySuccess('提交');
  @override
  Future<CapabilityResult> init(String path,
          {String defaultBranch = 'main'}) async =>
      const CapabilitySuccess('已初始化');
  @override
  Future<CapabilityResult> stage(String path,
          {List<String> paths = const []}) async =>
      const CapabilitySuccess('已暂存');
  @override
  Future<CapabilityResult> unstage(String path,
          {List<String> paths = const []}) async =>
      const CapabilitySuccess('已取消暂存');
  @override
  Future<CapabilityResult> commit(String path,
          {required String message,
          String? authorName,
          String? authorEmail}) async =>
      CapabilitySuccess('已提交：$message');
  @override
  Future<CapabilityResult> checkout(String path,
          {required String branch, bool create = false}) async =>
      CapabilitySuccess('已切到 $branch');
  @override
  Future<CapabilityResult> clone(
          {required String url,
          required String destPath,
          String? token,
          int? depth,
          void Function(String message)? onProgress}) async =>
      CapabilitySuccess('已克隆到 $destPath');
  @override
  Future<CapabilityResult> pull(String path, {String? token}) async =>
      const CapabilitySuccess('已拉取');
  @override
  Future<CapabilityResult> push(String path,
          {String? token, bool setUpstream = false}) async =>
      const CapabilitySuccess('已推送');
  @override
  Future<CapabilityResult> fetch(String path, {String? token}) async =>
      const CapabilitySuccess('已 fetch');
}

class _FakeAskGate implements AskGate {
  _FakeAskGate({this.answer = '用户选了 A'});
  final String? answer;

  @override
  Future<String?> askUser(List<AskQuestion> questions) async => answer;

  @override
  Future<bool> requestApproval({
    required String callId,
    required String toolName,
    required Map<String, String> args,
    required String risk,
    required String detail,
    required bool workspaceInside,
  }) async =>
      true;
}
