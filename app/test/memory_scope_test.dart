import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';

import 'support/secure_storage_mock.dart';

/// **记忆页三作用域（第 9 条 / F9）** —— UI 侧门禁。
///
/// 契约：`docs/INTERFACE.md` §N12；设计稿 `.docs/记忆系统重设计-2026-10-29.md` §4.4。
///
/// 后端 B1 **未交付** ⇒ 本页的数据源是一个 UI 侧可注入的抽象
/// （[MemoryDataSource]）：默认实现只敢用 HEAD 就有的旧 API 读全局，
/// 工作区/会话如实降级「后端 B1 接入中」；本文件注入 mock 覆盖三段 /
/// 两组预算 / 提议晋升 / 分作用域清空。
///
/// 钉住的缺陷：
/// 1. 旧页面只有「全局一份 + 256KB 上限」，没有作用域概念（混一层就串台）；
/// 2. 旧容量卡把存储硬上限当每轮注入开销（「会注入每次对话」），把用户吓坏；
/// 3. 旧页面把「读失败」显示成「暂无记忆」（两句话，说错就骗人）；
/// 4. 旧页面一个清空按钮清所有记忆（无法只清会话私有）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  /// 固定帧推进：**不用 pumpAndSettle** —— 加载态是无限转圈，抽屉/轻提示
  /// 是有限动画，固定帧对两者都安全（也避免 settle 等不到的假挂死）。
  Future<void> frames(WidgetTester tester, {int n = 12}) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 轻提示用的是 `Future.delayed(2.2s)` 移除（见 cupertino_kit.showIosToast）——
  /// 用例结束时把计时器放干净，否则 flutter_test 报 "Timer is still pending"。
  Future<void> flushToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 1));
  }

  const sid = 's1791611845161';

  Future<void> pumpPage(
    WidgetTester tester,
    MemoryDataSource src, {
    String? sessionId,
    String? workspacePath,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(GlobalMemoryPage(
      source: src,
      sessionId: sessionId,
      workspacePath: workspacePath ?? (sessionId == null ? null : '/ws/demo'),
    )));
    await frames(tester);
  }

  MemoryScopeEntry entry(
    String id,
    String text, {
    String kind = 'other',
    String source = 'user',
    int createdAt = 1791612000000,
  }) =>
      MemoryScopeEntry(
        id: id,
        kind: kind,
        text: text,
        source: source,
        createdAt: createdAt,
      );

  final globalKey = const ValueKey('memory_scope_global');
  final workspaceKey = const ValueKey('memory_scope_workspace');
  final sessionKey = const ValueKey('memory_scope_session');

  group('三作用域', () {
    testWidgets('三段齐备 + 作用域标注 + 条目各归其段（不串台）', (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(entry('g1', '全局条目正文'))
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '工作区条目正文'))
        ..entries[MemoryScopeView.session]!.add(entry('s1', '会话条目正文'));
      await pumpPage(tester, src, sessionId: sid);

      expect(find.byKey(globalKey), findsOneWidget);
      expect(find.byKey(workspaceKey), findsOneWidget);
      expect(find.byKey(sessionKey), findsOneWidget);

      expect(find.descendant(of: find.byKey(globalKey), matching: find.text('全局')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(workspaceKey), matching: find.text('本工作区')),
          findsOneWidget);
      expect(
          find.descendant(of: find.byKey(sessionKey), matching: find.text('本会话')),
          findsOneWidget);

      // 每个条目只在自己那一段里（串台会让"会话私有"变成全局可见）
      expect(
          find.descendant(
              of: find.byKey(globalKey), matching: find.text('全局条目正文')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(workspaceKey), matching: find.text('工作区条目正文')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(sessionKey), matching: find.text('会话条目正文')),
          findsOneWidget);
      for (final other in [workspaceKey, sessionKey]) {
        expect(
            find.descendant(
                of: find.byKey(other), matching: find.text('全局条目正文')),
            findsNothing,
            reason: '全局条目不许出现在 ${(other as ValueKey).value} 段');
      }

      // 作用域语义标注（F9 指定文案）
      expect(
          find.descendant(
              of: find.byKey(globalKey),
              matching: find.textContaining('全局记忆对所有会话只读')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(workspaceKey),
              matching: find.textContaining('本工作区所有会话共享')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(sessionKey),
              matching: find.textContaining('只在本会话生效')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有会话上下文 ⇒ 不渲染「本会话」段，改为指向会话的提示', (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(entry('g1', '全局条目正文'));
      await pumpPage(tester, src);

      expect(find.byKey(sessionKey), findsNothing,
          reason: '设置主页进记忆页没有会话上下文，不能画一个假的会话记忆段');
      expect(find.text('本会话'), findsNothing);
      expect(find.textContaining('进入某个会话'), findsOneWidget,
          reason: '要告诉用户会话记忆去哪看（F9 原文）');
      // 全局 / 工作区仍然在
      expect(find.byKey(globalKey), findsOneWidget);
      expect(find.byKey(workspaceKey), findsOneWidget);
    });
  });

  group('空态 / 读失败 / 未接入', () {
    testWidgets('三段各自的空态都写「暂无记忆」', (tester) async {
      await pumpPage(tester, FakeMemorySource(), sessionId: sid);

      expect(find.text('暂无记忆'), findsNWidgets(3));
      expect(find.text('读取失败'), findsNothing);
    });

    testWidgets('★★ 读失败 ≠ 暂无记忆：错误态显式，其它段仍是空态', (tester) async {
      final src = FakeMemorySource()
        ..errors[MemoryScopeView.global] = '设备通道不可用（假）';
      await pumpPage(tester, src, sessionId: sid);

      final g = find.byKey(globalKey);
      expect(find.descendant(of: g, matching: find.text('读取失败')),
          findsOneWidget);
      expect(
          find.descendant(of: g, matching: find.textContaining('设备通道不可用（假）')),
          findsOneWidget);
      expect(find.descendant(of: g, matching: find.text('暂无记忆')), findsNothing,
          reason: '"读不出来"和"还没有记忆"是两句话，说错就骗人');
      // 工作区 / 会话没出错 ⇒ 各自仍显示空态
      expect(find.text('暂无记忆'), findsNWidgets(2));
    });

    testWidgets('读失败后点「重试」→ 重新读，读到了就换正常列表', (tester) async {
      final src = FakeMemorySource()
        ..errors[MemoryScopeView.global] = '设备通道不可用（假）';
      await pumpPage(tester, src, sessionId: sid);

      src.errors.remove(MemoryScopeView.global);
      src.entries[MemoryScopeView.global]!.add(entry('g1', '重试读到了'));
      await tester.tap(find.byKey(const ValueKey('memory_retry_global')));
      await frames(tester);

      expect(find.text('读取失败'), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(globalKey), matching: find.text('重试读到了')),
          findsOneWidget);
    });

    testWidgets('★★ 默认数据源（未注入）：工作区/会话如实降级「后端 B1 接入中」，不假装空',
        (tester) async {
      // 默认源要过 `heracles/device` 通道读全局；测试环境没有原生实现，
      // 必须挂一个替身 —— 否则那个 await 会**永久挂起**（与
      // flutter_secure_storage 未 mock 同一个坑，见 AGENTS.md 环境坑 5）。
      const channel = MethodChannel('heracles/device');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return <String, Object?>{
          'ok': false,
          'error': '设备通道不可用（测试替身）',
        };
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await tester.binding.setSurfaceSize(const Size(390, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(wrap(const GlobalMemoryPage(sessionId: sid)));
      await frames(tester);

      expect(tester.takeException(), isNull);
      // B1 未交付 ⇒ 两段都显示降级，不是「暂无记忆」（不许假造后端能力）
      expect(
          find.descendant(
              of: find.byKey(workspaceKey),
              matching: find.textContaining('后端 B1 接入中')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(sessionKey),
              matching: find.textContaining('后端 B1 接入中')),
          findsOneWidget);
      expect(find.text('暂无记忆'), findsNothing);
      // 全局段走 HEAD 旧 API：通道如实报错 ⇒ 页面显示「读取失败」
      final g = find.byKey(globalKey);
      expect(find.descendant(of: g, matching: find.text('读取失败')),
          findsOneWidget);
      expect(
          find.descendant(
              of: g, matching: find.textContaining('设备通道不可用（测试替身）')),
          findsOneWidget);
    });
  });

  group('两组数字（存储软预算 / 注入预算）', () {
    testWidgets('★★ 存储软预算 + 注入预算两组数字；无 256KB 压迫、无「会注入每次对话」',
        (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(entry('g1', '全局条目'))
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '工作区条目'))
        ..entries[MemoryScopeView.session]!.add(entry('s1', '会话条目'))
        ..used[MemoryScopeView.global] = 12 * 1024
        ..softMax[MemoryScopeView.global] = 8 * 1024 * 1024
        ..used[MemoryScopeView.workspace] = 3 * 1024
        ..softMax[MemoryScopeView.workspace] = 16 * 1024 * 1024
        ..used[MemoryScopeView.session] = 512
        ..softMax[MemoryScopeView.session] = 512 * 1024
        ..budget = MemoryBudgetSnapshot.ok(
          globalWorkspaceInjectChars: 6000,
          sessionInjectChars: 4000,
          fromHost: true,
        );
      await pumpPage(tester, src, sessionId: sid);

      final card = find.byKey(const ValueKey('memory_budget'));
      expect(card, findsOneWidget);
      // ① 存储：已用 / 软预算（不是"上限"，不是百分比压迫）
      expect(find.descendant(of: card, matching: find.text('存储软预算')),
          findsOneWidget);
      expect(find.text('已用 12 KB · 软预算 8 MB'), findsOneWidget);
      expect(
          find.descendant(
              of: card, matching: find.textContaining('满了会淘汰最旧条目')),
          findsOneWidget);
      expect(
          find.descendant(of: card, matching: find.textContaining('不会拒绝新增')),
          findsOneWidget);
      // ② 注入：两组字符上限 + 检索式注入口径
      expect(find.descendant(of: card, matching: find.text('注入预算')),
          findsOneWidget);
      expect(find.text('每轮最多 6000 字符（全局 + 本工作区）'), findsOneWidget);
      expect(find.text('每轮最多 4000 字符（本会话）'), findsOneWidget);
      expect(find.descendant(of: card, matching: find.textContaining('按任务检索后注入')),
          findsOneWidget);
      // 旧口径必须真的消失
      expect(find.textContaining('会注入每次对话'), findsNothing);
      expect(find.textContaining('接近上限'), findsNothing);
      expect(find.textContaining('256 KB'), findsNothing,
          reason: '256KB 硬上限是这次要废除的口径，不许再出现在页面上');
      expect(find.textContaining('上限 '), findsNothing);
    });

    testWidgets('注入预算未接入时如实降级，不编数字', (tester) async {
      final src = FakeMemorySource()
        ..budget = const MemoryBudgetSnapshot.unavailable('待后端 B1 接入');
      await pumpPage(tester, src, sessionId: sid);

      final card = find.byKey(const ValueKey('memory_budget'));
      expect(find.descendant(of: card, matching: find.text('待后端 B1 接入')),
          findsOneWidget);
      expect(find.textContaining('每轮最多'), findsNothing,
          reason: '宿主还没回报上限，不许自己编一个数字');
    });
  });

  group('增删改（mock B1 API）', () {
    testWidgets('添加：本工作区新增一条 → 落到工作区段 + 回调 add(workspace)',
        (tester) async {
      final src = FakeMemorySource();
      await pumpPage(tester, src, sessionId: sid);

      await tester.tap(find.byKey(const ValueKey('memory_add_workspace')));
      await frames(tester);
      expect(find.text('添加记忆'), findsOneWidget);

      await tester.enterText(find.byType(CupertinoTextField), '新记的一条');
      await tester.tap(find.text('保存'));
      await frames(tester);

      expect(src.calls, contains('add:workspace'));
      expect(
          find.descendant(
              of: find.byKey(workspaceKey), matching: find.text('新记的一条')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(sessionKey), matching: find.text('新记的一条')),
          findsNothing,
          reason: '加在工作区，不许同时出现在会话段');
      await flushToast(tester);
    });

    testWidgets('编辑：改正文 → 回调 update(workspace)，旧文本不再显示', (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '旧正文'));
      await pumpPage(tester, src, sessionId: sid);

      final card = find.byKey(const ValueKey('memory_entry_workspace_w1'));
      await tester.tap(
          find.descendant(of: card, matching: find.byIcon(AppIcons.edit)));
      await frames(tester);
      expect(find.text('编辑记忆'), findsOneWidget);

      await tester.enterText(find.byType(CupertinoTextField), '改过的正文');
      await tester.tap(find.text('保存'));
      await frames(tester);

      expect(src.calls, contains('update:workspace'));
      expect(find.text('改过的正文'), findsOneWidget);
      expect(find.text('旧正文'), findsNothing);
      await flushToast(tester);
    });

    testWidgets('删除：先确认再删（单条删除仍走确认交互）', (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '要删掉的'));
      await pumpPage(tester, src, sessionId: sid);

      final card = find.byKey(const ValueKey('memory_entry_workspace_w1'));
      await tester.tap(
          find.descendant(of: card, matching: find.byIcon(AppIcons.trash)));
      await frames(tester);
      expect(find.text('删除这条记忆？'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await frames(tester);

      expect(src.calls, contains('remove:workspace'));
      expect(find.text('要删掉的'), findsNothing);
      expect(src.entries[MemoryScopeView.workspace], isEmpty);
      await flushToast(tester);
    });
  });

  group('模型想记住（提议晋升 / 忽略）', () {
    testWidgets('★★ 提议列表：晋升 → 调 resolve(promote) 并进全局段', (tester) async {
      final src = FakeMemorySource()
        ..proposals = MemoryProposalsSnapshot.ok([
          const MemoryProposal(
              id: 'p1', text: '用户喜欢黑色主题', kind: 'preference'),
          const MemoryProposal(id: 'p2', text: '项目用 Flutter', kind: 'background'),
        ]);
      await pumpPage(tester, src, sessionId: sid);

      expect(find.text('模型想记住（2）'), findsOneWidget);
      expect(find.text('用户喜欢黑色主题'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('memory_promote_p1')));
      await frames(tester);

      expect(src.calls, contains('resolve:p1:promote'));
      expect(find.text('已晋升为全局记忆'), findsOneWidget);
      // 晋升后进全局段（全局是"用户确认过的记忆"）；提议列表少一条
      expect(
          find.descendant(
              of: find.byKey(globalKey), matching: find.text('用户喜欢黑色主题')),
          findsOneWidget);
      expect(find.text('模型想记住（1）'), findsOneWidget);
      await flushToast(tester);
    });

    testWidgets('提议列表：忽略 → 调 resolve(reject)，处理完板块消失', (tester) async {
      final src = FakeMemorySource()
        ..proposals = MemoryProposalsSnapshot.ok([
          const MemoryProposal(id: 'p1', text: '一条不该记住的', kind: 'other'),
        ]);
      await pumpPage(tester, src, sessionId: sid);

      await tester.tap(find.byKey(const ValueKey('memory_reject_p1')));
      await frames(tester);

      expect(src.calls, contains('resolve:p1:reject'));
      expect(find.textContaining('模型想记住'), findsNothing,
          reason: '没有待确认提议时不该留一个空标题');
      expect(find.text('一条不该记住的'), findsNothing);
      await flushToast(tester);
    });

    testWidgets('提议未接入（B1 未交付）⇒ 不渲染提议板块（不显示假 0 条）',
        (tester) async {
      final src = FakeMemorySource()
        ..proposals = const MemoryProposalsSnapshot.unavailable('待后端 B1 接入');
      await pumpPage(tester, src, sessionId: sid);

      expect(find.textContaining('模型想记住'), findsNothing);
    });
  });

  group('分作用域清空', () {
    testWidgets('★★ 清空全局：确认文案带作用域，只清全局不碰工作区/会话',
        (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(entry('g1', '全局条目'))
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '工作区条目'))
        ..entries[MemoryScopeView.session]!.add(entry('s1', '会话条目'));
      await pumpPage(tester, src, sessionId: sid);

      await tester.tap(find.byKey(const ValueKey('memory_clear_global')));
      await frames(tester);
      expect(find.text('清空全局记忆？'), findsOneWidget);

      await tester.tap(find.text('清空记忆'));
      await frames(tester);

      expect(src.calls, contains('clear:global'));
      expect(src.entries[MemoryScopeView.global], isEmpty);
      expect(src.entries[MemoryScopeView.workspace], isNotEmpty,
          reason: '清全局不许连工作区一起清（旧版一个按钮清所有层）');
      expect(src.entries[MemoryScopeView.session], isNotEmpty);
      expect(
          find.descendant(
              of: find.byKey(globalKey), matching: find.text('暂无记忆')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(workspaceKey), matching: find.text('工作区条目')),
          findsOneWidget);
      await flushToast(tester);
    });

    testWidgets('★★ 清空本工作区 / 清空本会话：各自独立确认、互不影响', (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(entry('g1', '全局条目'))
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '工作区条目'))
        ..entries[MemoryScopeView.session]!.add(entry('s1', '会话条目'));
      await pumpPage(tester, src, sessionId: sid);

      await tester.tap(find.byKey(const ValueKey('memory_clear_workspace')));
      await frames(tester);
      expect(find.text('清空本工作区记忆？'), findsOneWidget);
      await tester.tap(find.text('清空记忆'));
      await frames(tester);
      expect(src.calls, contains('clear:workspace'));
      expect(src.entries[MemoryScopeView.workspace], isEmpty);
      expect(src.entries[MemoryScopeView.global], isNotEmpty);
      expect(src.entries[MemoryScopeView.session], isNotEmpty);
      await flushToast(tester);

      await tester.tap(find.byKey(const ValueKey('memory_clear_session')));
      await frames(tester);
      expect(find.text('清空本会话记忆？'), findsOneWidget);
      await tester.tap(find.text('清空记忆'));
      await frames(tester);
      expect(src.calls, contains('clear:session'));
      expect(src.entries[MemoryScopeView.session], isEmpty);
      expect(src.entries[MemoryScopeView.global], isNotEmpty);
      await flushToast(tester);
    });
  });

  group('legacy 与主页徽章', () {
    testWidgets('legacy 旧纯文本条目保留「旧格式」标识', (tester) async {
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(
            entry('legacy-1', '旧纯文本记忆行', source: 'legacy', createdAt: 0));
      await pumpPage(tester, src, sessionId: sid);

      expect(
          find.descendant(
              of: find.byKey(globalKey), matching: find.text('旧格式')),
          findsOneWidget);
    });

    testWidgets('★★ 设置主页徽章按作用域计数：全局 N · 本工作区 M', (tester) async {
      installSecureStorageMock();
      SharedPreferences.setMockInitialValues({});
      final controller = await SettingsController.load();
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(entry('g1', '全局一'))
        ..entries[MemoryScopeView.global]!.add(entry('g2', '全局二'))
        ..entries[MemoryScopeView.workspace]!.add(entry('w1', '工作区一'));

      await tester.binding.setSurfaceSize(const Size(390, 1750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: SettingsScreen(controller: controller, memorySource: src),
      ));
      await frames(tester);

      expect(
          find.descendant(
              of: find.byKey(const ValueKey('memory_home_row')),
              matching: find.text('全局 2 · 本工作区 1')),
          findsOneWidget);
    });

    testWidgets('★★ 徽章读失败显示「读取失败」，不是「暂无记忆」', (tester) async {
      installSecureStorageMock();
      SharedPreferences.setMockInitialValues({});
      final controller = await SettingsController.load();
      final src = FakeMemorySource()
        ..errors[MemoryScopeView.global] = '通道不可用（假）';

      await tester.binding.setSurfaceSize(const Size(390, 1750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: SettingsScreen(controller: controller, memorySource: src),
      ));
      await frames(tester);

      final row = find.byKey(const ValueKey('memory_home_row'));
      expect(find.descendant(of: row, matching: find.text('读取失败')),
          findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('暂无记忆')),
          findsNothing);
    });
  });
}

