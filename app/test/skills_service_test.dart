/// **F1 Skills 服务层**（`docs/INTERFACE.md` §N16.1）。
///
/// ## 这份测试钉的是什么
///
/// 宿主（Kotlin）只搬字节，**解析/校验/合并全在 Dart**。因此这里用真实的
/// `heracles/command` 通道 mock 掉宿主，跑**生产代码路径**，逐条钉住：
///
/// 1. 内置清单来自 backend `builtinSkillEntries()`（不是 App 里另抄一份）；
/// 2. 启停状态**只信宿主**（同一个 name 在两次 list 之间必须保持）；
/// 3. 非法 SKILL.md 逐条进 `errors`，好技能照常列出（不整体失败）；
/// 4. 安装回来的坏技能必须**回滚**（真的调 `skillsRemove`），不许留在磁盘；
/// 5. 旧宿主没有这些方法（`MissingPluginException`）⇒ 如实降级，不崩、不假装成功；
/// 6. 用户技能正文（body）**不出现**在对外数据结构里。
///
/// ## 为什么不用「注入假实现」
///
/// 假实现会让测试和线上走两条路：通道参数名写错、`{ok}` 判反，测试都能绿。
/// mock 在**通道边界**上，服务里每一行生产代码都被覆盖。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles_backend/heracles_backend.dart';

