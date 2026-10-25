import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **K3 大改写门禁**（2026-10-25 接线门禁）。
///
/// `write_file` 对**已存在且已读**的文件做 200+ 行整文重写时要求显式声明：
/// 拦截并指路（edit/apply_patch 小步优先；确需全量重写则在 content 末尾加
/// `[FULL_REWRITE]`）。软门禁而非硬拒绝 —— 格式化/重新生成类任务确实需要
/// 全量重写，显式声明即可通过。
///
/// 新文件与 < 200 行的小改写不受限。
void main() {
  (List<Tool>, _MemWorkspace) toolsWith() {
    final ws = _MemWorkspace();
    final factory = ToolFactory(ws.capabilities);
    final tools = buildFileTools(factory, ws.capabilities,
        tracker: EditReadTracker());
    return (tools, ws);
  }

  Future<dynamic> call(Tool t, Map<String, dynamic> args) async =>
      await t.executable!(args);

  Tool pick(List<Tool> tools, String name) =>
      tools.firstWhere((t) => t.name == name);

  test('★★★ 已读文件写 200+ 行 ⇒ 被拦，错误信息指路 [FULL_REWRITE]', () async {
    final (tools, ws) = toolsWith();
    ws.files['big.dart'] = '旧内容';
    await call(pick(tools, 'read_file'), {'path': 'big.dart'});

    final big = List.filled(250, 'x').join('\n');
    final out = await call(
        pick(tools, 'write_file'), {'path': 'big.dart', 'content': big});

    expect(out, contains('edit'));
    expect(out, contains('[FULL_REWRITE]'));
    expect(ws.files['big.dart'], '旧内容', reason: '拦截即未写');
  });

  test('★★ 带 [FULL_REWRITE] 声明 ⇒ 放行（软门禁：显式选择）', () async {
    final (tools, ws) = toolsWith();
    ws.files['big.dart'] = '旧内容';
    await call(pick(tools, 'read_file'), {'path': 'big.dart'});

    final big = '${List.filled(250, 'x').join('\n')}\n[FULL_REWRITE]';
    final out = await call(
        pick(tools, 'write_file'), {'path': 'big.dart', 'content': big});

    expect(out, isNot(contains('未执行')));
    expect(ws.files['big.dart'], contains('FULL_REWRITE'));
  });

  test('★ 新文件不受限（>200 行随便写——本来就是全量创建）', () async {
    final (tools, ws) = toolsWith();
    final big = List.filled(250, 'x').join('\n');
    final out = await call(
        pick(tools, 'write_file'), {'path': 'fresh.dart', 'content': big});
    expect(out, isNot(contains('未执行')));
    expect(ws.files['fresh.dart'], contains('x'));
  });

  test('★ 小改写（< 200 行）不受限', () async {
    final (tools, ws) = toolsWith();
    ws.files['s.dart'] = '旧';
    await call(pick(tools, 'read_file'), {'path': 's.dart'});
    final out = await call(
        pick(tools, 'write_file'), {'path': 's.dart', 'content': '新的小内容'});
    expect(out, isNot(contains('未执行')));
    expect(ws.files['s.dart'], '新的小内容');
  });
}

/// 内容存内存的最小工作区。
class _MemWorkspace implements WorkspaceCapability {
  final files = <String, String>{};

  Capabilities get capabilities => Capabilities(workspace: this);

  @override
  Future<CapabilityResult> read(String path,
      {int offset = 1, int limit = 0}) async {
    if (!files.containsKey(path)) return CapabilityFailure('文件不存在：$path');
    return CapabilitySuccess(files[path]!);
  }

  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return CapabilitySuccess('已写入 $path');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<CapabilityResult> edit(
      String path, String oldText, String newText) async {
    if (!files.containsKey(path)) return CapabilityFailure('文件不存在');
    files[path] = files[path]!.replaceFirst(oldText, newText);
    return const CapabilitySuccess('已替换');
  }

  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('');

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
