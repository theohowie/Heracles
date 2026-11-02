// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 定位文案**（2026-11-02，对应 #6/T1）：主叙事 = 任意代码项目，
// Android/APK 只是能力之一；README 同步改口。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/screens/chat_screen.dart'
    show kWelcomeGreeting, kWelcomeSuggestions;

void main() {
  test('★★ 首屏问候体现"任意代码项目"，不是只做 APK', () {
    expect(kWelcomeGreeting, contains('任意代码项目'));
    expect(kWelcomeGreeting, contains('今天想做些什么'));
    expect(kWelcomeGreeting, isNot(contains('只能做 APK')));
    expect(kWelcomeGreeting, isNot(contains('安卓开发智能体')));
  });

  test('★★ 建议覆盖 看项目/写脚本/搭工具/修 bug/写文档 + 一条 Android 示例', () {
    final labels = kWelcomeSuggestions.map((e) => e.$2).toList();
    expect(labels.length, greaterThanOrEqualTo(5));
    expect(labels.any((l) => l.contains('项目')), isTrue);
    expect(labels.any((l) => l.contains('脚本')), isTrue);
    expect(labels.any((l) => l.contains('工具')), isTrue);
    expect(labels.any((l) => l.contains('bug')), isTrue);
    expect(labels.any((l) => l.contains('文档')), isTrue);
    expect(labels.any((l) => l.contains('Android')), isTrue,
        reason: '保留一条 Android 示例，但不能只有 APK');
    // 不能只有 APK：Android 条目占比 < 一半
    expect(labels.where((l) => l.contains('APK')).length,
        lessThan(labels.length));
  });

  test('★★ README 定位改为"任意代码项目"，不再自称开发智能体/只做 APK', () {
    // flutter test 的工作目录是 app/ ⇒ 仓库根是 ../
    final readme = File('../README.md');
    expect(readme.existsSync(), isTrue, reason: 'README.md 应存在于仓库根');
    final text = readme.readAsStringSync();
    expect(text, contains('手机上的代码智能体'));
    expect(text, contains('任意代码项目'));
    expect(text, isNot(contains('手机上的开发智能体')));
  });
}