import 'package:heracles/services/skills_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ContractSkills.channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 记录宿主收到的每次调用（方法名 + 参数）。
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
  });

  tearDown(() {
    // 必须清掉：否则下一条测试会吃到上一条的宿主行为（跨用例串台）。
    messenger.setMockMethodCallHandler(channel, null);
  });

  /// 注册一个"宿主"：默认把收到的调用记进 [calls]，再交给 [onCall]。
  void host(Future<Object?> Function(MethodCall call) onCall) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return onCall(call);
    });
  }

  Map<String, Object?> argsOf(MethodCall call) =>
      (call.arguments as Map).cast<String, Object?>();

  /// 一份合法 SKILL.md（正文用 marker 便于验证"不外泄"）。
  String validSkillMd(String name, {String body = '正文内容'}) =>
      '''
---
name: $name
description: $name 的说明
---
$body
''';

  // ==========================================================================
  // ① 清单：内置 + 用户合并，字段齐全
  // ==========================================================================

  test('★ 清单字段齐全：内置来自 backend，用户技能带 path，enabled 来自宿主', () async {
    host((call) async {
      expect(call.method, ContractSkills.listMethod);
      expect(argsOf(call)['workspace'], '/ws');
      return <String, Object?>{
        'ok': true,
        'entries': <Object?>[
          <String, Object?>{
            'path': '/ws/.heracles/skills/code-review/SKILL.md',
            'raw': validSkillMd('code-review'),
          },
          <String, Object?>{
            'path': '/ws/.heracles/skills/doc-writer/SKILL.md',
            'raw': validSkillMd('doc-writer'),
          },
        ],
        // 缺省项必须视为启用（启停表只记"用户改过的"）。
        'enabled': <String, Object?>{'verify-loop': false},
      };
    });

    final snapshot = await SkillsService(workspace: '/ws').listSkills();

    expect(snapshot.ok, isTrue);
    expect(snapshot.errors, isEmpty);

    // 内置三条 —— 名字/描述必须与 backend 同源，不能在 App 里另写一份。
    final expectedBuiltin = builtinSkillEntries();
    expect(snapshot.builtin, hasLength(3));
    expect(
      snapshot.builtin.map((v) => v.name).toList(),
      expectedBuiltin.map((e) => e.name).toList(),
    );
    expect(
      snapshot.builtin.map((v) => v.description).toList(),
      expectedBuiltin.map((e) => e.description).toList(),
    );

    for (final v in snapshot.builtin) {
      expect(v.source, ContractSkills.sourceBuiltin);
      expect(v.path, isEmpty, reason: '内置技能没有磁盘路径');
    }
    expect(
      snapshot.builtin.firstWhere((v) => v.name == 'verify-loop').enabled,
      isFalse,
      reason: '宿主的启停表必须覆盖出厂默认值',
    );
    expect(
      snapshot.builtin.firstWhere((v) => v.name == 'root-cause-first').enabled,
      isTrue,
      reason: '表里没有的名字缺省启用',
    );

    // 用户技能
    expect(snapshot.user, hasLength(2));
    final review = snapshot.user.firstWhere((v) => v.name == 'code-review');
    expect(review.description, 'code-review 的说明');
    expect(review.source, ContractSkills.sourceUser);
    expect(review.enabled, isTrue);
    expect(review.path, '/ws/.heracles/skills/code-review/SKILL.md');
    expect(snapshot.all, hasLength(5));
  });

  // ==========================================================================
  // ② 启停：写宿主 → 重新 list 仍是停用态（不是本地缓存骗人）
  // ==========================================================================

  test('★★ 启停持久化：setSkillEnabled 后重新 listSkills 仍是停用态', () async {
    // 宿主侧唯一的真相：name → bool。
    final enabledTable = <String, bool>{};

    host((call) async {
      switch (call.method) {
        case ContractSkills.listMethod:
          return <String, Object?>{
            'ok': true,
            'entries': <Object?>[
              <String, Object?>{
                'path': '/ws/.heracles/skills/code-review/SKILL.md',
                'raw': validSkillMd('code-review'),
              },
            ],
            'enabled': <String, Object?>{...enabledTable},
          };
        case ContractSkills.setEnabledMethod:
          final a = argsOf(call);
          enabledTable[a['name']! as String] = a['enabled']! as bool;
          return <String, Object?>{'ok': true};
      }
      return <String, Object?>{'ok': false, 'error': '未预期的方法 ${call.method}'};
    });

    final service = SkillsService(workspace: '/ws');
    final first = await service.listSkills();
    expect(
      first.builtin.firstWhere((v) => v.name == 'verify-loop').enabled,
      isTrue,
    );

    final op = await service.setSkillEnabled('verify-loop', false);
    expect(op.ok, isTrue);
    final setCall = calls.last;
    expect(setCall.method, ContractSkills.setEnabledMethod);
    expect(argsOf(setCall), <String, Object?>{
      'name': 'verify-loop',
      'enabled': false,
    });

    // 用**新实例**重新拉：证明状态真的落在宿主，而不是服务里的一个假字段。
    final second = await SkillsService(workspace: '/ws').listSkills();
    expect(
      second.builtin.firstWhere((v) => v.name == 'verify-loop').enabled,
      isFalse,
      reason: '停用状态必须活过重新加载',
    );

    // 本地快照也要同步（页面不必为了一个开关重拉整张表）。
    final local = await service.listSkills();
    expect(
      local.builtin.firstWhere((v) => v.name == 'verify-loop').enabled,
      isFalse,
    );
  });

  // ==========================================================================
  // ③ 非法 SKILL.md：逐条报错，好的照常列出
  // ==========================================================================

  test('★★ 非法 SKILL.md 逐条报错：坏文件进 errors，好文件仍列出', () async {
    host(
      (call) async => <String, Object?>{
        'ok': true,
        'entries': <Object?>[
          <String, Object?>{
            'path': '/ws/.heracles/skills/good/SKILL.md',
            'raw': validSkillMd('good-skill'),
          },
          <String, Object?>{
            // 没有 front-matter —— 真实用户会手写坏文件。
            'path': '/ws/.heracles/skills/broken/SKILL.md',
            'raw': '这是一个没有 front-matter 的文件\n正文\n',
          },
        ],
        'enabled': <String, Object?>{},
      },
    );

    final snapshot = await SkillsService(workspace: '/ws').listSkills();

    expect(snapshot.ok, isTrue, reason: '单个坏文件不代表整张清单失败');
    expect(snapshot.user.map((v) => v.name), <String>['good-skill']);
    expect(snapshot.errors, hasLength(1));
    expect(
      snapshot.errors.single,
      allOf(
        contains('/ws/.heracles/skills/broken/SKILL.md'),
        contains('front-matter'),
      ),
      reason: '错误必须能定位到具体文件，并且给出人话原因',
    );
  });

  // ==========================================================================
  // ④ 安装：坏技能回滚（真调 skillsRemove）
  // ==========================================================================

  test('★★★ 安装回来的坏技能被回滚：调 skillsRemove 删掉，errors 说明原因', () async {
    host((call) async {
      switch (call.method) {
        case ContractSkills.installMethod:
          expect(argsOf(call), <String, Object?>{
            'workspace': '/ws',
            'source': 'https://example.com/bad-skill.zip',
          });
          return <String, Object?>{
            'ok': true,
            'installed': <Object?>[
              <String, Object?>{
                'path': '/ws/.heracles/skills/good/SKILL.md',
                'raw': validSkillMd('good-skill'),
              },
              <String, Object?>{
                'path': '/ws/.heracles/skills/broken/SKILL.md',
                // front-matter 未闭合
                'raw': '---\nname: broken\n正文没有结束线\n',
              },
            ],
            'errors': <Object?>[],
          };
        case ContractSkills.removeMethod:
          return <String, Object?>{'ok': true, 'removed': true};
      }
      return <String, Object?>{'ok': false, 'error': '未预期的方法 ${call.method}'};
    });

    final result = await SkillsService(
      workspace: '/ws',
    ).installSkill('https://example.com/bad-skill.zip');

    // 回滚必须真的打到宿主，而且用 **path** 定位（name 可能还没解析出来）。
    final removes = calls
        .where((c) => c.method == ContractSkills.removeMethod)
        .toList();
    expect(removes, hasLength(1), reason: '坏的技能必须被删掉，不能留在磁盘上');
    final ra = argsOf(removes.single);
    expect(ra['workspace'], '/ws');
    expect(ra['path'], '/ws/.heracles/skills/broken/SKILL.md');

    expect(result.installed.map((v) => v.name), <String>['good-skill']);
    expect(result.ok, isFalse, reason: '有条目被回滚 ⇒ 这次安装不算全部成功');
    expect(result.errors, hasLength(1));
    expect(
      result.errors.single,
      allOf(
        contains('/ws/.heracles/skills/broken/SKILL.md'),
        contains('front-matter'),
      ),
    );
  });

  test('安装全部合法 ⇒ ok，且不调 skillsRemove', () async {
    host((call) async {
      if (call.method == ContractSkills.installMethod) {
        return <String, Object?>{
          'ok': true,
          'installed': <Object?>[
            <String, Object?>{
              'path': '/ws/.heracles/skills/good/SKILL.md',
              'raw': validSkillMd('good-skill'),
            },
          ],
          'errors': <Object?>[],
        };
      }
      return <String, Object?>{'ok': false};
    });

    final r = await SkillsService(
      workspace: '/ws',
    ).installSkill('/tmp/good-skill');
    expect(r.ok, isTrue);
    expect(r.installed.single.path, '/ws/.heracles/skills/good/SKILL.md');
    expect(
      calls.where((c) => c.method == ContractSkills.removeMethod),
      isEmpty,
    );
  });

  test('宿主安装失败（有 code）⇒ 原样透传，不假装成功', () async {
    host(
      (call) async => <String, Object?>{
        'ok': false,
        'error': '来源是明文 http://，已拒绝',
        'code': ContractSkills.errSourceInvalid,
      },
    );

    final r = await SkillsService(
      workspace: '/ws',
    ).installSkill('http://example.com/x.zip');
    expect(r.ok, isFalse);
    expect(r.code, ContractSkills.errSourceInvalid);
    expect(r.error, contains('http://'));
    expect(r.installed, isEmpty);
  });

  // ==========================================================================
  // ⑤ 旧宿主：通道缺失 ⇒ 如实降级
  // ==========================================================================

  test('★★ 通道缺失（MissingPluginException）：不崩，内置仍可见，明确说明', () async {
    // 完全不注册 handler：这正是旧宿主上 `invokeMethod` 的真实表现。
    final snapshot = await SkillsService(workspace: '/ws').listSkills();

    expect(snapshot.ok, isFalse, reason: '没读到用户技能不能算成功');
    expect(snapshot.user, isEmpty);
    expect(snapshot.builtin, hasLength(3), reason: '内置清单不依赖宿主，仍要能显示');
    expect(snapshot.code, SkillsService.errChannelMissing);
    expect(snapshot.error, isNotNull);
    expect(
      snapshot.errors,
      isNotEmpty,
      reason: '必须有一条说明性 errors 告诉用户为什么看不到自己的技能',
    );
    expect(snapshot.errors.first, contains('技能通道'));

    final install = await SkillsService(
      workspace: '/ws',
    ).installSkill('/tmp/x');
    expect(install.ok, isFalse);
    expect(install.code, SkillsService.errChannelMissing);
  });

  // ==========================================================================
  // ⑥ 正文不外泄
  // ==========================================================================

  test('★★ SkillView 不含 body：正文 marker 不出现在 toJson/toString', () async {
    const marker = 'BODY_MARKER_DO_NOT_LEAK_9f3a';
    host(
      (call) async => <String, Object?>{
        'ok': true,
        'entries': <Object?>[
          <String, Object?>{
            'path': '/ws/.heracles/skills/secretive/SKILL.md',
            'raw': validSkillMd('secretive', body: marker),
          },
        ],
        'enabled': <String, Object?>{},
      },
    );

    final snapshot = await SkillsService(workspace: '/ws').listSkills();
    final view = snapshot.user.single;

    expect(view.toJson().containsKey('body'), isFalse);
    expect(view.toJson().values.join('|'), isNot(contains(marker)));
    expect(view.toString(), isNot(contains(marker)));
    expect(snapshot.toString(), isNot(contains(marker)));
  });

  // ==========================================================================
  // ⑦ 没有工作区：明确失败
  // ==========================================================================

  test('★★ 没有工作区 ⇒ E_SKILLS_NO_WORKSPACE，且不假装空清单成功', () async {
    host((call) async => <String, Object?>{'ok': true, 'entries': <Object?>[]});

    final snapshot = await SkillsService().listSkills();
    expect(snapshot.ok, isFalse);
    expect(snapshot.code, ContractSkills.errNoWorkspace);
    expect(snapshot.errors, isNotEmpty);
    expect(calls, isEmpty, reason: '没有工作区就不该去打宿主');

    final install = await SkillsService().installSkill('/tmp/x');
    expect(install.ok, isFalse);
    expect(install.code, ContractSkills.errNoWorkspace);

    final remove = await SkillsService().removeSkill('code-review');
    expect(remove.ok, isFalse);
    expect(remove.code, ContractSkills.errNoWorkspace);
  });

  // ==========================================================================
  // ⑧ 卸载
  // ==========================================================================

  test('★★ removeSkill 用已解析清单里的 path 定位（name 可能重名）', () async {
    host((call) async {
      switch (call.method) {
        case ContractSkills.listMethod:
          return <String, Object?>{
            'ok': true,
            'entries': <Object?>[
              <String, Object?>{
                'path': '/ws/.heracles/skills/deep/code-review/SKILL.md',
                'raw': validSkillMd('code-review'),
              },
            ],
            'enabled': <String, Object?>{},
          };
        case ContractSkills.removeMethod:
          return <String, Object?>{'ok': true, 'removed': true};
      }
      return <String, Object?>{'ok': false};
    });

    final service = SkillsService(workspace: '/ws');
    await service.listSkills();
    final r = await service.removeSkill('code-review');

    expect(r.ok, isTrue);
    expect(r.removed, isTrue);
    final ra = argsOf(calls.last);
    expect(calls.last.method, ContractSkills.removeMethod);
    expect(ra['name'], 'code-review');
    expect(ra['path'], '/ws/.heracles/skills/deep/code-review/SKILL.md');
  });

  test('★ 内置技能不能卸载：直接失败，不打宿主', () async {
    host((call) async => <String, Object?>{'ok': true, 'removed': true});

    final r = await SkillsService(workspace: '/ws').removeSkill('verify-loop');

    expect(r.ok, isFalse);
    expect(r.removed, isFalse);
    expect(r.error, contains('内置'));
    expect(calls, isEmpty, reason: '内置技能不在工作区里，删不着；必须说清楚而不是让宿主报"未找到"');
  });

  test('宿主说没删到（removed=false）⇒ 如实失败，不谎报成功', () async {
    host((call) async => <String, Object?>{'ok': true, 'removed': false});

    final r = await SkillsService(workspace: '/ws').removeSkill('ghost');
    expect(r.ok, isFalse);
    expect(r.removed, isFalse);
    expect(r.code, ContractSkills.errNotFound);
  });

  // ==========================================================================
  // ⑨ 宿主失败时的清单降级
  // ==========================================================================

  test('★★ skillsList 返回 ok:false ⇒ 内置仍列出，错误如实上报', () async {
    host(
      (call) async => <String, Object?>{
        'ok': false,
        'error': '工作区不可读',
        'code': ContractSkills.errNoWorkspace,
      },
    );

    final snapshot = await SkillsService(workspace: '/ws').listSkills();
    expect(snapshot.ok, isFalse);
    expect(snapshot.error, '工作区不可读');
    expect(snapshot.code, ContractSkills.errNoWorkspace);
    expect(snapshot.builtin, hasLength(3));
    expect(snapshot.user, isEmpty);
    expect(snapshot.errors, contains('工作区不可读'));
  });
}