/// UI 侧数据源的 mock（B1 未交付）：可逐段注入条目 / 错误 / 未接入 /
/// 容量与预算数字，并记录每次写调用（断言"清了哪一层"）。
class FakeMemorySource implements MemoryDataSource {
  final Map<MemoryScopeView, List<MemoryScopeEntry>> entries = {
    MemoryScopeView.global: <MemoryScopeEntry>[],
    MemoryScopeView.workspace: <MemoryScopeEntry>[],
    MemoryScopeView.session: <MemoryScopeEntry>[],
  };

  /// 非 null ⇒ 该作用域**读取失败**（"错"与"空"必须不同形）
  final Map<MemoryScopeView, String> errors = {};

  /// 非 null ⇒ 该作用域**未接入**（B1 未交付时的降级）
  final Map<MemoryScopeView, String> unavailable = {};

  final Map<MemoryScopeView, int> used = {};
  final Map<MemoryScopeView, int> softMax = {};

  MemoryProposalsSnapshot proposals =
      const MemoryProposalsSnapshot.unavailable('待后端 B1 接入');
  MemoryBudgetSnapshot budget =
      const MemoryBudgetSnapshot.unavailable('待后端 B1 接入');

  final List<String> calls = [];
  int _seq = 0;

  @override
  Future<MemoryScopeSnapshot> loadScope(MemoryScopeView scope) async {
    calls.add('load:${scope.name}');
    final err = errors[scope];
    if (err != null) return MemoryScopeSnapshot.error(err);
    final why = unavailable[scope];
    if (why != null) return MemoryScopeSnapshot.unavailable(why);
    final list = List<MemoryScopeEntry>.of(entries[scope] ?? const []);
    return MemoryScopeSnapshot.ok(
      entries: list,
      usedBytes: used[scope],
      softMaxBytes: softMax[scope],
    );
  }

