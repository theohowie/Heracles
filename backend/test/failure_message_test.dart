// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **失败文案分类的回归闸（2026-11-04）**。
//
// ## 真机事故（用户 2026-11-04 09:29 截图）
//
// 用户网络明明是好的，却看到「网络连接失败：请检查网络后重试。」
// 真相是 Dio 的 `receiveTimeout`（`The request connection took longer than
// 0:05:00 …`）—— 消息里带 `connection`，被 UI 关键词表一律当网络故障。
// 用户因此被指向一个**不存在**的问题。
//
// `describeFailureMessage` 在**后端**就把种类认清楚，本文件锁住三件事：
//
// 1. 超时**必须**说成超时（带时限），不许说成网络；
// 2. 真正的网络问题（DNS）**必须**仍说成网络（不许把真问题也糊掉）；
// 3. 认不出时**原样给出**（截断），不许编一个"看起来专业"的原因。
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  test('① Dio 接收超时 ⇒ 说成超时并给出时限，不许说成网络', () {
    final text = describeFailureMessage(
      'DioException [connection error]: The request connection took longer '
      'than 0:05:00.000000 and it was aborted. Call with id: xyz',
    );
    expect(text, contains('超时'), reason: '这是本地等太久，不是断网');
    expect(text, contains('0:05:00'), reason: '要把时限给出来，否则没法判断是紧还是松');
    expect(
      text.toLowerCase(),
      isNot(contains('network')),
      reason: '★ 不许出现 network 类关键词 —— UI 会据此误报"检查网络"',
    );
    expect(text.contains('连接失败'), isFalse);
  });

  test('② 对端提前关闭连接 ⇒ 说成"被对端中断"，且不含误导关键词', () {
    final text = describeFailureMessage(
      'DioException [connection error]: Connection closed before full header was received',
    );
    expect(text, contains('对端'));
    expect(text, contains('中断'));
    // 关键：不能带 connection/network 这些英文词，否则 UI 又误判成网络故障
    expect(text.toLowerCase().contains('connection'), isFalse);
    expect(text.toLowerCase().contains('network'), isFalse);
  });

  test('③ DNS 解析失败 ⇒ 仍然要说成网络问题（真问题不许糊掉）', () {
    final text = describeFailureMessage(
      'DioException [connection error]: Failed host lookup: \'bad.host\'',
    );
    expect(text, contains('域名解析'));
    expect(text, contains('网络'));
  });

  test('④ TLS/证书 ⇒ 说成 TLS，不冒充网络故障', () {
    final text = describeFailureMessage(
      'HandshakeException: Handshake error in client (OS Error: '
      'CERTIFICATE_VERIFY_FAILED)',
    );
    expect(text, contains('TLS'));
    expect(text, contains('证书'));
  });

  test('⑤ HTTP 状态码 ⇒ 把码和响应片段给出来', () {
    final text = describeFailureMessage(
      'Failed to generate from OpenAI: 500 Internal Server Error '
      '{"error":{"message":"upstream overloaded"}}',
    );
    expect(text, contains('HTTP 500'));
    expect(text, contains('upstream overloaded'));
  });

  test('⑥ 认不出的错误 ⇒ 原样给出（截断），不许编原因', () {
    const raw = 'Some totally unknown provider failure XYZ';
    expect(describeFailureMessage(raw), contains('XYZ'));

    final long = 'x' * 400;
    final clipped = describeFailureMessage(long);
    expect(clipped.length, lessThanOrEqualTo(201), reason: '兜底要截断，别把整坨 JSON 塞进会话');
    expect(clipped, endsWith('…'));
  });

  test('⑦c 轮次用尽 ≠ 死循环：话术必须分开', () {
    // 框架把两种终止都塞进 loopDetection 异常码；真机上用户看到"完全相同的调用
    // 连续重复"，而实际是 Maximum turns reached(40) —— 完全误导。
    final turns = describeLoopFailure('Maximum turns reached (40). Possible infinite loop.');
    expect(turns, contains('轮次用尽'));
    expect(turns, isNot(contains('完全相同的调用')));

    final real = describeLoopFailure('Tool call loop detected: Same tool called 6 times.');
    expect(real, contains('完全相同的调用'));
    expect(real, isNot(contains('轮次用尽')));
  });
  test('⑦b 余额不足（402）⇒ 说人话 + 给充值地址 + 不许说成网络问题', () {
    final text = describeFailureMessage(
      'Exception: Failed to stream from OpenAI: 402 Payment Required '
      '{"code":"INSUFFICIENT_BALANCE","message":"账户余额不足，请充值后重试。'
      '充值地址：https://tokenrhythm.studio/account/recharge"}',
    );
    expect(text, contains('余额不足'));
    expect(text, contains('402'));
    expect(text, contains('tokenrhythm.studio'));
    expect(text, isNot(contains('网络')));
    expect(text, isNot(contains('超时')));
  });
  test('⑦ 空消息 ⇒ 明说没给原因（不冒充"网络失败"）', () {
    final text = describeFailureMessage('   ');
    expect(text, contains('没有给出失败原因'));
  });
}
