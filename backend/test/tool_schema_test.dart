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

    test('★ 有 shell 能力时说法要变（不许再说"在工作区里执行 shell"）', () {
      // 用一个假的 shell 能力
      final withShell = defaultSystemPrompt(Capabilities(
        shell: _FakeShell(),
      ));
      expect(withShell.contains('不能**执行 shell'), isFalse,
          reason: '有 shell 能力时不该出现"不能"');
      expect(withShell.contains('手机 shell'), isTrue,
          reason: '只有手机 shell 的宿主也要如实说命令跑在哪');
      expect(withShell.contains('在工作区里执行'), isFalse,
          reason: '★ 说反话：shell 不在用户工作区里跑');
    });
  });

  // ==========================================================================
  // ★ 执行面事实（2026-10-29 P1-③）
  //
  // 根因：system_prompt 与 run_shell_command 的 description 说
  //   「你可以在工作区里执行 shell 命令」「相对路径以工作区为基准」，
  // 但 guest 的 cwd 恒为沙箱 /workspace（ProotEngine.kt:931 /
  // SandboxBridge.kt:366），模型用 pwd/ls/find 探测用户工作区必然扑空
  // （真机实测白烧 3 轮）。
  //
  // 这些断言钉住「提示词是事实句」，而不是把执行逻辑改掉：
  //   · 两个执行面 = 两套文件系统（文件工具 ↔ 用户工作区；shell ↔ 沙箱）
  //   · 禁止用 shell 探测用户工作区，改用文件工具
  //   · 两种 shell 的事实各一行（沙箱 Alpine/ash；手机 Android mksh）
  // ==========================================================================
  group('★ 执行面事实 — 提示词不许说反话', () {
    final capsBoth = Capabilities(shell: _FakeShell(), sandbox: _FakeSandbox());
    final promptBoth = defaultSystemPrompt(capsBoth);

    test('★★★ system prompt：必须说清"两套文件系统"（沙箱 /workspace ≠ 用户工作区）', () {
      expect(promptBoth.contains('两套文件系统'), isTrue,
          reason: '不说清的话模型会拿 shell 的 pwd/ls 探测用户工作区（实测白烧 3 轮）');
      expect(promptBoth.contains('沙箱'), isTrue);
      expect(promptBoth.contains('/workspace'), isTrue);
      expect(promptBoth.contains('不是用户工作区'), isTrue);
    });

    test('★★★ system prompt：两种 shell 的事实各一行（Alpine / mksh）', () {
      expect(promptBoth.contains('Alpine'), isTrue,
          reason: '沙箱内是 Alpine Linux（ash），不是 Ubuntu');
      expect(promptBoth.contains('ash'), isTrue);
      expect(promptBoth.contains('mksh'), isTrue,
          reason: '手机上的 shell 是 Android mksh（toybox 风格）');
      expect(promptBoth.contains('由系统'), isTrue,
          reason: '命令实际在哪跑由系统决定 —— 模型不要假设');
    });

    test('★★★ system prompt：禁止用 shell 探测用户工作区，并给出替代工具', () {
      expect(promptBoth.contains('pwd'), isTrue);
      expect(promptBoth.contains('不要用 shell'), isTrue);
      expect(promptBoth.contains('grep_files'), isTrue);
      expect(promptBoth.contains('read_file'), isTrue);
      expect(promptBoth.contains('find_files'), isTrue);
    });

    test('★★★ system prompt：不许出现"说反话"的旧句', () {
      for (final wrong in [
        '你可以在工作区里执行 shell 命令',
        '在工作区里执行',
        '所有路径都相对于它',
        '工作区为基准',
      ]) {
        expect(promptBoth.contains(wrong), isFalse,
            reason: '★ 不许再说：「$wrong」');
      }
    });

    test('★★★ run_shell_command：description 必须说清沙箱 / @workspace ≠ 用户工作区', () {
      final t = buildShellTools(ToolFactory(capsBoth), capsBoth)
          .firstWhere((t) => t.name == 'run_shell_command');
      final d = t.description;
      expect(d.contains('沙箱'), isTrue);
      expect(d.contains('/workspace'), isTrue);
      expect(d.contains('两套文件系统'), isTrue);
      expect(d.contains('Alpine'), isTrue);
      expect(d.contains('mksh'), isTrue);
      expect(d.contains('@workspace'), isTrue);
      expect(d.contains('不是用户工作区'), isTrue);
      expect(d.contains('工作区为基准'), isFalse, reason: '旧文案说反话，必须删');
      // 不许写物理路径（宿主的 /data/... 之类模型也用不上）
      expect(RegExp(r'[A-Za-z]:\\|/data/|/storage/').hasMatch(d), isFalse,
          reason: '提示词里不许出现宿主物理路径');

      final props =
          (t.parameters['properties'] as Map).cast<String, dynamic>();
      final cmdDesc = (props['command'] as Map)['description'] as String;
      expect(cmdDesc.contains('工作区为基准'), isFalse,
          reason: '★ 参数说明里的旧句也要删');
      expect(cmdDesc.contains('/workspace'), isTrue,
          reason: '要说明沙箱内的相对路径以 /workspace（沙箱目录）为基准');
      expect(cmdDesc.contains('@workspace'), isTrue,
          reason: '保留 @name 命名挂载的说明');
      expect(cmdDesc.contains('不是用户工作区'), isTrue);
      expect(RegExp(r'[A-Za-z]:\\|/data/|/storage/').hasMatch(cmdDesc), isFalse);
    });

    test('★ 没有 shell 也没有沙箱时，仍然不许说"在工作区里执行 shell"', () {
      final p = defaultSystemPrompt(const Capabilities());
      expect(p.contains('不能**执行 shell'), isTrue);
      expect(p.contains('两套文件系统'), isFalse,
          reason: '连 shell 执行面都没有时，不必谈两套文件系统（会误导）');
      expect(p.contains('在工作区里执行'), isFalse);
    });

    // ★ B4（2026-10-30）：沙箱优先 + 未就绪不可静默回落 —— 提示词必须是事实句
    test('★★★ system prompt：沙箱优先 + 未就绪明确报错、不偷换执行面（B4）', () {
      expect(promptBoth.contains('沙箱优先'), isTrue,
          reason: '★ 产品语义：沙箱就绪时默认且优先走沙箱（构建类也在沙箱）');
      expect(promptBoth.contains('构建类任务同样在沙箱'), isTrue,
          reason: 'T2：构建类任务优先沙箱，设备工具链只作显式回退');
      expect(promptBoth.contains('明确报错'), isTrue,
          reason: '★ 未就绪要如实报错，不是静默降级');
      expect(promptBoth.contains('不会偷偷改在手机 shell 上跑'), isTrue,
          reason: '★★ 这句话是"不可静默回落"对模型的事实交代');
    });

    test('★★★ run_shell_command：description 写明未就绪会报错、不偷换到手机（B4）', () {
      final t = buildShellTools(ToolFactory(capsBoth), capsBoth)
          .firstWhere((t) => t.name == 'run_shell_command');
      expect(t.description.contains('沙箱未激活'), isTrue);
      expect(t.description.contains('明确报错'), isTrue);
      expect(t.description.contains('不会偷偷改在手机 shell 上跑'), isTrue);
      // 旧事实句不许被这次改动挤掉（不弱化既有断言的对象）
      expect(t.description.contains('两套文件系统'), isTrue);
      expect(t.description.contains('@workspace'), isTrue);
    });

    test('★★ 只有手机 shell 的宿主：不许承诺"沙箱优先/激活沙箱"', () {
      final p = defaultSystemPrompt(Capabilities(shell: _FakeShell()));
      expect(p.contains('沙箱优先'), isFalse,
          reason: '宿主没接沙箱时承诺"沙箱优先"就是假话');
      expect(p.contains('沙箱未激活'), isFalse);
      expect(p.contains('只有**手机 shell**执行面'), isTrue);
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

class _FakeSandbox implements SandboxCapability {
  @override
  Future<bool> isReady() async => true;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async =>
      const CapabilitySuccess('ok');

  @override
  Future<CapabilityResult> reset({String snapshot = ''}) async =>
      const CapabilitySuccess('ok');
}
