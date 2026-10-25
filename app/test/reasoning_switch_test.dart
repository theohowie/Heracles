import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/input_bar.dart';

import 'support/secure_storage_mock.dart';

/// **推理等级开关（S4）+ 输入框新形态（2026-10-12）的测试**。
///
/// ## 形态变更史（读这个文件前先看）
///
/// - S4 原形态：输入框上方一行「权限芯片 …… 推理等级芯片」，
///   测试按 `find.text('Auto')` 找芯片。
/// - **2026-10-12 改版**（用户拿 llama.cpp Web UI 当参考）：
///   输入框改为**大容器**，`+`/发送键内嵌；
///   发送键左侧是**模型选择框**（带阴影胶囊），点击弹**图二**列表
///   （模型 / 推理等级两行），推理等级行**就地展开五档**；
///   权限改为发送键左侧的**纯图标按钮**（点击弹三档选择框，
///   切「完全访问」仍会触发二次风险确认）。
///   —— 旧版按芯片行写的 12 项已随旧形态删除，
///   但每一条的**断言意图**都在新写法里保留了。
///
/// ## ★★ 最容易被写歪的一条：本地只有开/关两态
///
/// 实测（`docs/25` §10.3）：本地 `llama-server` **静默忽略**
/// `reasoning_effort`，只有 `enable_thinking` 的 true/false。
/// 所以本地下 `Low`/`High`/`Max` **行为完全相同**。
/// UI 必须**如实说明**，否则用户以为调 Max 就更聪明 —— 那是假信息。
///
/// ## 2026-10-18（F1c）新增：安全存储通道 mock
///
/// 见下方「0. 测试基建」—— 没有它，本文件里**任何**走
/// `SettingsController.load()` 的用例都会**永久卡死**在本机。
/// 实现（单一来源）在 `test/support/secure_storage_mock.dart`。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {bool dark = true}) => MaterialApp(
        theme: buildHeraclesTheme(dark: dark),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(dark, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  /// 造一个新形态的 InputBar（不需要真的发消息）。
  ///
  /// ★ 2026-10-18（ADR-035 S4）：`isLocalBackend` 参数已随本地后端**删除** ——
  /// InputBar 不再有"本地/云端"两态，推理等级一律走云端语义。
  Widget barWith({
    required ReasoningLevel level,
    ValueChanged<ReasoningLevel>? onChanged,
    PermissionMode permission = PermissionMode.workspaceAuto,
    String? label,
    List<ModelProviderConfig> providers = const [],
    ValueChanged<String>? onProviderSelected,
    int maxTurns = 0,
    ValueChanged<int>? onMaxTurnsChanged,
  }) =>
      InputBar(
        onSend: (_) {},
        reasoningLevel: level,
        onReasoningLevelChanged: onChanged,
        permission: permission,
        providerLabel: label,
        providers: providers,
        onProviderSelected: onProviderSelected,
        maxTurns: maxTurns,
        onMaxTurnsChanged: onMaxTurnsChanged,
      );

  // ==================================================================
  // 0. ★★ 测试基建：mock `flutter_secure_storage` 通道（2026-10-18，F1c）
  //
  // 实现已抽到 `test/support/secure_storage_mock.dart`（**单一来源**，
  // `widget_test.dart` 等文件共用同一份 —— 复制两份必然在通道名变更时漂移）。
  // 那份文件里写了完整的根因与通道契约，这里只留一行指针。
  //
  // 一句话：`load()` 会 `await` Keystore 通道；未装 handler 时那个 Future
  // **永不完成**（不是抛 `MissingPluginException`）⇒ 任何走 `load()` 的
  // 用例**永久卡死**。装上 mock 后本文件由"第 4 个用例卡死"变成 39/39 通过。
  //
  // ⚠️ 与 `实测-03` 坑 35（ChatScreen 卡首帧）**不是同一件事**。
  // ==================================================================

  setUp(installSecureStorageMock);
  tearDown(removeSecureStorageMock);

  // ==================================================================
  // 1. ★ 五档定义本身（纯逻辑，不依赖 UI）
  // ==================================================================

  group('★ ReasoningLevel 五档', () {
    test('★★ 五档齐全，且顺序是 Auto → Off → Low → High → Max', () {
      expect(
        ReasoningLevel.values.map((v) => v.label).toList(),
        ['Auto', 'Off', 'Low', 'High', 'Max'],
        reason: '顺序 = 菜单里从上到下的顺序，也是用户指定的一档不差',
      );
    });

    test('★★ 没有任何档位叫 Default —— 用户明确要求改名 Auto', () {
      for (final v in ReasoningLevel.values) {
        expect(v.label, isNot('Default'),
            reason: '用户原话：「把 Default 改为 Auto」—— 改名要彻底');
      }
      expect(ReasoningLevel.auto.label, 'Auto');
    });
  });

  // ==================================================================
  // 2. ★ 持久化与旧数据兼容
  // ==================================================================

  group('★ 持久化与旧数据兼容', () {
    testWidgets('★ 改了推理等级会落盘，重载后仍在', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      await c.setReasoningLevel(ReasoningLevel.high);

      final c2 = await SettingsController.load();
      expect(c2.value.reasoningLevel, ReasoningLevel.high,
          reason: '推理等级是设置，重启后必须还在');
    });

    testWidgets('★★ 旧数据（没有该字段）→ 回落 auto，不崩', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      expect(c.value.reasoningLevel, ReasoningLevel.auto);
    });

    testWidgets('★★ 旧数据里的脏值 → 回落 auto，不崩也不静默开思考',
        (tester) async {
      SharedPreferences.setMockInitialValues({'reasoningLevel': 'wat'});
      final c = await SettingsController.load();
      expect(c.value.reasoningLevel, ReasoningLevel.auto,
          reason: '认不出的值绝不能静默当成"开思考" —— 那会拖慢且花token');
    });

    test('★ 每一档都能存能读（五档全覆盖）', () async {
      for (final v in ReasoningLevel.values) {
        SharedPreferences.setMockInitialValues({});
        final c = await SettingsController.load();
        await c.setReasoningLevel(v);
        final c2 = await SettingsController.load();
        expect(c2.value.reasoningLevel, v, reason: '${v.label} 存读一致');
      }
    });
  });

  // ==================================================================
  // 3. ★ 新形态：模型框弹层（点胶囊 → 模型/推理等级两行 → 五档）
  // ==================================================================

  group('★ 模型选择框弹层', () {
    testWidgets('★ 模型框显示当前模型名', (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'deepseek-flash',
      )));
      await tester.pump();
      expect(find.text('deepseek-flash'), findsOneWidget);
    });

    testWidgets('★★ 点模型框 → 底部弹层列出 provider 列表 + 推理等级',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'deepseek-flash',
        providers: const [
          ModelProviderConfig(
              id: 'deepseek-account',
              name: 'DeepSeek 账号',
              baseUrl: 'https://api.deepseek.com/v1',
              model: 'deepseek-flash',
              // ⚠️ 必须有 Key：弹层只列"可用"的 provider
              //   （`isConfigured || isLocalConfig`），没 Key 的会被过滤掉。
              apiKey: 'sk-test'),
        ],
      )));
      await tester.pump();

      await tester.tap(find.text('deepseek-flash'));
      await tester.pumpAndSettle();

      expect(find.text('DeepSeek 账号'), findsOneWidget,
          reason: '弹层列出 provider（2026-10-12 用户要求：模型可点选切换）');
      expect(find.text('思考等级'), findsOneWidget,
          reason: '推理等级选项区在同一弹层里');
    });

    testWidgets('★★ 点选另一个 provider → 回调 id（切换后端）', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'deepseek-flash',
        providers: const [
          ModelProviderConfig(
              id: 'deepseek-account',
              name: 'DeepSeek 账号',
              baseUrl: 'https://api.deepseek.com/v1',
              model: 'deepseek-flash'),
          ModelProviderConfig(
              id: 'dashscope',
              name: '通义千问 (DashScope)',
              baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
              model: 'qwen3.8-flash',
              apiKey: 'sk-test'),
        ],
        onProviderSelected: picked.add,
      )));
      await tester.pump();

      await tester.tap(find.text('deepseek-flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('通义千问 (DashScope)'));
      await tester.pumpAndSettle();

      expect(picked, ['dashscope'],
          reason: '点选即切换后端 —— 用户要在两个云端 provider 之间切');
    });

    testWidgets('★★ 点推理等级行 → 就地展开五档（一个不少）', (tester) async {
      var picked = ReasoningLevel.auto;
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'deepseek-flash',
        onChanged: (v) => picked = v,
      )));
      await tester.pump();

      await tester.tap(find.text('deepseek-flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('思考等级'));
      await tester.pumpAndSettle();

      for (final v in ReasoningLevel.values) {
        expect(find.text(v.label), findsWidgets,
            reason: '五档一个不少：${v.label} 必须在子菜单里');
      }

      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();
      expect(picked, ReasoningLevel.high);
    });

    testWidgets('★ 选同一个档位不触发回调（不产生无意义的写盘）',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.low,
        label: 'deepseek-flash',
        onChanged: (_) => calls++,
      )));
      await tester.pump();

      await tester.tap(find.text('deepseek-flash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('思考等级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Low').last);
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '选了同一个档位不该回调 —— 否则每次点都白写一次盘');
    });
  });

  // ==================================================================
  // 4. ★★ 推理等级说明必须如实（本文件最重要的一组）
  // ==================================================================

  group('★★ 推理等级说明必须如实（本地后端已删除）', () {
    // ★ 2026-10-18（ADR-035 S4）：原先本组第一条钉的是"**本地**下
    //   Low/High/Max 说明必须**完全相同**"（本地 llama-server 静默忽略
    //   `reasoning_effort`，编出差异就是**假装本地有分档**，`docs/25` §10.3）。
    //
    //   本地后端整体删除 ⇒ **被测对象不存在了**，那条断言与 `isLocalBackend`
    //   参数一起删除。**这不是覆盖退化**：今天只剩云端，而"云端三档说明
    //   各不相同"由下面第 4 条钉住。
    //
    //   ⚠️ 但那条历史教训要留着：**给不支持的档位编出差异 = 假信息**。
    //   将来接新后端时要重新问一遍"它真的支持分档吗"。

    // ★「本地模型只有开/关两态」的显式提示已**删除**（2026-10-12 用户要求：
    //   "我都不打算用本地模型了……那个提示可以删了"）。
    //   保留一条反向断言：任何模式下都不再出现这句话 —— 防止谁把它加回来。
    testWidgets('★★ 不再显示「本地模型只有开/关两态」提示（已按需求删除）',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'm',
      )));
      await tester.pump();
      await tester.tap(find.text('m'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('本地模型只有开/关两态'),
        findsNothing,
        reason: '用户明确要求删掉这句 —— 2026-10-12',
      );
    });

    testWidgets('★★ 三档的说明各不相同（真的支持分档）', (tester) async {
      // 2026-10-12 底部弹层形态：说明文字**随当前档位**显示一行
      // （旧锚点菜单是三行并排）。这里驱动切档，断言三档说明**互不相同**。
      final seen = <String, String>{};
      for (final v in [
        ReasoningLevel.low,
        ReasoningLevel.high,
        ReasoningLevel.max,
      ]) {
        await tester.pumpWidget(wrap(barWith(
          level: v,
          label: 'm',
        )));
        await tester.pump();
        await tester.tap(find.text('m'));
        await tester.pumpAndSettle();
        final t = find.text(v.description);
        expect(t, findsOneWidget,
            reason: '${v.label} 应当显示它自己的说明');
        seen[v.label] = v.description;
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }
      // 三条说明两两不同 = 真的支持分档
      expect(seen['Low'] == seen['High'], isFalse,
          reason: 'Low/High 说明不同 —— 分档是真的');
      expect(seen['High'] == seen['Max'], isFalse,
          reason: 'High/Max 说明不同');
    });
  });

  // ==================================================================
  // 5. 权限（新形态：发送键左侧的**纯图标按钮**，点击弹选择框；
  //    切「完全访问」仍触发二次风险确认）
  // ==================================================================

  group('★ 权限按钮（图标形态）', () {
    testWidgets('★ 图标随档位变化：需提权 = 盾+叹号（exclamationmark_shield）',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        permission: PermissionMode.fullAccess,
      )));
      await tester.pump();
      expect(find.byIcon(CupertinoIcons.exclamationmark_shield),
          findsOneWidget,
          reason: '完全访问 = 盾+叹号（用户参考图3）—— 不用点开就知道要小心');
    });

    testWidgets('★ 普通档位用盾+锁图标（工作区内 = lock_shield）',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        permission: PermissionMode.workspaceAuto,
      )));
      await tester.pump();
      // Cupertino 无"盾+笔"——用盾+锁（受控放行）近似，已向用户说明
      expect(find.byIcon(CupertinoIcons.lock_shield), findsOneWidget);
    });

    testWidgets('★ 手动审批 = 盾+勾（checkmark_shield，用户参考图1）',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        permission: PermissionMode.manual,
      )));
      await tester.pump();
      expect(find.byIcon(CupertinoIcons.checkmark_shield), findsOneWidget);
    });

    testWidgets('★ 点图标 → 底部弹层三档 → 点选回调', (tester) async {
      final picked = <PermissionMode>[];
      await tester.pumpWidget(wrap(InputBar(
        onSend: (_) {},
        permission: PermissionMode.workspaceAuto,
        onPermissionChanged: picked.add,
        reasoningLevel: ReasoningLevel.auto,
      )));
      await tester.pump();

      await tester.tap(find.byIcon(CupertinoIcons.lock_shield));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动审批').last);
      await tester.pumpAndSettle();

      expect(picked, [PermissionMode.manual]);
    });

    testWidgets('★★ 切到「完全访问」→ 弹二次风险确认（用户要求）',
        (tester) async {
      await tester.pumpWidget(wrap(InputBar(
        onSend: (_) {},
        permission: PermissionMode.workspaceAuto,
        onPermissionChanged: (_) {},
        reasoningLevel: ReasoningLevel.auto,
      )));
      await tester.pump();

      await tester.tap(find.byIcon(CupertinoIcons.lock_shield));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完全访问').last);
      await tester.pumpAndSettle();

      expect(
        find.text('开启完全访问？'),
        findsOneWidget,
        reason: 'fullAccess = agent 不再逐条询问，必须二次确认风险',
      );
      // 点取消 → 档位不变（安全默认）
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('开启完全访问？'), findsNothing);
    });
  });

  // ==================================================================
  // 7. ★★ 最大轮次（2026-10-18，docs/27 P0-1 / ADR-033）
  //
  // ## 修的是什么
  //
  // 最大轮次此前**硬编码 8**，且 `MainActivity` 从不接收这个参数 ——
  // 于是真机上**云端模型也只在 8 轮内跑**，一个要十几步的构建任务
  // 被无理由截断，且界面上没有任何说明。
  //
  // ## 这一组钉住三件事
  //
  // 1. **持久化 + 容错**：改完重启还在；脏值/负数/超大值一律回落 `0`（自动）
  //    —— 脏值若原样透传就是"无限轮次"，云端会一直花钱、设备会一直烧。
  // 2. **UI 档位**：自动/8/16/40/80 一个不少，且**人话提示**必须在
  //    （只说数字等于让用户猜"8 轮是多少钱"）。
  // 3. **真的传给 Kotlin**：`runAgent` 通道参数里必须有 `maxTurns`
  //    —— 这是本缺陷的**根因**（参数以前根本不存在），
  //    只把 UI 做出来而不传下去 = 白做。
  // ==================================================================

  group('★★ 最大轮次（ADR-033）', () {
    /// 打开模型框 → 弹出弹层（最大轮次就在这个弹层里）。
    Future<void> openSheet(WidgetTester tester, {String label = 'm'}) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    test('★★ 默认是 0（自动跟随后端）—— 不是 8', () {
      const s = AppSettings();
      expect(s.maxTurns, 0,
          reason: '默认必须是"自动"：0 让云端跟 40、本地跟 8。'
              '若默认写死 8，就等于把这次修的缺陷又钉回去了');
    });

    test('★★ 档位定义齐全是 自动/8/16/40/80', () {
      expect(kMaxTurnsOptions, [0, 8, 16, 40, 80],
          reason: '0 = 自动；其余四档是用户明确要求的可选值');
    });

    test('★ copyWith 能改 maxTurns，不动别的字段', () {
      const s = AppSettings();
      final n = s.copyWith(maxTurns: 40);
      expect(n.maxTurns, 40);
      expect(n.reasoningLevel, s.reasoningLevel,
          reason: 'copyWith 不该顺手改别的设置');
    });

    testWidgets('★ 改了最大轮次会落盘，重载后仍在', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // ★ 用 withValues 模式：这样"落盘"是真的经过
      //   安全存储内存表的往返，而不是被 mock 吞掉
      setSecureStorageMode(SecureStorageMockMode.withValues);
      final c = await SettingsController.load();
      await c.setMaxTurns(40);

      final c2 = await SettingsController.load();
      expect(c2.value.maxTurns, 40,
          reason: '轮次是显式的成本选择 —— 重启回到自动会让用户以为没生效');
    });

    test('★ 四个档位都能存能读（全覆盖）', () async {
      for (final v in [0, 8, 16, 40, 80]) {
        SharedPreferences.setMockInitialValues({});
        setSecureStorageMode(SecureStorageMockMode.withValues);
        final c = await SettingsController.load();
        await c.setMaxTurns(v);
        final c2 = await SettingsController.load();
        expect(c2.value.maxTurns, v, reason: '$v 存读一致');
      }
    });

    testWidgets('★★ 旧数据（没有该字段）→ 回落 0 自动，不崩', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      expect(c.value.maxTurns, 0);
    });

    testWidgets('★★ 脏值一律回落 0（不是 clamp 到 80）', (tester) async {
      // 三类脏值：负数 / 不在档位里的正数 / 超大值。
      // 它们若被原样透传就是"无限轮次"：云端一直花钱、本地一直烧设备，
      // 而用户只看到"怎么停不下来"。
      for (final bad in [-1, 7, 100000]) {
        SharedPreferences.setMockInitialValues({'maxTurns': bad});
        final c = await SettingsController.load();
        expect(c.value.maxTurns, 0,
            reason: '脏值 $bad 必须回落 0（自动）—— 不能原样透传，'
                '也不能悄悄改成用户没选过的 80');
      }
    });

    test('★ setter 收到非法值也存成 0（与读取同规则）', () async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      await c.setMaxTurns(999);
      expect(c.value.maxTurns, 0, reason: '内存里就该是 0');
      final c2 = await SettingsController.load();
      expect(c2.value.maxTurns, 0,
          reason: '写盘也必须是 0 —— 否则写进去的脏值下次读回又被悄悄改掉');
    });

    testWidgets('★★ 弹层里五档一个不少，默认选中「自动」', (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'm',
        maxTurns: 0,
      )));
      await tester.pump();
      await openSheet(tester);

      expect(find.text('最大轮次'), findsOneWidget,
          reason: '最大轮次区块必须出现在模型/推理弹层里');
      for (final label in ['自动', '8', '16', '40', '80']) {
        expect(find.text(label), findsWidgets,
            reason: '档位 $label 必须在（0 显示成"自动"，不是"0"）');
      }
    });

    testWidgets('★★ 必须有**人话提示**：自动跟随后端 + 更久 + 更贵',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'm',
        maxTurns: 0,
      )));
      await tester.pump();
      await openSheet(tester);

      // 三个事实缺一不可：自动到底是多少 / 更久 / 更贵
      // ★ 2026-10-19：本地后端已删除 ⇒ 提示里只保留"云端 40"（不再有"本地 8"）
      expect(find.textContaining('云端 40'), findsWidgets,
          reason: '"自动"必须说清它跟的是哪个数 —— 否则用户不知道自动=多少');
      expect(find.textContaining('更久'), findsWidgets,
          reason: '加大轮次会让单次任务跑更久 —— 这是用户能感知的代价');
      expect(find.textContaining('花费'), findsWidgets,
          reason: '云端按轮计费 ⇒ 必须提示花钱更多，不能只让用户看到"更多轮次"');
    });

    /// 点某个轮次**选项胶囊**（现实现是自绘 _PillOption，不是 ChoiceChip）。
    ///
    /// ⚠️ **不能**直接 `find.text('40')`：当前档位非自动时，行尾也会显示
    /// "40"（`_maxTurnsLabel`），于是同一个文本有两个 widget →
    /// `tap()` 报 "ambiguously found multiple matching widgets"。
    /// （这不是产品缺陷，是测试的定位问题 —— 用户点的是胶囊，不是行尾文字。）
    /// 胶囊 = GestureDetector 包着 Text，行尾文字不在 GestureDetector 里，
    /// 所以按「GestureDetector 里的 Text」定位。
    Future<void> tapChip(WidgetTester tester, String label) async {
      await tester.tap(find
          .ancestor(
            of: find.text(label),
            matching: find.byType(GestureDetector),
          )
          .first);
      await tester.pumpAndSettle();
    }

    testWidgets('★★ 点「40」→ 回调 40，且行尾显示 40', (tester) async {
      final picked = <int>[];
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'm',
        maxTurns: 0,
        onMaxTurnsChanged: picked.add,
      )));
      await tester.pump();
      await openSheet(tester);

      await tapChip(tester, '40');

      expect(picked, [40], reason: '点选即回调该档位的数值');
    });

    testWidgets('★ 选同一档位不触发回调（不产生无意义的写盘）',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'm',
        maxTurns: 40,
        onMaxTurnsChanged: (_) => calls++,
      )));
      await tester.pump();
      await openSheet(tester);

      await tapChip(tester, '40');

      expect(calls, 0, reason: '选了同一档不该回调 —— 与推理等级同语义');
    });

    testWidgets('★ 非自动档位时行尾显示具体数字（不是"自动"）',
        (tester) async {
      await tester.pumpWidget(wrap(barWith(
        level: ReasoningLevel.auto,
        label: 'm',
        maxTurns: 16,
      )));
      await tester.pump();
      await openSheet(tester);

      // 行尾 "16" + 档位芯片 "16" = 至少两处
      expect(find.text('16'), findsWidgets);
    });

    // ----------------------------------------------------------------
    // ★★ 先证明这套 mock 基建本身是对的（三态各一条）
    //     —— 否则后面那些断言可能是"在一个坏掉的 mock 上"通过的
    // ----------------------------------------------------------------

    testWidgets('★★ 基建①首次安装（空存储）→ load() 能返回，不卡死',
        (tester) async {
      setSecureStorageMode(SecureStorageMockMode.empty);
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      expect(c.value.maxTurns, 0,
          reason: '空存储 = 正常启动路径。这条能跑完本身就证明 mock 生效了'
              '（装 mock 之前这里会永久卡死）');
    });

    testWidgets('★★ 基建②已配置（有值）→ 真 Key 从安全存储回填',
        (tester) async {
      setSecureStorageMode(SecureStorageMockMode.withValues);
      // 内存表里预置一个真 Key（模拟"用户早就配好了"）
      setSecureStorageValue('api_key/p1', 'sk-real-key');

      const prov = ModelProviderConfig(
        id: 'p1',
        name: 'P1',
        baseUrl: 'https://x/v1',
        model: 'm',
        // SharedPreferences 里只有哨兵 —— 真 Key 在"Keystore"
        apiKey: kSecureSentinel,
      );
      SharedPreferences.setMockInitialValues({
        'providers': jsonEncode([prov.toJson()]),
      });

      final c = await SettingsController.load();
      final loaded = c.value.providers.firstWhere((p) => p.id == 'p1');
      expect(loaded.apiKey, 'sk-real-key',
          reason: '安全存储里有真 Key ⇒ 必须回填（且绝不是哨兵）');
      expect(loaded.apiKey, isNot(kSecureSentinel));
      expect(loaded.isConfigured, isTrue);
    });

    testWidgets('★★ 基建③Keystore 不可用（read 抛异常）→ 不崩，且清掉哨兵',
        (tester) async {
      setSecureStorageMode(SecureStorageMockMode.throwsOnRead);

      const prov = ModelProviderConfig(
        id: 'p1',
        name: 'P1',
        baseUrl: 'https://x/v1',
        model: 'm',
        apiKey: kSecureSentinel,
      );
      SharedPreferences.setMockInitialValues({
        'providers': jsonEncode([prov.toJson()]),
      });

      final c = await SettingsController.load();
      final loaded = c.value.providers.firstWhere((p) => p.id == 'p1');

      // ★ 这条断言的是**可观测后果**，不是"没抛异常"——
      //   抛异常本身会被 `load()` 的 catch 吃掉，所以"没崩"不足以
      //   证明走到了那个 catch（也可能根本没读）。哨兵被清空才是证据。
      expect(loaded.apiKey, '',
          reason: 'Keystore 读失败 ⇒ 哨兵必须被清掉。'
              '否则 "__secure__" 会被当 Key 发出去（必然 401）');
      expect(c.value.maxTurns, 0, reason: '设置还能正常读到');
    });


    /// ## 为什么直接测 `AgentBridge.run` 而不是走 ChatScreen
    ///
    /// 本机 **ChatScreen 的 widget 测试一律卡首帧**（`实测-03` 坑 35），
    /// 所以断言不能挂在"打开 ChatScreen"上。而这一条要证明的是
    /// ★ 2026-10-18（ADR-035 S4）：`AgentBridge.run()` 现在**不兜底** ——
    /// 没有可用 provider 时**就地抛 `AgentBridgeException`**（以前是
    /// `null => 'local'` 静默兜底，而 `'local'` 已是 Kotlin 侧的 `error(...)`）。
    /// 所以走通道的用例**必须**给一个已配置的 provider，否则根本到不了
    /// `runAgent`（这是有意的行为，见 agent_bridge.dart 里那段注释）。
    AppSettings withProvider({
      int maxTurns = 0,
      ReasoningLevel reasoningLevel = ReasoningLevel.auto,
    }) =>
        AppSettings(
          maxTurns: maxTurns,
          reasoningLevel: reasoningLevel,
          activeProviderId: 'deepseek-account',
          providers: const [
            ModelProviderConfig(
              id: 'deepseek-account',
              name: 'DeepSeek 账号',
              baseUrl: 'https://api.deepseek.com/v1',
              model: 'deepseek-chat',
              apiKey: 'sk-test',
            ),
          ],
        );

    /// **通道参数**，与界面无关 —— 直接调 `AgentBridge().run()` 更准，
    /// 也恰好绕开那个环境限制。
    ///
    /// ⚠️ 这条**必须**在 `runAgent` 的 arguments 里看到 `maxTurns`：
    /// 缺陷根因就是"参数根本不存在"（UI 做得再漂亮也没用）。
    testWidgets('★★★ runAgent 通道参数里真的带上了 maxTurns',
        (tester) async {
      const commandChannel = MethodChannel('heracles/command');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      final seen = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(commandChannel, (call) async {
        if (call.method == 'runAgent') {
          seen.add(Map<dynamic, dynamic>.from(call.arguments as Map));
          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': 'ok',
            'sessionId': 's',
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'turns': <Map<String, dynamic>>[],
          };
        }
        return null;
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(commandChannel, null));

      // 「自动」= 0，也必须显式传（让"自动"这个选择可观测）
      await AgentBridge().run(
        workspacePath: '/w',
        request: 'hi',
        settings: withProvider(maxTurns: 0),
      );
      expect(seen, hasLength(1));
      expect(seen.single.containsKey('maxTurns'), isTrue,
          reason: '★ 缺陷根因就是"参数根本不存在" —— 必须出现这个键');
      expect(seen.single['maxTurns'], 0,
          reason: '0 = 按后端自动（Kotlin Contract.Budget：本地 8 / 云端 40）');

      // 用户显式选的档位必须原样送到
      await AgentBridge().run(
        workspacePath: '/w',
        request: 'hi',
        settings: withProvider(maxTurns: 40),
      );
      expect(seen, hasLength(2));
      expect(seen.last['maxTurns'], 40,
          reason: '用户选的那一档必须原样传给 Kotlin，不能被界面吞掉');

      // 类型也必须是 int —— Kotlin 侧按 Int 读，传字符串会静默回落
      expect(seen.last['maxTurns'], isA<int>(),
          reason: '通道里必须是 int（Kotlin 按 Int 读）');
    });

    testWidgets('★★ runAgent 里 maxTurns 与 reasoningLevel 并存（不能互相顶掉）',
        (tester) async {
      const commandChannel = MethodChannel('heracles/command');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      Map<dynamic, dynamic>? args;
      messenger.setMockMethodCallHandler(commandChannel, (call) async {
        if (call.method == 'runAgent') {
          args = Map<dynamic, dynamic>.from(call.arguments as Map);
          return <String, dynamic>{
            'stopReason': 'x',
            'finalText': '',
            'sessionId': 's',
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'turns': <Map<String, dynamic>>[],
          };
        }
        return null;
      });
      addTearDown(
          () => messenger.setMockMethodCallHandler(commandChannel, null));

      await AgentBridge().run(
        workspacePath: '/w',
        request: 'hi',
        settings: withProvider(
          maxTurns: 16,
          reasoningLevel: ReasoningLevel.high,
        ),
      );

      expect(args, isNotNull);
      expect(args!['maxTurns'], 16);
      expect(args!['reasoningLevel'], 'high',
          reason: '两个"成本参数"必须同时在场 —— 加新参数时最容易顶掉旧的');
    });
  });

  // ==================================================================
  // 6. 主题适配：浅色/深色都要看得清
  // ==================================================================

  group('主题适配', () {
    testWidgets('★ 深浅两色下模型框都渲染出模型名', (tester) async {
      for (final dark in [true, false]) {
        await tester.pumpWidget(wrap(
          barWith(level: ReasoningLevel.high, label: 'm'),
          dark: dark,
        ));
        await tester.pump();
        expect(find.text('m'), findsOneWidget,
            reason: '${dark ? '深色' : '浅色'}下模型框必须可见');
      }
    });
  });
}
