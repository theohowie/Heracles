import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **"先读再改"强制 e2e**（2026-10-24，K1 —— Claude Code FileEditTool 形态）。
///
/// 钉住 `EditReadTracker` + 文件工具的准入语义：
///
/// 1. `edit` 没读过 ⇒ 拒绝（错误信息给模型指路：先 read_file）；
/// 2. read 之后 edit ⇒ 放行；
/// 3. `write_file` 覆盖**已存在**文件：没读过 ⇒ 拒绝；读过 ⇒ 放行；
///    **新文件**随便写（Claude Code 同规则：Write 只对已存在文件要求先读）；
/// 4. 本会话写过 ⇒ 算"知道内容"（自己写的不必再读）；
/// 5. `delete_path` 让记账失效；`move_path` 迁移记账；
/// 6. tracker 为 null（旧行为入口）⇒ 不强制 —— 兼容既有测试/CLI。
///
/// ## 为什么这是 K1 的"工具层强制"
///
/// 提示词说"先读再改"是**劝**；这里是**拦** —— 没读过就 edit 直接失败，
/// 模型只能去 read_file。AGENTS.md 铁律："抗幻觉必须由架构保证，不得依赖
/// 提示词" —— 这条把 K1 的最后一半从提示词搬进了工具层。
void main() {
  /// 组装：真实 ToolFactory + 最小伪造工作区（内容存内存）。
  (List<Tool>, _MemWorkspace) toolsWith({EditReadTracker? tracker}) {
    final ws = _MemWorkspace();
    final factory = ToolFactory(Capabilities(workspace: ws));
    final tools = [
      ...buildFileTools(factory, ws.capabilities, tracker: tracker),
      ...buildFileManageTools(factory, ws.capabilities, tracker: tracker),
    ];
    return (tools, ws);
  }

  Future<dynamic> call(Tool t, Map<String, dynamic> args) async {
    final r = await t.executable!(args);
    return r is String ? r : r;
  }

  group('edit —— 没读就改 ⇒ 拒绝', () {
    test('★★★ 没读过 ⇒ 拒绝，错误信息指路 read_file', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());
      ws.files['a.dart'] = 'int add(int a, int b) => a + b;';

      final out = await call(pick(tools, 'edit'),
          {'path': 'a.dart', 'old_string': 'add', 'new_string': 'sub'});

      expect(out, contains('还没被读过'));
      expect(out, contains('read_file'));
      expect(ws.files['a.dart'], contains('add'),
          reason: '★ 文件必须原样未动 —— 拒绝就是没执行');
    });

    test('★★★ read 之后 edit ⇒ 放行，且内容真的变了', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());
      ws.files['a.dart'] = 'int add(int a, int b) => a + b;';

      await call(pick(tools, 'read_file'), {'path': 'a.dart'});
      final out = await call(pick(tools, 'edit'),
          {'path': 'a.dart', 'old_string': 'add', 'new_string': 'sub'});

      expect(out, isNot(contains('未执行')), reason: '读过之后必须放行');
      expect(ws.files['a.dart'], contains('sub'), reason: '文件真的变了');
    });

    test('★ 本会话写过 ⇒ 算知道内容，edit 放行', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());

      await call(pick(tools, 'write_file'),
          {'path': 'b.dart', 'content': 'class B {}'});
      final out = await call(pick(tools, 'edit'),
          {'path': 'b.dart', 'old_string': 'class B', 'new_string': 'class C'});

      expect(out, isNot(contains('未执行')), reason: '自己写的内容就是知道的');
      expect(ws.files['b.dart'], contains('class C'));
    });
  });

  group('write_file —— 只对已存在文件要求先读', () {
    test('★★★ 新文件 ⇒ 直接写（Write 只对已存在文件要求先读）', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());
      final out = await call(pick(tools, 'write_file'),
          {'path': 'new.dart', 'content': 'x'});
      expect(out, isNot(contains('未执行')));
      expect(ws.files['new.dart'], 'x');
    });

    test('★★★ 已存在 + 没读过 ⇒ 拒绝', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());
      ws.files['old.dart'] = '别人的内容';

      final out = await call(pick(tools, 'write_file'),
          {'path': 'old.dart', 'content': '我的内容'});

      expect(out, contains('还没有读过'));
      expect(ws.files['old.dart'], '别人的内容',
          reason: '★ 盲覆盖必须被挡住 —— 这是这条防线存在的意义');
    });

    test('★★ 已存在 + 读过 ⇒ 放行', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());
      ws.files['old.dart'] = '旧内容';
      await call(pick(tools, 'read_file'), {'path': 'old.dart'});

      final out = await call(pick(tools, 'write_file'),
          {'path': 'old.dart', 'content': '新内容'});

      expect(out, isNot(contains('未执行')));
      expect(ws.files['old.dart'], '新内容');
    });
  });

  group('记账维护', () {
    test('★★ delete 让路径失效；move 迁移记账', () async {
      final (tools, ws) = toolsWith(tracker: EditReadTracker());
      ws.files['a.dart'] = 'A';
      ws.files['b.dart'] = 'B';
      await call(pick(tools, 'read_file'), {'path': 'a.dart'});
      await call(pick(tools, 'read_file'), {'path': 'b.dart'});

      await call(pick(tools, 'delete_path'), {'path': 'a.dart'});
      ws.files['a.dart'] = 'A(重建)'; // 外部又出现了同名文件
      final outA = await call(pick(tools, 'edit'),
          {'path': 'a.dart', 'old_string': 'A', 'new_string': 'x'});
      expect(outA, contains('还没被读过'),
          reason: '删过之后旧记账必须失效（重建的同名文件没读过）');

      await call(pick(tools, 'move_path'), {'from': 'b.dart', 'to': 'c.dart'});
      final outC = await call(pick(tools, 'edit'),
          {'path': 'c.dart', 'old_string': 'B', 'new_string': 'x'});
      expect(outC, isNot(contains('未执行')),
          reason: 'move 后记账迁到新路径，edit 放行');
      expect(ws.files['c.dart'], contains('x'));
    });

    test('★ tracker 为 null ⇒ 不强制（旧行为入口，兼容既有调用方）', () async {
      final (tools, ws) = toolsWith(); // 不传 tracker
      ws.files['a.dart'] = 'A';
      final out = await call(pick(tools, 'edit'),
          {'path': 'a.dart', 'old_string': 'A', 'new_string': 'x'});
      expect(out, isNot(contains('未执行')), reason: '没有 tracker 就没有强制（旧行为）');
      expect(ws.files['a.dart'], contains('x'));
    });
  });
}

