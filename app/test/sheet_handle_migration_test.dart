// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **抽屉抓手迁移（T2-4，2026-10-31 用户定版）**：抽屉的抓手只有一处来源 ——
// `BwSheetShell` 默认渲染的共享 `BwSheetHandle`（36×4 / pill / h.border）。
// 各抽屉自己的那行 36×4 自绘抓手必须删掉，否则真机上会出现**双抓手**
// （壳一个 + 内容一个），用户看到两条横线。
//
// 本文件是**运行时**断言（`test/sheet_handle_guard_test.dart` 是源码级
// 防回归）：每个迁移过的抽屉泵出来，数"36×4 的抓手容器"必须恰好 1 个。
//
// 另外钉住菜单行样式：抽屉里的动作行统一是 `BwActionCard`（边框动作卡），
// 不再用裸 `InkWell` 行 —— 消息长按菜单此前就是裸行（无边框、无抓手）。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/session_usage.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/models/view_options.dart';
import 'package:heracles/models/workspace.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/widgets/bw_model_sheet.dart';
import 'package:heracles/widgets/bw_usage_sheet.dart';
import 'package:heracles/widgets/git_branch_sheet.dart';
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/workspace_drawer.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  Future<void> settle(WidgetTester tester, {int times = 20}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 抽屉里"36 宽 + 4/5 高"的抓手容器个数。
  ///
  /// 迁移前 = 2（壳渲染的 `BwSheetHandle` + 抽屉自绘的那条）⇒ 必须变红；
  /// 迁移后 = 1。断言落在**实际渲染尺寸**上，而不是只看
  /// `find.byType(BwSheetHandle)`（后者数不到自绘的那条，会假绿）。
  int handleCount(WidgetTester tester) {
    final containers = find.descendant(
      of: find.byType(BwSheetShell),
      matching: find.byType(Container),
    );
    var n = 0;
    for (final element in containers.evaluate()) {
      final one = find.byElementPredicate((e) => e == element);
      if (one.evaluate().isEmpty) continue;
      final size = tester.getSize(one);
      if (size.width == 36 && (size.height == 4 || size.height == 5)) n++;
    }
    return n;
  }

  /// 泵一个「打开」按钮 → 点开抽屉 → 推到静止。
  Future<void> openSheet(
    WidgetTester tester,
    Future<void> Function(BuildContext ctx) open,
  ) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () => open(ctx),
          child: const Text('打开'),
        ),
      ),
    )));
    await tester.tap(find.text('打开'));
    await settle(tester);
  }

  Finder drawerHandles() => find.byType(BwSheetHandle);

  // ---------------------------------------------------------------- bw_approval

  testWidgets('审批请求抽屉：只有一个抓手（不再自绘）', (tester) async {
    await openSheet(tester, (ctx) async {
      await showApprovalRequestSheet(
        ctx,
        tool: 'run_shell_command',
        argsPreview: 'command: ls',
        risk: '执行命令',
        allowStop: true,
      );
    });
    expect(find.text('需要你的批准'), findsOneWidget, reason: '前提：抽屉真的开了');
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1,
        reason: '抓手只能由 BwSheetShell 渲染一处；自绘的那条已迁移');
    expect(tester.takeException(), isNull);
  });

  testWidgets('审批模式抽屉：只有一个抓手（不再自绘）', (tester) async {
    await openSheet(tester, (ctx) async {
      await showApprovalModeSheet(
        ctx,
        current: PermissionMode.manual,
        onPicked: (mode) {},
      );
    });
    expect(find.text('审批模式'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1, reason: '壳的抓手 + 抽屉自绘抓手 = 双抓手');
    expect(tester.takeException(), isNull);
  });

  testWidgets('完全访问二次确认抽屉：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showFullAccessConfirmSheet(ctx);
    });
    expect(find.text('开启完全访问？'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用单选抽屉：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showBwRadioSheet<String>(
        ctx,
        title: '选择一档',
        options: const ['甲', '乙'],
        current: '甲',
        labelOf: (v) => v,
      );
    });
    expect(find.text('选择一档'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用确认抽屉：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showBwConfirmSheet(
        ctx,
        title: '删除这个会话？',
        confirmLabel: '删除',
        destructive: true,
      );
    });
    expect(find.text('删除这个会话？'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用文本输入抽屉：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showBwTextInputSheet(ctx, title: '重命名会话');
    });
    expect(find.text('重命名会话'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提问弹层：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showAskGateSheet(ctx, questions: const <Map<String, dynamic>>[
        {
          'id': 'q1',
          'question': '选哪个方案？',
          'multi': false,
          'options': [
            {'label': '甲', 'description': ''},
            {'label': '乙', 'description': ''},
          ],
        },
      ]);
    });
    expect(find.text('选哪个方案？'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- 其它 widgets 抽屉

  testWidgets('模型抽屉：只有一个抓手', (tester) async {
    ModelProviderConfig cfg(String id, String model) => ModelProviderConfig(
          id: id,
          name: id,
          baseUrl: 'https://api.example.com/v1',
          model: model,
          apiKey: 'sk-test',
        );
    await openSheet(tester, (ctx) async {
      await showModelSheet(
        ctx,
        providers: [cfg('p1', 'm-one'), cfg('p2', 'm-two')],
        activeProviderId: 'p1',
        reasoningLevel: ReasoningLevel.auto,
        onProviderSelected: (id) {},
      );
    });
    expect(find.text('模型'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分支抽屉：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showGitBranchSheet(
        ctx,
        loader: () async => ['master', 'frontend'],
        current: 'master',
      );
    });
    expect(find.text('选择分支'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('用量抽屉：只有一个抓手', (tester) async {
    await openSheet(tester, (ctx) async {
      await showUsageSheet(
        ctx,
        const SessionUsage(),
        const ContextUsage(
          frozenTokens: 0,
          conversationTokens: 0,
          limit: 0,
        ),
      );
    });
    expect(find.text('上下文占用'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- 侧边栏抽屉

  Widget drawer({List<HWorkspace>? workspaces}) => wrap(WorkspaceDrawer(
        workspaces: workspaces ??
            const [
              HWorkspace(
                id: 'w1',
                name: 'proj',
                path: '/storage/emulated/0/proj',
                expanded: true,
                sessions: [HSession(id: 's1', title: '会话一')],
              ),
            ],
        onSelectSession: (workspaceId, sessionId) {},
        onNewSession: (workspaceId) {},
        onOpenSettings: () {},
        viewOptions: const ViewOptions(),
        onViewOptionsChanged: (options) {},
        searchQuery: '',
        onSearchChanged: (query) {},
        onAddWorkspace: () {},
        onAddAppWorkspace: () {},
        onBatchArchiveSessions: (items, archive) {},
        onBatchDeleteSessions: (items) {},
      ));

  testWidgets('侧边栏 ⊕ 菜单：只有一个抓手 + 菜单行是边框动作卡', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester, times: 10);
    await tester.tap(find.byIcon(CupertinoIcons.folder_badge_plus));
    await settle(tester);

    expect(find.text('选择文件夹'), findsOneWidget, reason: '前提：菜单真的开了');
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1, reason: '壳的抓手 + 本地 _bwSheetHandle = 双抓手');
    expect(find.byType(BwActionCard), findsNWidgets(2),
        reason: '两项菜单行都走 BwActionCard');
    expect(tester.takeException(), isNull);
  });

  testWidgets('侧边栏视图选项抽屉：只有一个抓手', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester, times: 10);
    await tester.tap(find.byIcon(CupertinoIcons.slider_horizontal_3));
    await settle(tester, times: 10);

    expect(find.text('分组方式'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(find.byType(BwOptionCard), findsWidgets,
        reason: '视图选项行仍是边框选项卡');
    expect(tester.takeException(), isNull);
  });

  testWidgets('侧边栏会话长按菜单：只有一个抓手 + 4 张动作卡', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester, times: 10);
    await tester.longPress(find.text('会话一'));
    await settle(tester);

    expect(find.text('收藏'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(find.byType(BwActionCard), findsNWidgets(4),
        reason: '收藏 / 重命名 / 归档 / 删除 四行都是 BwActionCard');
    expect(tester.takeException(), isNull);
  });

  testWidgets('侧边栏多选批量菜单：只有一个抓手 + 2 张动作卡', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester, times: 10);
    await tester.tap(find.byIcon(CupertinoIcons.checkmark_square));
    await settle(tester, times: 10);
    await tester.longPress(find.text('会话一'));
    await settle(tester);

    expect(find.text('已选 1 个会话'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget);
    expect(handleCount(tester), 1);
    expect(find.byType(BwActionCard), findsNWidgets(2),
        reason: '归档 / 删除 两行都是 BwActionCard');
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- 消息长按菜单

  testWidgets('消息长按菜单：有抓手 + 两行都换成边框动作卡', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(wrap(MessageRow(
      message: const HUserMessage(id: 'u1', text: '把这句话改一下'),
      onEdit: (text) {},
    )));
    await settle(tester, times: 10);
    await tester.longPress(find.text('把这句话改一下'));
    await settle(tester);

    expect(find.text('复制'), findsOneWidget, reason: '前提：菜单真的开了');
    expect(find.text('编辑重发'), findsOneWidget);
    expect(drawerHandles(), findsOneWidget,
        reason: '消息菜单此前没抓手（裸 showModalBottomSheet 内容）');
    expect(handleCount(tester), 1);
    expect(find.byType(BwActionCard), findsNWidgets(2),
        reason: '复制 / 编辑重发 两行必须迁到 BwActionCard（旧版是裸 InkWell 行）');
    expect(tester.takeException(), isNull);
  });
}
