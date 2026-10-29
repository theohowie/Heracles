import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/attachment.dart';
import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart' show attachmentsFromRow;
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/bw_topbar.dart';
import 'package:heracles/widgets/image_viewer.dart';
import 'package:heracles/widgets/message_row.dart';

import 'support/secure_storage_mock.dart';

/// 2026-10-29 用户六图批次的回归钉：
/// 灵动岛收起加长、已发送图片成图+看大图、上下文单一口径、
/// 设置主页分组卡片、停止回复的操作行（bare 提示不带）。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  group('上下文窗口单一口径 effectiveContextWindow', () {
    ModelProviderConfig cfg({
      String model = 'm1',
      int contextLength = 0,
      Map<String, ModelCapability> caps = const {},
    }) =>
        ModelProviderConfig(
          id: 'p1',
          name: '测试',
          baseUrl: 'https://example.com/v1',
          model: model,
          contextLength: contextLength,
          modelCapabilities: caps,
        );

    test('逐模型能力优先于 provider 单值', () {
      final p = cfg(
        contextLength: 128000,
        caps: const {
          'm1': ModelCapability(contextWindow: 1000000),
        },
      );
      expect(p.effectiveContextWindow, 1000000);
    });

    test('没有逐模型能力时用 provider 单值', () {
      expect(cfg(contextLength: 262144).effectiveContextWindow, 262144);
    });

    test('都没有 → 0（未知，不自创兜底）', () {
      expect(cfg().effectiveContextWindow, 0);
      expect(
        cfg(caps: const {'other': ModelCapability(contextWindow: 999)})
            .effectiveContextWindow,
        0,
      );
    });
  });

  group('会话记录附件解析 attachmentsFromRow', () {
    test('正常行解析，kind 按记录值', () {
      final out = attachmentsFromRow([
        {'path': '/a/b.png', 'name': 'b.png', 'kind': 'image'},
        {'path': '/a/c.pdf', 'name': 'c.pdf', 'kind': 'binary'},
      ], 'm1');
      expect(out.length, 2);
      expect(out[0].isImage, isTrue);
      expect(out[1].kind, AttachmentKind.binary);
    });

    test('坏行跳过、缺 kind 按扩展名推断、缺 name 用文件名', () {
      final out = attachmentsFromRow([
        'junk',
        {'name': 'no-path.jpg'},
        {'path': '/x/y.jpg'},
        {'path': '/x/z.txt', 'kind': 'nonsense'},
      ], 'm2');
      expect(out.length, 2);
      expect(out[0].name, 'y.jpg');
      expect(out[0].kind, AttachmentKind.image);
      expect(out[1].kind, AttachmentKind.text);
    });

    test('非列表 → 空', () {
      expect(attachmentsFromRow(null, 'm3'), isEmpty);
      expect(attachmentsFromRow('attach-string', 'm3'), isEmpty);
    });
  });

  testWidgets('灵动岛收起胶囊有最小宽度（不再短短一截）', (tester) async {
    await tester.pumpWidget(wrap(const Center(
      child: DynamicIsland(
        steps: ['一', '二'],
        doneCount: 2,
        activeIndex: 1,
        collapsed: true,
        onToggle: _noop,
      ),
    )));
    await tester.pump(const Duration(milliseconds: 600));
    final size = tester.getSize(find.byType(DynamicIsland));
    expect(size.width, greaterThanOrEqualTo(168));
  });

  group('已发送图片渲染', () {
    late Directory tmp;
    late File img;

    setUp(() {
      // 同步 IO：testWidgets 的 fake-async 区里 await 真实文件
      // IO 不可靠（写盘可能永不完成 → 后续 existsSync 恒 false，
      // 看图页走「文件不存在」分支）—— 同步写没有这个坑。
      tmp = Directory.systemTemp.createTempSync('att_test');
      img = File('${tmp.path}/shot.png');
      // 1×1 透明 PNG
      img.writeAsBytesSync(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    testWidgets('图片附件渲染成图、不再是 📎 文件名；图上挂着看图点按',
        (tester) async {
      final msg = HUserMessage(
        id: 'u1',
        text: '看看这张图',
        attachments: [
          HAttachment(
            id: 'a1',
            name: 'shot.png',
            path: img.path,
            kind: AttachmentKind.image,
          ),
        ],
      );
      await tester.pumpWidget(wrap(ListView(children: [MessageRow(message: msg)])));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsWidgets);
      expect(find.textContaining('📎'), findsNothing);
      // 图片外层必须挂着 onTap（点开看大图）—— 点按手势的派发
      // 在真机验证；此处钉住接线本身不丢。
      final gd = tester.widget<GestureDetector>(find.ancestor(
        of: find.byType(Image).first,
        matching: find.byType(GestureDetector),
      ).first);
      expect(gd.onTap, isNotNull);
    });

    testWidgets('看图页：打开有缩放层与关闭钮，点关闭退出', (tester) async {
      await tester.pumpWidget(wrap(Builder(
        builder: (ctx) => Center(
          child: GestureDetector(
            onTap: () => showImageViewer(ctx, img.path, name: 'shot.png'),
            child: const Text('open'),
          ),
        ),
      )));
      // 注：这里直接调用回调而不是 tester.tap —— 本次排查确认
      // 功能无恙，坑在测试推进方式（单次大步 pump 不挂载路由
      // 转场，见下方逐帧推进）；气泡侧的点按接线由上一条用例
      // 的 onTap 断言钉住，真机点按为最终验证面。
      tester
          .widget<GestureDetector>(find.ancestor(
            of: find.text('open'),
            matching: find.byType(GestureDetector),
          ).first)
          .onTap!();
      // 逐帧推进（本机单次大步 pump 不处理路由转场挂载 ——
      // 与 bw 测试的 settle 助手同一教训）
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byIcon(AppIcons.close), findsOneWidget);
      await tester.tap(find.byIcon(AppIcons.close));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('纯附件（无文字）也能渲染', (tester) async {
      final msg = HUserMessage(
        id: 'u2',
        text: '',
        attachments: [
          HAttachment(
            id: 'a2',
            name: 'shot.png',
            path: img.path,
            kind: AttachmentKind.image,
          ),
        ],
      );
      await tester.pumpWidget(wrap(ListView(children: [MessageRow(message: msg)])));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('助手消息操作行', () {
    testWidgets('正常回答带复制按钮', (tester) async {
      const msg = HAssistantMessage(id: 'a1', text: '回答正文');
      await tester.pumpWidget(wrap(ListView(children: const [MessageRow(message: msg)])));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(AppIcons.copy), findsOneWidget);
    });

    testWidgets('bare 系统提示（已停止）不带操作行', (tester) async {
      const msg = HAssistantMessage(
        id: 'a2',
        text: '已停止。你可以继续发消息。',
        bare: true,
      );
      await tester.pumpWidget(wrap(ListView(children: const [MessageRow(message: msg)])));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已停止。你可以继续发消息。'), findsOneWidget);
      expect(find.byIcon(AppIcons.copy), findsNothing);
      expect(find.byIcon(AppIcons.thumbUpOutline), findsNothing);
    });
  });

  testWidgets('设置主页：一组一卡（3 个分组卡）+ 全部入口在', (tester) async {
    //  tall 画布让 ListView 一次建满全部条目（否则折叠线以下懒建不到）
    await tester.binding.setSurfaceSize(const Size(390, 1750));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installSecureStorageMock();
    SharedPreferences.setMockInitialValues({});
    final controller = await SettingsController.load();
    await tester.pumpWidget(MaterialApp(
      theme: buildHeraclesTheme(),
      builder: (context, inner) => HueScope(
        hue: Hue.darkHue,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: SettingsScreen(
        controller: controller,
        archivedCountLoader: () => 2,
        onOpenArchived: () async {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    for (final t in [
      '通用设置',
      '全局记忆',
      '设备权限',
      '语音识别',
      '已归档对话',
      '模型',
      '外观',
      '关于 Heracles',
      '开源许可',
    ]) {
      expect(find.text(t), findsOneWidget, reason: '入口缺失：$t');
    }
    // 分组卡 = 带 xl 圆角装饰的 Container，恰好 3 张（通用/智能体/应用）
    final cards = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      return d is BoxDecoration &&
          d.borderRadius == BorderRadius.circular(HRadius.xl);
    });
    expect(cards, findsNWidgets(3));
  });
}

void _noop() {}