/// 内容存内存的最小工作区 —— 只实现本文件用到的方法。
class _MemWorkspace implements WorkspaceCapability {
  final files = <String, String>{};

  /// 自我引用的能力聚合（组装工具时用）
  Capabilities get capabilities => Capabilities(workspace: this);

  @override
  Future<CapabilityResult> read(String path,
      {int offset = 1, int limit = 0}) async {
    if (!files.containsKey(path)) {
      return CapabilityFailure('文件不存在：$path');
    }
    final lines = files[path]!.split('\n');
    final buf = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      buf.writeln('${(i + 1).toString().padLeft(5)}| ${lines[i]}');
    }
    return CapabilitySuccess(buf.toString().trimRight());
  }

  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return CapabilitySuccess('已写入 $path（${content.length} 字符）');
  }

  @override
  Future<CapabilityResult> edit(
      String path, String oldText, String newText) async {
    if (!files.containsKey(path)) return CapabilityFailure('文件不存在：$path');
    final c = files[path]!;
    if (!c.contains(oldText)) {
      return CapabilityFailure('old_string 在文件中未找到（或不止一处）');
    }
    files[path] = c.replaceFirst(oldText, newText);
    return CapabilitySuccess('已替换');
  }

  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async {
    return CapabilityFailure('本测试不实现 applyPatch');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async {
    files.remove(path);
    return CapabilitySuccess('已删除 $path');
  }

  @override
  Future<CapabilityResult> move(String from, String to) async {
    if (!files.containsKey(from)) return CapabilityFailure('文件不存在：$from');
    files[to] = files.remove(from)!;
    return CapabilitySuccess('已移动');
  }

  @override
  Future<CapabilityResult> copy(String from, String to) async {
    if (!files.containsKey(from)) return CapabilityFailure('文件不存在：$from');
    files[to] = files[from]!;
    return CapabilitySuccess('已复制');
  }

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
}

/// 按名字取工具（断言用）。
Tool pick(List<Tool> tools, String name) =>
    tools.firstWhere((t) => t.name == name);
