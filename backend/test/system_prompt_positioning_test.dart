// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **系统提示的定位段（V0.4 T1-6）**：任意代码项目 / 项目类型提示 / 不编造。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | 提示词写明"能完成任意代码项目" + "APK 只是能力之一" | 定位退回"只能构建 APK" |
// | ② | 传 ProjectDetection ⇒ 渲染类型 + 建议命令 | 模型看不到项目类型（默认按 Android 猜） |
// | ③ | 未知项目 ⇒ 明确"未识别/不要猜" | 编造构建命令 |
// | ④ | 不传 project ⇒ 不渲染该段（首帧字节不变） | 前缀变化破坏缓存 |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

Capabilities _caps() => Capabilities();

void main() {
  test('① 定位：任意代码项目 + APK 只是能力之一', () {
    final p = defaultSystemPrompt(_caps());
    expect(p, contains('能完成任意代码项目'));
    expect(p, contains('APK 只是能力之一'));
    // 旧定位句不能还在（"一个运行在 Android 手机上的开发智能体。" 单句版）
    expect(p.contains('开发智能体。\n\n## 语言'), isFalse);
  });

  test('② 传识别结果 ⇒ 类型 + 建议命令', () {
    final p = defaultSystemPrompt(
      _caps(),
      project: detectProject(['pyproject.toml']),
    );
    expect(p, contains('当前工作区项目类型：**Python**'));
    expect(p, contains('pyproject.toml'));
    expect(p, contains('pytest'));
  });

  test('③ 未知项目 ⇒ 明确未识别、不猜命令', () {
    final p = defaultSystemPrompt(
      _caps(),
      project: detectProject(['README.md']),
    );
    expect(p, contains('未识别'));
    // ★ 断言要锚定**项目段**，不能搜全文：定位段的示例里本来就有 `npm test` 字样
    //   （"按项目生态选，如 npm test / pytest …"）——搜全文会误判（测错对象）。
    expect(p, contains('未识别出构建命令'));
    expect(p, contains('不要猜一个去跑'));
  });

  test('④ 不传 project ⇒ 无项目段（首帧前缀不变）', () {
    final p = defaultSystemPrompt(_caps());
    expect(p.contains('当前工作区项目类型'), isFalse);
  });
}
