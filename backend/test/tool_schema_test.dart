import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **工具定义门禁** —— JSON Schema 必须是真实类型。
///
/// ## 为什么这个测
///
/// 旧实现 55 个参数**全是 `string`**（GBNF 时代只能出扁平标量），
/// 导致模型把 `limit` 写成 `"80"`，然后被服务端拒或本地解析失败。
///
/// 云端原生 function calling **完整支持 integer/boolean/array**，
/// 用 string 是把能力锁死。这个测试就是防回退。
void main() {
  /// 不需要任何能力就能构建工具（用 null Capsabilities 也能拿到 schema）。
  final factory = ToolFactory(const Capabilities());
  final tools = {
    for (final t in [
      ...buildFileToolsForTest(factory),
    ])
      t.name: t,
  };

  group('JSON Schema — 真实类型（不是全 string）', () {
    test('★★★ read_file 的 offset / limit 必须是 integer', () {
      final t = tools['read_file']!;
      final props = (t.parameters['properties'] as Map).cast<String, dynamic>();
      expect((props['offset'] as Map)['type'], 'integer',
          reason: 'offset 是行号，必须是 integer 而不是 string');
      expect((props['limit'] as Map)['type'], 'integer');
      expect((props['path'] as Map)['type'], 'string');
    });

    test('★★★ list_files 的 recursive 必须是 boolean', () {
      final t = tools['list_files']!;
      final props = (t.parameters['properties'] as Map).cast<String, dynamic>();
      expect((props['recursive'] as Map)['type'], 'boolean',
          reason: 'recursive 是开关，必须是 boolean');
      expect((props['max_entries'] as Map)['type'], 'integer');
    });

    test('★★★ find_files 的 max_results 必须是 integer', () {
      final t = tools['find_files']!;
      final props = (t.parameters['properties'] as Map).cast<String, dynamic>();
      expect((props['max_results'] as Map)['type'], 'integer');
    });

    test('★★ required 必须准确（缺了模型会漏填）', () {
      expect((tools['read_file']!.parameters['required'] as List), ['path']);
      expect((tools['write_file']!.parameters['required'] as List),
          ['path', 'content']);
      expect((tools['edit']!.parameters['required'] as List),
          ['path', 'old_string', 'new_string']);
      expect((tools['grep_files']!.parameters['required'] as List), ['pattern']);
    });

    test('★★ 不该 required 的不要写进 required', () {
      final req = tools['list_files']!.parameters['required'] as List;
      expect(req, isEmpty, reason: '列目录的所有参数都是可选的');
    });

    test('★ 每个参数都必须有 description（模型靠它理解）', () {
      for (final entry in tools.entries) {
        final props =
            (entry.value.parameters['properties'] as Map).cast<String, dynamic>();
        for (final p in props.entries) {
          final desc = (p.value as Map)['description'];
          expect(desc, isNotNull,
              reason: '${entry.key}.${p.key} 缺少 description');
          expect((desc as String).trim(), isNotEmpty,
              reason: '${entry.key}.${p.key} 的 description 是空的');
        }
      }
    });
  });

  group('工具描述 — 必须说清"什么时候用"', () {
    test('★ edit 的描述要提到唯一性约束（否则模型会改错位置）', () {
      final d = tools['edit']!.description;
      expect(d.contains('唯一') || d.contains('唯一出现'), isTrue,
          reason: '必须告诉模型 old_string 要唯一，否则它会到处误替换');
    });

    test('★ write_file 要说清是覆盖不是追加', () {
      final d = tools['write_file']!.description;
      expect(d.contains('覆盖'), isTrue,
          reason: '不说明的话模型会以为能追加，导致内容丢失');
    });

    test('★ grep_files 要说明它是"搜索优先"的工具', () {
      final d = tools['grep_files']!.description;
      expect(d.length > 30, isTrue, reason: '描述太短，模型不会优先选它');
    });
  });

  group('命令安全闸', () {
    test('★★★ kill 必须被拦（2026-10-09 真实事故）', () {
      expect(checkCommandSafety('kill 1234'), isNotNull);
      expect(checkCommandSafety('killall app'), isNotNull);
    });

    test('★★★ force-stop 必须被拦', () {
      expect(checkCommandSafety('am force-stop com.foo.bar'), isNotNull);
      expect(checkCommandSafety('pm disable com.foo'), isNotNull);
    });

    test('★★ 正常命令不误伤', () {
      expect(checkCommandSafety('ls -la'), isNull);
      expect(checkCommandSafety('npm run build'), isNull);
      expect(checkCommandSafety('git status'), isNull);
      expect(checkCommandSafety('echo hello > file.txt'), isNull);
    });

    test('★★ 大小写不敏感', () {
      expect(checkCommandSafety('KILL 1'), isNotNull);
      expect(checkCommandSafety('AM FORCE-STOP x'), isNotNull);
    });
  });

  group('系统提示词 — 给事实不给教练', () {
    test('★★★ 不含"必须分步"/"一次只做一步"这类教练约束', () {
      final p = defaultSystemPrompt(const Capabilities());
      expect(p.contains('必须分步'), isFalse);
      expect(p.contains('一次只做一步'), isFalse);
      expect(p.contains('3000 字符'), isFalse);
    });

    test('★★★ 必须包含停止条件（实测能减少轮数）', () {
      final p = defaultSystemPrompt(const Capabilities());
      expect(p.contains('什么时候该停'), isTrue,
          reason: '没有停止条件时模型会跑 22 轮（2026-10-21 真机实测）');
    });

    test('★★ 必须声明不许编造工具名、不许猜文件内容', () {
      final p = defaultSystemPrompt(const Capabilities());
      expect(p.contains('不要编造工具名'), isTrue);
      expect(p.contains('不要猜测文件内容'), isTrue);
    });

    test('★★ 能力缺失时提示词要如实说"不能"', () {
      final noShell = defaultSystemPrompt(const Capabilities());
      expect(noShell.contains('不能**执行 shell'), isTrue,
          reason: '没有 shell 能力时必须明说，否则模型会调用它然后失败');
    });

    test('★ 有 shell 能力时说法要变', () {
      // 用一个假的 shell 能力
      final withShell = defaultSystemPrompt(Capabilities(
        shell: _FakeShell(),
      ));
      expect(withShell.contains('你可以在工作区里执行 shell 命令'), isTrue);
      expect(withShell.contains('不能**执行 shell'), isFalse,
          reason: '有 shell 能力时不该出现"不能"');
    });
  });
}

/// 测试用：只构建文件工具（不需要真能力）。
List<dynamic> buildFileToolsForTest(ToolFactory f) {
  // buildFileTools 需要 Capabilities；这里传 null 能力也能拿到 schema，
  // 因为 schema 是静态声明，与能力无关。
  return buildFileTools(f, const Capabilities());
}

class _FakeShell implements ShellCapability {
  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async =>
      const CapabilitySuccess('ok');
}
