// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **token 数量的输入解析（2026-11-05 用户要求）**。
//
// ## 用户口径（原话）
//
// 「k 和 m 都是单位，大写的也算，如果没有单位，那就是数字，32 就是 32，1 就是 1；
//   **1k 和 1K 一样**，但和 1 不一样；**1m 和 1M 一样**，但和 1k / 1 / 1K 不一样。
//   用户自行输入单位。」
//
// ## 换算（1K = 1024，与全部主流工具、操作系统、模型上下文口径一致）
//
// | 输入 | 结果 |
// |---|---|
// | `1` `32` `1000000` | 原样（**没有单位就是纯数字**） |
// | `1k` `1K` `1 k` | 1024 |
// | `128k` `128K` | 131072 |
// | `1m` `1M` | 1048576 |
// | `32K` | 32768 |
// | `1.5M` | 1572864（小数允许） |
//
// ⚠️ 为什么 1K = 1024 而不是 1000：上下文窗口/输出上限是**二进制量级**的
// 工程值（模型越界判断按 2 的幂做），用 1000 会在 128K→131072 这种常见值上
// 差 7%，把"刚好够"变成"越界"。这与厂商面板显示的 1M=1048576 一致。
//
// ⚠️ 不做"猜单位"：空串/非法 ⇒ 返回 `null`（调用方保持"未设置"，**不猜**）。
library;

/// 把用户输入解析成 token 数量。
///
/// 返回 `null` = 空 / 非法 / 负数（调用方不得把它当成 0 处理 —— 0 有语义：
/// "未设置，用默认值"；非法输入应当是"我没看懂"）。
int? parseTokenCount(String raw) {
  final s = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty) return null;

  // 允许结尾的 "token"/"tokens" 写法（用户可能照抄面板）
  var body = s.replaceAll(RegExp(r'tokens?$'), '');
  if (body.isEmpty) return null;

  var multiplier = 1;
  final last = body[body.length - 1];
  if (last == 'k') {
    multiplier = 1024;
    body = body.substring(0, body.length - 1);
  } else if (last == 'm') {
    multiplier = 1024 * 1024;
    body = body.substring(0, body.length - 1);
  }

  final n = double.tryParse(body);
  if (n == null || n.isNaN || n.isInfinite || n < 0) return null;

  final v = (n * multiplier).round();
  return v < 0 ? null : v;
}

/// 把 token 数**还原成带单位的展示**（输入框占位、只读展示用）。
///
/// 规则与 [parseTokenCount] 对称：能被 1M 整除就用 `M`，能被 1K 整除就用 `K`，
/// 否则给纯数字 —— 这样"1.5M"这类值不会退化成 1572864 让人看不懂。
String formatTokenCount(int tokens) {
  if (tokens <= 0) return '';
  if (tokens % (1024 * 1024) == 0) return '${tokens ~/ (1024 * 1024)}M';
  if (tokens % 1024 == 0) return '${tokens ~/ 1024}K';
  return '$tokens';
}
