import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/widgets/brand_icons.dart';

/// **token 计数格式 + 品牌图标回归测试**（2026-10-27）。
///
/// 用户定的口径：≤1000 原样、>1000 用 K、>100 万用 M，
/// 一位小数、整数不带 .0。用量面板（message_row）用它显示本轮用量。
/// 品牌图标：Octocat 与 git-branch 象形图标必须能正常渲染
///（输入条「连接 Github / 选择分支」在用）。
void main() {
  group('formatTokenCount', () {
    test('1000 及以下原样', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(290), '290');
      expect(formatTokenCount(1000), '1000');
    });

    test('超过 1000 用 K', () {
      expect(formatTokenCount(1001), '1K');
      expect(formatTokenCount(1200), '1.2K');
      expect(formatTokenCount(48500), '48.5K');
      expect(formatTokenCount(1000000), '1000K');
    });

    test('超过 100 万用 M', () {
      expect(formatTokenCount(1000001), '1M');
      expect(formatTokenCount(1500000), '1.5M');
      expect(formatTokenCount(2340000), '2.3M');
    });
  });

  group('品牌图标渲染', () {
    testWidgets('GitHub 猫与 git-branch 图标无异常渲染', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              GitHubIcon(size: 15, color: Colors.black),
              GitBranchIcon(size: 15, color: Colors.black),
            ],
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(GitHubIcon), findsOneWidget);
      expect(find.byType(GitBranchIcon), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
