import 'dart:io';

import 'package:heracles_backend/src/capability/capabilities.dart';
import 'package:heracles_backend/src/capability/local_workspace_capability.dart';
import 'package:heracles_backend/src/contract/contract.dart';
import 'package:test/test.dart';

/// **工作区能力门禁** —— 尤其钉住两处编译期错误背后的**语义**。
///
/// 这个文件补的是审计里"从来没被跑过"的两条路径：
///
/// 1. `_applyHunk` 的返回类型（`return_of_invalid_type`）
///    —— 旧声明是 `CapabilityResult`、末尾却 `return <List<String>>`，
///    调用处靠 `as List<String>` 强转兜着。编译器报错挡住了编译，
///    但**"补丁猜错就静默改坏代码"这条红线没有任何测试**。
/// 2. `Directory.list()` 是 `Stream` 不是 `List`（`undefined_getter: isNotEmpty`）
///    —— `delete(recursive: false)` 要能判断"目录非空"，且必须
///    **一个文件都不删**（P1-3 的取舍）。
///
/// 用真实临时目录跑（不是 mock）：`dart:io` 的行为是这些断言的依据，
/// mock 掉就只是在测 mock。
void main() {
  late Directory tmp;
  late LocalWorkspaceCapability ws;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('heracles_ws_test_');
    ws = LocalWorkspaceCapability(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Future<String> readRaw(String rel) =>
      File('${tmp.path}${Platform.pathSeparator}$rel').readAsString();

  Future<void> writeRaw(String rel, String content) async {
    final f = File('${tmp.path}${Platform.pathSeparator}$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  /// 断言是成功，并返回正文。
  String asSuccess(CapabilityResult r) {
    expect(r, isA<CapabilitySuccess>(),
        reason: '期望成功，实际：${r is CapabilityFailure ? r.reason : r}');
    return (r as CapabilitySuccess).data;
  }

  /// 断言是失败，并返回原因。
  String asFailure(CapabilityResult r) {
    expect(r, isA<CapabilityFailure>(),
        reason: '期望失败，实际成功了：${r is CapabilitySuccess ? r.data : r}');
    return (r as CapabilityFailure).reason;
  }

  // ==========================================================================
  group('apply_patch —— _applyHunk 的返回类型', () {
    test('★★★ 正常 hunk 打上，文件内容真的变了', () async {
      await writeRaw('a.txt', 'one\ntwo\nthree\n');

      final r = await ws.applyPatch('a.txt', '''
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
''');

      asSuccess(r);
      expect(await readRaw('a.txt'), 'one\nTWO\nthree\n');
    });

    test('★★★ 补丁不许吃掉文件末尾的换行（重写前就有的真 bug）', () async {
      // `LineSplitter.convert('a\nb\n')` ⇒ ['a','b']，末尾换行在切分时没了。
      // 旧写法 `lines.join('\n')` 写回 ⇒ 'a\nb' ⇒ 每打一次补丁就少一个换行。
      // 这条是本次重写中新测试抓出来的（原先没有 apply_patch 的换行覆盖）。
      await writeRaw('t.txt', 'one\ntwo\n');

      asSuccess(await ws.applyPatch('t.txt', '''
@@ -1,2 +1,2 @@
 one
-two
+TWO
'''));

      final after = await readRaw('t.txt');
      expect(after, 'one\nTWO\n');
      expect(after.endsWith('\n'), isTrue, reason: '末尾换行必须保住');
    });

    test('★★ 原文件本来就没有末尾换行 ⇒ 打完补丁也别多加', () async {
      await writeRaw('noeol.txt', 'one\ntwo'); // 刻意无末尾 \n

      asSuccess(await ws.applyPatch('noeol.txt', '''
@@ -1,2 +1,2 @@
 one
-two
+TWO
'''));

      expect(await readRaw('noeol.txt'), 'one\nTWO',
          reason: '不要"顺手美化"用户的文件');
    });

    test('★★★ CRLF 文件打完补丁仍必须是 CRLF（不许整文件改行尾）', () async {
      // LineSplitter 会把 \r\n 也当分隔符并**丢掉 \r** ⇒ 若按 '\n' 拼回，
      // 整个文件每一行的行尾都被改写了（Windows 项目 git diff 会整文件变红）。
      await writeRaw('crlf.txt', 'one\r\ntwo\r\nthree\r\n');

      asSuccess(await ws.applyPatch('crlf.txt', '''
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
'''));

      final after = await readRaw('crlf.txt');
      expect(after, 'one\r\nTWO\r\nthree\r\n');
      expect(after.contains('\r\n'), isTrue, reason: '行尾风格必须保住');
      expect(after.replaceAll('\r\n', '').contains('\n'), isFalse,
          reason: '不许混进裸 LF（那会把文件变成混合行尾）');
    });

    test('★★ 只有一个换行的文件打完补丁不许变成空文件', () async {
      // `LineSplitter.convert('\n')` ⇒ [''] ⇒ join ⇒ '' ⇒ 若不还回换行，
      // 文件就从"一个换行"变成"完全空"（一行变零行）
      await writeRaw('nl.txt', '\n');

      await ws.applyPatch('nl.txt', '''
@@ -1,1 +1,1 @@
-
+x
''');

      final after = await readRaw('nl.txt');
      expect(after, isNotEmpty, reason: '文件不许被补丁清空');
      expect(after, 'x\n');
    });

    test('★ 末尾多个空行逐字节保真（实测结论，防"顺手压缩空行"）', () async {
      await writeRaw('blank.txt', 'a\n\n\n');

      asSuccess(await ws.applyPatch('blank.txt', '''
@@ -1,1 +1,1 @@
-a
+A
'''));

      expect(await readRaw('blank.txt'), 'A\n\n\n',
          reason: '末尾空行数不该被补丁改动');
    });

    test('★ 混合行尾会被统一成 CRLF（已知边界，钉住现有行为）', () async {
      // 这条**不是**在说"这是对的"，而是把当前行为钉住：
      // 探测到 \r\n 就整文件按 CRLF 拼回 ⇒ "a\r\nb\n" 变成 "a\r\nb\r\n"。
      // 将来若改成"逐行保真"，这条测试会红 —— 那时应该更新它而不是删掉。
      await writeRaw('mixed.txt', 'a\r\nb\n');

      asSuccess(await ws.applyPatch('mixed.txt', '''
@@ -1,2 +1,2 @@
 a
-b
+B
'''));

      expect(await readRaw('mixed.txt'), 'a\r\nB\r\n');
    });

    test('★★★ 匹配不上 ⇒ 返回 CapabilityFailure（不是抛、不是强转崩）', () async {
      await writeRaw('a.txt', 'alpha\nbeta\ngamma\n');

      final r = await ws.applyPatch('a.txt', '''
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
''');

      final reason = asFailure(r);
      // 三要素：哪个 hunk / 期望什么 / 实际是什么
      expect(reason, contains('第 1 个 hunk'), reason: '必须说清是哪个 hunk');
      expect(reason, contains('期望读到 3 行'), reason: '必须说清期望什么');
      expect(reason, contains('实际是'), reason: '必须说清实际是什么');
      // ★ 最关键的一条：匹配不上**绝不改文件**
      expect(await readRaw('a.txt'), 'alpha\nbeta\ngamma\n',
          reason: '补丁失败时文件必须一字未动（"绝不尽力猜"）');
    });

    test('★★★ 失败时给出的提示里带真实内容（模型据此自愈）', () async {
      await writeRaw('a.txt', 'alpha\nbeta\n');
      final r = await ws.applyPatch('a.txt', '''
@@ -1,1 +1,1 @@
-nonexistent
+x
''');
      final reason = asFailure(r);
      expect(reason, contains('alpha'), reason: '要回显文件实际内容，模型才知道怎么改');
    });

    test('★★ 空文件上打补丁 ⇒ 不崩（clamp(0, -1) 那条边界）', () async {
      await writeRaw('empty.txt', '');

      // 空文件 ⇒ lines 为空 ⇒ 旧写法 `claimed.clamp(0, lines.length - 1)`
      // 就是 `clamp(0, -1)`，直接抛 ArgumentError（lowerLimit > upperLimit）
      final r = await ws.applyPatch('empty.txt', '''
@@ -1,1 +1,1 @@
-should-not-exist
+replaced
''');

      expect(() => asFailure(r), returnsNormally);
      expect(await readRaw('empty.txt'), '', reason: '失败时不该动空文件');
    });

    test('★★ 多个 hunk 一次打上（从后往前打，行号不互相顶偏）', () async {
      await writeRaw('multi.txt', 'a\nb\nc\nd\ne\nf\ng\n');

      final r = await ws.applyPatch('multi.txt', '''
@@ -1,2 +1,2 @@
 a
-b
+B
@@ -6,2 +6,2 @@
 f
-g
+G
''');

      asSuccess(r);
      // 第二个 hunk 是 `f` 作上下文、`g`→`G` 替换 ⇒ 只有 g 变大写
      expect(await readRaw('multi.txt'), 'a\nB\nc\nd\ne\nf\nG\n',
          reason: '两个 hunk 都要生效，且上下文行不被改写');
    });

    test('★★ 补丁里没有 @@ 头 ⇒ 明确说要 unified diff 格式', () async {
      await writeRaw('a.txt', 'x\n');
      final reason = asFailure(await ws.applyPatch('a.txt', '这不是补丁'));
      expect(reason, contains('@@'));
      expect(reason, contains('unified diff'));
    });

    test('★★ 文件不存在 ⇒ 失败并说明（不创建新文件）', () async {
      final reason = asFailure(await ws.applyPatch('nope.txt', '''
@@ -1,1 +1,1 @@
-a
+b
'''));
      expect(reason, contains('文件不存在'));
      expect(await File('${tmp.path}/nope.txt').exists(), isFalse);
    });
  });

  // ==========================================================================
  group('read —— 行号前缀（宽度来自契约常量）', () {
    test('★★★ 行号前缀宽度必须是 ContractWorkspace.lineNumberWidth', () async {
      await writeRaw('n.txt', 'first\nsecond\n');
      final text = asSuccess(await ws.read('n.txt'));

      final firstLine = text.split('\n').first;
      final bar = firstLine.indexOf('|');
      expect(bar, ContractWorkspace.lineNumberWidth,
          reason: '`|` 之前的行号区必须正好 ${ContractWorkspace.lineNumberWidth} 字符');
      expect(firstLine.substring(0, bar).trim(), '1');
      expect(firstLine.substring(bar), '| first');
    });

    test('★★ 行号右对齐（列对齐是模型对 oldText 的前提）', () async {
      final lines = List.generate(12, (i) => 'L${i + 1}');
      await writeRaw('many.txt', '${lines.join('\n')}\n');

      final text = asSuccess(await ws.read('many.txt'));
      final rendered = text.split('\n');
      // 前 9 行是 "    1| ..." 形状：宽度一致才叫对齐
      for (var i = 0; i < 9; i++) {
        expect(rendered[i].indexOf('|'), ContractWorkspace.lineNumberWidth);
      }
      // "   12| " —— 两位数也要在同一列
      expect(rendered[11].indexOf('|'), ContractWorkspace.lineNumberWidth);
      expect(rendered[11].trimLeft().startsWith('12|'), isTrue);
    });

    test('★★ offset / limit 分页（继续读的提示要对）', () async {
      await writeRaw('p.txt', 'a\nb\nc\nd\n');
      final text = asSuccess(await ws.read('p.txt', offset: 2, limit: 2));

      expect(text, contains('| b'));
      expect(text, contains('| c'));
      expect(text, isNot(contains('| a')));
      expect(text, contains('offset=4'), reason: '要告诉模型下一段的 offset');
    });

    test('★★ 二进制文件（含 NUL）被拒，不按文本读', () async {
      await File('${tmp.path}${Platform.pathSeparator}b.bin')
          .writeAsBytes([0x41, 0x00, 0x42]);
      final reason = asFailure(await ws.read('b.bin'));
      expect(reason, contains('二进制'));
    });
  });

  // ==========================================================================
  group('delete —— Directory.list() 是 Stream，不是 List', () {
    test('★★★ 非空目录 + recursive=false ⇒ 拒绝，且一个文件都不删', () async {
      await writeRaw('dir/keep.txt', 'precious');

      final reason = asFailure(await ws.delete('dir'));

      expect(reason, contains('目录非空'));
      expect(reason, contains('recursive=true'));
      // ★ 这是这条测试的重点：预扫描只读不删
      expect(
        await File('${tmp.path}${Platform.pathSeparator}dir'
                '${Platform.pathSeparator}keep.txt')
            .exists(),
        isTrue,
        reason: '拒绝时一个文件都不许删（P1-3 的取舍）',
      );
    });

    test('★★★ 空目录 + recursive=false ⇒ 能删（Stream.isEmpty 的正面用例）', () async {
      await Directory('${tmp.path}${Platform.pathSeparator}emptydir').create();

      asSuccess(await ws.delete('emptydir'));
      expect(
        await Directory('${tmp.path}${Platform.pathSeparator}emptydir').exists(),
        isFalse,
      );
    });

    test('★★ 文件直接删（不必 recursive）', () async {
      await writeRaw('f.txt', 'x');
      asSuccess(await ws.delete('f.txt'));
      expect(
        await File('${tmp.path}${Platform.pathSeparator}f.txt').exists(),
        isFalse,
      );
    });

    test('★★ 非空目录 + recursive=true ⇒ 真的递归删干净', () async {
      await writeRaw('tree/sub/deep.txt', 'x');
      asSuccess(await ws.delete('tree', recursive: true));
      expect(
        await Directory('${tmp.path}${Platform.pathSeparator}tree').exists(),
        isFalse,
      );
    });

    test('★★★ 拒绝删除工作区根目录本身', () async {
      final reason = asFailure(await ws.delete('', recursive: true));
      expect(reason, contains('拒绝删除工作区根目录'));
      expect(await tmp.exists(), isTrue);
    });

    test('★★ 路径不存在 ⇒ 失败并说明', () async {
      final reason = asFailure(await ws.delete('ghost'));
      expect(reason, contains('不存在'));
    });
  });

  // ==========================================================================
  group('路径穿越防护 —— 绝不碰 root 外的东西', () {
    test('★★★ `../` 逃出根目录 ⇒ 拒绝', () async {
      final reason = asFailure(await ws.read('../outside.txt'));
      expect(reason, contains('越出'));
    });

    test('★★★ 绝对路径 ⇒ 拒绝（否则模型能读 /etc/passwd）', () async {
      final reason = asFailure(await ws.read('/etc/passwd'));
      expect(reason, contains('绝对路径'));
    });

    test('★★ 根目录内的 `a/../b` 是合法的（不是见 .. 就拒）', () async {
      await writeRaw('b.txt', 'ok');
      final text = asSuccess(await ws.read('sub/../b.txt'));
      expect(text, contains('ok'));
    });
  });

  // ==========================================================================
  group('edit —— 匹配不上必须说清为什么', () {
    test('★★★ oldText 出现 0 次 ⇒ 失败 + 绝不写文件', () async {
      await writeRaw('e.txt', 'hello world\n');
      final reason = asFailure(await ws.edit('e.txt', 'goodbye', 'hi'));
      // 文案是"在 `e.txt` 里找不到 `old_string`（0 处命中）"
      expect(reason, contains('找不到'));
      expect(reason, contains('0 处'));
      expect(await readRaw('e.txt'), 'hello world\n');
    });

    test('★★★ oldText 出现多次 ⇒ 失败（不偷偷改第一个）', () async {
      await writeRaw('m.txt', 'x\nx\n');
      final reason = asFailure(await ws.edit('m.txt', 'x', 'y'));
      // 文案是"命中了 2 处，无法确定改哪一处"
      expect(reason, contains('2 处'));
      expect(reason, contains('无法确定'));
      expect(await readRaw('m.txt'), 'x\nx\n', reason: '歧义时一字不改');
    });

    test('★★ 唯一命中 ⇒ 正常替换', () async {
      await writeRaw('u.txt', 'before unique after\n');
      asSuccess(await ws.edit('u.txt', 'unique', 'CHANGED'));
      expect(await readRaw('u.txt'), 'before CHANGED after\n');
    });
  });

  // ==========================================================================
  group('write / mkdir / exists', () {
    test('★★ 写新文件 + 区分"已创建"与"已覆盖"', () async {
      final created = asSuccess(await ws.write('new.txt', 'a'));
      expect(created, contains('已创建'));

      final overwritten = asSuccess(await ws.write('new.txt', 'bb'));
      expect(overwritten, contains('已覆盖'));
      expect(await readRaw('new.txt'), 'bb');
    });

    test('★★ 父目录不存在 ⇒ 失败并让模型先 mkdir（不偷偷建）', () async {
      final reason = asFailure(await ws.write('no/such/dir/f.txt', 'x'));
      expect(reason, contains('父目录不存在'));
      expect(reason, contains('mkdir'));
    });

    test('★★ mkdir 幂等（已存在也报成功，但要能看出是本来就有）', () async {
      final first = asSuccess(await ws.mkdir('d1'));
      expect(first, contains('已创建'));
      final second = asSuccess(await ws.mkdir('d1'));
      expect(second, contains('已存在'));
    });

    test('★ exists 对文件与目录都成立', () async {
      await writeRaw('there.txt', 'x');
      await Directory('${tmp.path}${Platform.pathSeparator}theredir').create();
      expect(await ws.exists('there.txt'), isTrue);
      expect(await ws.exists('theredir'), isTrue);
      expect(await ws.exists('nope'), isFalse);
      // 越界路径一律 false（不抛）
      expect(await ws.exists('../escape'), isFalse);
    });
  });
}
