import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **词法检索 RAG**（R1-R3，2026-10-25 接线门禁；用户拍板"词法可以"）。
///
/// R1 索引管道：文本文件按行切分 → 倒排表 → （可持久化）。
/// R2 检索注入：token 重合打分 → top-K 片段，**每条带 文件:行号 出处**。
/// R3 质量策略：**混合检索** —— 正文关键词命中 + 文件名命中加权（+3/词）。
void main() {
  late _IdxWs ws;
  late WorkspaceIndex idx;

  setUp(() {
    ws = _IdxWs();
    idx = WorkspaceIndex();
  });

  test('★★★ R1：索引构建（按行切分、文本扩展名过滤、预算上限）', () async {
    await idx.build(ws, [
      'lib/math.dart', // 文本 ✓
      'logo.png', // 二进制扩展名 ✗ 不索引
      'a' * 600, // 超长路径 ✗
    ]);
    expect(idx.indexedFileCount, 1, reason: '只有 math.dart 进了索引');
    expect(idx.tokenCount, greaterThan(0));
    expect(idx.tokenCount, greaterThanOrEqualTo(2), reason: 'add/multiply 等 token');
  });

  test('★★★ R2：检索命中正确文件，片段带 文件:行号 出处', () async {
    await idx.build(ws, ['lib/math.dart', 'README.md']);
    final hits = idx.search('multiply function', maxResults: 3);
    expect(hits, isNotEmpty, reason: '有命中');
    final top = hits.first;
    expect(top.file, 'lib/math.dart');
    expect(top.line, greaterThan(0), reason: '出处带行号');
    expect(top.snippet, contains('multiply'));
    // render 的出处格式（R2"注明来源"）
    expect(top.render(), contains('lib/math.dart:'));
  });

  test('★★ R3：文件名加权 —— 问"math"，即使正文没有该词也命中', () async {
    await idx.build(ws, ['lib/math.dart', 'README.md']);
    // 'math' 在 math.dart 正文里没有（只有 add/multiply）—— 文件名通道命中
    final hits = idx.search('math');
    expect(hits, isNotEmpty, reason: '文件名通道：混合检索的另一半');
    expect(hits.first.file, 'lib/math.dart');
  });

  test('★★ R2：无命中返回空（调用方据此不注入）', () async {
    await idx.build(ws, ['lib/math.dart']);
    expect(idx.search('kubernetes部署'), isEmpty);
    expect(idx.search(''), isEmpty, reason: '空查询不检索');
  });

  test('★ R1：单文件读失败 ⇒ 跳过该文件不炸索引', () async {
    await idx.build(ws, ['lib/math.dart', 'broken.dart']);
    expect(idx.indexedFileCount, 1, reason: 'broken.dart 读失败被跳过');
  });

  test('★ R3 分词：ASCII 词 + CJK 二元组', () {
    final t1 = WorkspaceIndex.tokenize('Hello World hello');
    expect(t1, containsAll(['hello', 'world']));
    expect(t1.where((x) => x == 'hello').length, 1, reason: '去重');
    final t2 = WorkspaceIndex.tokenize('上下文压缩机制');
    expect(t2, contains('上下'), reason: 'CJK 二元组');
    expect(t2, contains('文压'), reason: '滑动二元组');
  });
}

class _IdxWs implements WorkspaceCapability {
  final files = <String, String>{
    'lib/math.dart': 'int add(int a, int b) => a + b;'
        '\nint multiply(int a, int b) => a * b;',
    'README.md': '# demo\nrun: flutter run',
    'logo.png': 'BINARY',
    'broken.dart': '', // read 会失败（_failRead 模拟）
  };
  final failRead = {'broken.dart'};

  @override
  Future<CapabilityResult> read(String path,
      {int offset = 1, int limit = 0}) async {
    if (failRead.contains(path)) {
      return const CapabilityFailure('读失败', isRetryable: false);
    }
    if (!files.containsKey(path)) {
      return const CapabilityFailure('文件不存在');
    }
    final lines = files[path]!.split('\n');
    final take = limit > 0 ? lines.take(limit) : lines;
    return CapabilitySuccess(take.join('\n'));
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return const CapabilitySuccess('ok');
  }

  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> mkdir(String path) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> edit(
          String path, String oldText, String newText) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> delete(String path,
          {bool recursive = false}) async =>
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
