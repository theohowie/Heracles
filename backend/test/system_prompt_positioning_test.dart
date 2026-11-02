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

  // ★ 2026-11-02 用户裁定：产品目的不是构建 APK、不是安卓专属功能。
  //   沙箱是主战场和工作台；宿主 shell 只负责交付产物与力所能及的查询。
  //   ⚠️ 基线提示词本次是**有意的破坏性变更**（不再与旧版逐字节一致）。
  test('⑤ 沙箱优先：主战场关键句逐字在（有沙箱的宿主）', () {
    final p = defaultSystemPrompt(_sandboxCaps());
    expect(p, contains('主战场'), reason: '必须告诉模型工作台在哪');
    expect(p, contains('默认在沙箱里完成'));
    expect(p, contains('自己写脚本'), reason: '缺工具不许放弃，要自写脚本');
    expect(p, contains('把沙箱产物交付给用户'), reason: '宿主 shell 的第一职责');
    expect(p, contains('力所能及的系统查询'), reason: '宿主 shell 的第二职责');
    expect(p, contains('能不用则不用'), reason: '宿主 shell 能少用就少用');
    expect(p, contains('apk add'), reason: '缺工具先在沙箱里装');
  });

  test('⑥ APK 是能力之一：仅用户明确要 APK 才走那条路，中心表述不许回来', () {
    final p = defaultSystemPrompt(_sandboxCaps());
    expect(p, contains('仅在用户明确要 APK'), reason: '边界必须写死');
    // ★ APK 中心表述（旧定位的残余）不许回来
    expect(p.contains('默认构建 APK'), isFalse);
    expect(p.contains('以构建 APK 为主'), isFalse);
    expect(p.contains('核心能力是构建'), isFalse);
  });

  test('⑦ 缺工具链的指引 = 装或自写脚本，不许"放弃任务"（两种宿主都在）', () {
    // 定位段是无条件渲染的 —— 两种宿主都必须看到这条指引
    expect(defaultSystemPrompt(_caps()),
        contains('不要因为"没有现成工具"就放弃'));
    expect(defaultSystemPrompt(_sandboxCaps()),
        contains('不要因为"没有现成工具"就放弃'));
  });

  test('⑧ ★★★ 没接沙箱的宿主 ⇒ 短版如实，不许说"默认在沙箱里完成"', () {
    // 说反话 = P1-③ 的老病根：宿主没有沙箱却承诺沙箱优先，
    // 模型会照做然后撞墙。缺位时必须给如实的短版。
    final p = defaultSystemPrompt(_caps());
    expect(p, contains('没有沙箱执行面'));
    expect(p.contains('默认在沙箱里完成'), isFalse,
        reason: '没有沙箱的宿主不许承诺沙箱执行');
    expect(p.contains('主战场'), isFalse);
  });
}

/// 有沙箱的宿主（App 生产形态：文件工具 + 沙箱 + 手机 shell）。
Capabilities _sandboxCaps() => Capabilities(sandbox: _FakeSandbox());

class _FakeSandbox implements SandboxCapability {
  @override
  Future<bool> isReady() async => true;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async =>
      const CapabilitySuccess('ok');

  @override
  Future<CapabilityResult> reset({String snapshot = ''}) async =>
      const CapabilitySuccess('ok');
}
