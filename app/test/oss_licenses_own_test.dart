// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **开源许可页必须包含 Heracles 自己的 GPL-3.0**（2026-11-01 用户指出）：
// 旧页面只列了 48 个第三方依赖，漏了本项目自己的许可证。
// 本文件钉住：
//   a) 数据里有一条 group=self 的 Heracles / GPL-3.0，正文含 GNU GPL v3；
//   b) 页面渲染「Heracles 本体」分组与 Heracles 条目；
//   c) 引言只数第三方（不把本体算进“N 个开源项目”）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/data/open_source_licenses.dart';
import 'package:heracles/screens/oss_licenses_screen.dart';
import 'package:heracles/theme/app_theme.dart';

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

  test('a) Heracles 本体：group=self / GPL-3.0 / 完整 GPL v3 文本', () {
    final own = kOssEntries.firstWhere((e) => e.name == 'Heracles');
    expect(own.group, 'self');
    expect(own.licenseKind, 'GPL-3.0');
    expect(own.licenseText, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(own.licenseText, contains('Version 3, 29 June 2007'));
  });

  testWidgets('b) 页面显示「Heracles 本体」分组与条目', (tester) async {
    await tester.pumpWidget(wrap(const OssLicensesScreen()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Heracles 本体'), findsOneWidget);
    expect(find.text('Heracles'), findsOneWidget);
    // 引言：48 个第三方（本体不计入）
    expect(
      find.textContaining('48 个开源项目'),
      findsOneWidget,
      reason: '本体不是第三方依赖，引言数量不能把 Heracles 自己算进去',
    );
  });
}
