/// **工具行折叠摘要**的测试（2026-10-23）。
///
/// ## 为什么要有
///
/// 用户原话：
/// > 「调用工具太多了，我往下翻全是调用工具，导致观感不好，所以要你做一个折叠。
/// >   就是默认是图片这样合并」
///
/// 参考形态（他给的图）：`>_ 执行了命令并已读取图片`。
///
/// 折叠行是**一句话概括一组调用**，所以措辞必须钉死 —— 否则一旦有人
/// 改动动词表，用户看到的就是"执行了正在读取并读取了"这种半句话。
///
/// 同时钉住**单行标题的措辞不变**：抽动词表时最容易的失误就是把单行的
/// `读取了 a.txt` 改成 `读取了文件 a.txt`（重复啰嗦）—— 那是用户已经
/// 验收过的样子，不许回退。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/widgets/tool_call_card.dart';

void main() {
  group('折叠摘要 toolGroupSummary', () {
    test('★ 单类 ⇒ 独立短语（不接目标）', () {
      expect(toolGroupSummary(['run_shell_command']), '执行了命令');
      expect(toolGroupSummary(['read_file']), '读取了文件');
      expect(toolGroupSummary(['list_files']), '查看了目录');
    });

    test('★★ 两类 ⇒ 用「并」连起来（对应用户图里的形态）', () {
      expect(
        toolGroupSummary(['run_shell_command', 'view_image']),
        '执行了命令并读取了图片',
        reason: '用户给的参考形态：>_ 执行了命令并已读取图片',
      );
      expect(
        toolGroupSummary(['read_file', 'edit']),
        '读取了文件并编辑了文件',
      );
    });

    test('★ 三类以上 ⇒ 前两类 + 调用次数收尾', () {
      final s = toolGroupSummary([
        'run_shell_command',
        'list_files',
        'read_file',
        'edit',
        'grep_files',
      ]);
      expect(s, '执行了命令、查看了目录 等 5 项',
          reason: '收尾的数字是**调用次数**（5），不是类别数（4）');
    });

    test('★ 同类多次 ⇒ 去重（不出现"读取了文件并读取了文件"）', () {
      expect(toolGroupSummary(['read_file', 'read_file']), '读取了文件');
      expect(
        toolGroupSummary(['read_file', 'read_file', 'edit']),
        '读取了文件并编辑了文件',
      );
    });

    test('★ 顺序 = 首次出现顺序（不排序）', () {
      expect(
        toolGroupSummary(['edit', 'run_shell_command']),
        '编辑了文件并执行了命令',
      );
    });

    test('★ 未知工具也有兜底（不许露出 schema 名当动词）', () {
      expect(toolGroupSummary(['some_new_tool']), '调用了 some_new_tool');
    });

    test('★ 空组不崩', () {
      expect(toolGroupSummary(const []), '没有工具调用');
    });
  });

  group('单行标题 toolCallLabel（已验收措辞，不许被改坏）', () {
    test('★★ 是「动词 + 目标」，不是「动词+宾语 + 目标」', () {
      expect(
        toolCallLabel('read_file', {'path': 'a.txt'},
            running: false, failed: false),
        '读取了 a.txt',
        reason: '★ 抽动词表时最易犯的错：变成「读取了文件 a.txt」',
      );
      expect(
        toolCallLabel('list_files', {'path': 'lib'},
            running: false, failed: false),
        '查看了目录 lib',
      );
      expect(
        toolCallLabel('run_shell_command', {'command': 'ls -la'},
            running: false, failed: false),
        '执行了命令 ls -la',
      );
    });

    test('★ 运行中用进行时', () {
      expect(
        toolCallLabel('read_file', {'path': 'a.txt'},
            running: true, failed: false),
        '正在读取 a.txt',
      );
    });

    test('★ 失败时末尾补「（失败）」（不另起一列"成功"字样）', () {
      expect(
        toolCallLabel('edit', {'path': 'a.dart'},
            running: false, failed: true),
        '编辑了 a.dart（失败）',
      );
    });

    test('★ 没有目标时只给动词（不留尾巴空格）', () {
      expect(
        toolCallLabel('write_todos', const {},
            running: false, failed: false),
        '更新了待办',
      );
    });
  });
}