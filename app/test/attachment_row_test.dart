import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/attachment.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/input_bar.dart';

/// **附件展示回归**（2026-10-25 晚，用户给参考图定）：
///
/// · 图片附件 ⇒ 方形缩略图本体，右上角圆形 × 可删
/// · 文件附件 ⇒ 方形 tile（扩展名徽标 + 文件名），右上角圆形 × 可删
///   （2026-10-26 随 TRAE 式输入区改版，文件不再显大小）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late File png;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('attach_test');
    png = File('${dir.path}/shot.png');
    // 1×1 透明 PNG
    await png.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(dark: false),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(false, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home:
            Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
      );

  testWidgets('图片附件显示缩略图，点 × 回调删除', (tester) async {
    String? removed;
    await tester.pumpWidget(wrap(InputBar(
      onSend: (_) {},
      attachments: [
        HAttachment(
          id: 'img1',
          name: 'shot.png',
          path: png.path,
          kind: AttachmentKind.image,
          sizeBytes: 68,
        ),
      ],
      onRemoveAttachment: (id) => removed = id,
    )));
    // 等图片真从磁盘解码完（测试时钟下 IO 是真实异步）——
    // 没加载完时缩略图宽度为 0，右上角的 × 不在可点位置
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget,
        reason: '图片附件应渲染成缩略图本体，而不是文件名 chip');
    expect(find.byIcon(AppIcons.close), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.close));
    expect(removed, 'img1');
  });

  testWidgets('文件附件显示方形 tile（徽标 + 名），点 × 回调删除', (tester) async {
    String? removed;
    await tester.pumpWidget(wrap(InputBar(
      onSend: (_) {},
      attachments: const [
        HAttachment(
          id: 'f1',
          name: '智能体开发对照表.md',
          path: '/x/智能体开发对照表.md',
          kind: AttachmentKind.text,
          sizeBytes: 28672,
        ),
      ],
      onRemoveAttachment: (id) => removed = id,
    )));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('智能体开发对照表.md'), findsOneWidget);
    expect(find.text('MD'), findsOneWidget,
        reason: '文件 tile 顶部应有扩展名徽标');
    expect(find.text('28KB'), findsNothing,
        reason: 'tile 形态不显文件大小（向参考图看齐）');
    expect(find.byType(Image), findsNothing,
        reason: '文件附件不渲染图片缩略图');
    await tester.tap(find.byIcon(AppIcons.close));
    expect(removed, 'f1');
  });
}