  @override
  Future<MemoryProposalsSnapshot> loadProposals() async {
    calls.add('proposals');
    return proposals;
  }

  @override
  Future<MemoryBudgetSnapshot> loadBudget() async {
    calls.add('budget');
    return budget;
  }

  @override
  Future<MemoryWriteOutcome> add(
    MemoryScopeView scope,
    String text, {
    String kind = 'other',
  }) async {
    calls.add('add:${scope.name}');
    entries[scope]!.add(MemoryScopeEntry(
      id: 'new${++_seq}',
      kind: kind,
      text: text,
      source: 'user',
      createdAt: 1791612000000,
    ));
    return const MemoryWriteOutcome.ok();
  }

  @override
  Future<MemoryWriteOutcome> update(
      MemoryScopeView scope, String id, String text) async {
    calls.add('update:${scope.name}');
    final list = entries[scope]!;
    final i = list.indexWhere((e) => e.id == id);
    if (i < 0) return const MemoryWriteOutcome.failure('条目不存在');
    list[i] = MemoryScopeEntry(
      id: list[i].id,
      kind: list[i].kind,
      text: text,
      source: list[i].source,
      createdAt: list[i].createdAt,
    );
    return const MemoryWriteOutcome.ok();
  }

  @override
  Future<MemoryWriteOutcome> remove(MemoryScopeView scope, String id) async {
    calls.add('remove:${scope.name}');
    entries[scope]!.removeWhere((e) => e.id == id);
    return const MemoryWriteOutcome.ok();
  }

  @override
  Future<MemoryWriteOutcome> clear(MemoryScopeView scope) async {
    calls.add('clear:${scope.name}');
    entries[scope]!.clear();
    return const MemoryWriteOutcome.ok();
  }

  @override
  Future<MemoryWriteOutcome> resolveProposal(String id,
      {required bool promote}) async {
    calls.add('resolve:$id:${promote ? 'promote' : 'reject'}');
    final p = proposals;
    if (p.status != MemoryLoadStatus.ok) {
      return const MemoryWriteOutcome.failure('提议列表未接入');
    }
    final chosen = p.entries.where((e) => e.id == id).toList();
    proposals = MemoryProposalsSnapshot.ok(
        p.entries.where((e) => e.id != id).toList());
    if (promote && chosen.isNotEmpty) {
      entries[MemoryScopeView.global]!.add(MemoryScopeEntry(
        id: 'promoted-$id',
        kind: chosen.first.kind,
        text: chosen.first.text,
        source: 'promoted',
        createdAt: 1791612000000,
      ));
    }
    return const MemoryWriteOutcome.ok();
  }
}
