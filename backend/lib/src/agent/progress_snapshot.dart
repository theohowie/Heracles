// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **进展快照（V0.4，2026-11-02）** —— "连续 N 轮无进展"的判据来源。
//
// ## 为什么要它
//
// 长任务续跑最大的坑不是"停不下来"，而是**停不下来还一直在打转**：模型反复
// 重跑同一个失败测试、反复改同一行、反复读同一个文件 —— 轮数/token 预算都
// 还没到，但**已经没有任何进展**。靠提示词喊"别重复"没用（抗幻觉必须由架构
// 保证），所以必须有**可计算的进展判据**。
//
// ## 三个信号（都只取"拿得到"的，拿不到就留空，绝不编数）
//
// | 信号 | 来源 | 拿不到时 |
// |---|---|---|
// | 文件签名 | 本次 run 的改动文件列表（工具结果里的 diff/path） | 空列表（仍可比"有无变化"） |
// | 测试通过数 | 工具输出里的 pytest / jest / go test / gradle 摘要 | `null`（**不写 0**） |
// | 错误签名 | 失败工具输出里的错误文本归一化后 hash | `null` |
//
// ## 为什么"不编数"是硬要求
//
// 解析不到测试框架输出时，如果按 0 通过/0 总数来算，会把"跑了个不看输出的命令"
// 误判成"测试全挂了" ⇒ 误停任务。宁可不用这个信号，也不能造假。
library;

import 'dart:convert';

/// 一次轮末的进展快照（只增字段；`toJson` 用于写 checkpoint）。
class ProgressSnapshot {
  const ProgressSnapshot({
    required this.filesSignature,
    required this.changedFiles,
    this.testsPassed,
    this.testsTotal,
    this.errorSignature,
  });

  /// 改动文件集合的归一化签名（排序后 join 再 hash）。
  ///
  /// 用**改动文件列表**而不是整棵树 hash：整树 hash 需要遍历工作区（慢且
  /// 可能很大），而"这一轮动了哪些文件"本来就从工具结果里拿得到。
  final String filesSignature;

  /// 改动文件（相对路径，去重、排序）。
  final List<String> changedFiles;

  /// 测试通过数；`null` = 解析不到（**不是 0**）。
  final int? testsPassed;

  /// 测试总数；`null` = 解析不到。
  final int? testsTotal;

  /// 错误签名（失败输出的归一化 hash）；`null` = 本轮没有失败输出/拿不到。
  final String? errorSignature;

  Map<String, Object?> toJson() => {
        'filesSignature': filesSignature,
        'changedFiles': changedFiles,
        'testsPassed': ?testsPassed,
        'testsTotal': ?testsTotal,
        'errorSignature': ?errorSignature,
      };

  static ProgressSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final files = raw['filesSignature'];
    if (files is! String) return null;
    final changed = raw['changedFiles'];
    return ProgressSnapshot(
      filesSignature: files,
      changedFiles: changed is List
          ? [for (final c in changed) if (c is String) c]
          : const <String>[],
      testsPassed: raw['testsPassed'] is num ? (raw['testsPassed'] as num).toInt() : null,
      testsTotal: raw['testsTotal'] is num ? (raw['testsTotal'] as num).toInt() : null,
      errorSignature: raw['errorSignature'] is String ? raw['errorSignature'] as String : null,
    );
  }

  /// **有没有进展**（与上一帧比）。
  ///
  /// 判据（任一成立 = 有进展）：
  /// 1. 改动文件签名变了（动了新文件/改了内容路径）；
  /// 2. 测试通过数上升（或从"解析不到"变成"解析到了"）；
  /// 3. 错误签名变了（错误换了一个 ⇒ 至少动过东西；同一错误重复 = 没进展）。
  ///
  /// 注意：错误签名"从有到无"也算进展（修好了）。
  bool progressedFrom(ProgressSnapshot? prev) {
    if (prev == null) return true; // 第一帧：没得比，算有进展（不误停）
    if (filesSignature != prev.filesSignature) return true;
    final p = testsPassed;
    final pp = prev.testsPassed;
    if (p != null && pp != null && p > pp) return true;
    if (p != null && pp == null) return true;
    final e = errorSignature;
    final pe = prev.errorSignature;
    if (e == null && pe != null) return true; // 错误消失了
    if (e != null && pe == null) return true; // 出现新错误（至少动过）
    if (e != null && pe != null && e != pe) return true;
    return false;
  }
}

/// **从改动文件列表算文件签名**（排序后 hash；空列表也有稳定签名）。
String filesSignatureOf(List<String> changedFiles) {
  final sorted = [for (final f in changedFiles) f.trim()]..sort();
  return _sha1Like(sorted.join('\n'));
}

/// **解析测试通过数**（只认 4 个可解析框架；解析不到返回 null，绝不编数）。
///
/// 覆盖：
/// - pytest：`= 12 passed, 3 failed =` / `12 passed in 0.5s`
/// - jest：`Tests:       2 failed, 10 passed, 12 total`
/// - go test：`ok  pkg  0.1s`（无逐用例数 ⇒ 用 `PASS` 行数）/ `--- FAIL`
/// - gradle：`BUILD SUCCESSFUL` / `Tests: 5 passed`
///
/// 返回 `(passed, total)`；任一解析不到 ⇒ 该字段 null。
({int? passed, int? total})? parseTestCounts(String output) {
  final text = output;

  // gradle: "7 tests passed" / "5 tests passed, 1 failed" —— **先判**，
  // 否则会被下面 pytest 的宽正则（`N passed`）误吞。
  final gradle = RegExp(r'(\d+)\s+tests?\s+passed(?:,\s*(\d+)\s+failed)?')
      .firstMatch(text);
  if (gradle != null) {
    final passed = int.tryParse(gradle.group(1)!);
    final failed = int.tryParse(gradle.group(2) ?? '0') ?? 0;
    if (passed != null) return (passed: passed, total: passed + failed);
  }

  // pytest: 只认带 pytest 特征的形状（`= N passed =` 或 `N passed in Xs`），
  // 避免把 "N tests passed"（gradle）吞掉。
  final pytest = RegExp(r'(\d+)\s+passed(?:,\s*(\d+)\s+failed)?\s*(?:=|in\s+\d)')
      .firstMatch(text);
  if (pytest != null) {
    final passed = int.tryParse(pytest.group(1)!);
    final failed = int.tryParse(pytest.group(2) ?? '0') ?? 0;
    if (passed != null) return (passed: passed, total: passed + failed);
  }

  // jest: "Tests:       2 failed, 10 passed, 12 total"
  final jest = RegExp(r'Tests:\s*(?:(\d+)\s+failed,\s*)?(\d+)\s+passed,\s*(\d+)\s+total')
      .firstMatch(text);
  if (jest != null) {
    return (
      passed: int.tryParse(jest.group(2)!),
      total: int.tryParse(jest.group(3)!),
    );
  }

  // go test: 统计 PASS / FAIL 行（没有逐用例总数时只给 passed，total 留 null）
  final goPass = RegExp(r'^--- PASS:', multiLine: true).allMatches(text).length;
  final goFail = RegExp(r'^--- FAIL:', multiLine: true).allMatches(text).length;
  if (goPass > 0 || goFail > 0) {
    return (passed: goPass, total: goPass + goFail);
  }

  // gradle 分支已提前到函数开头（避免被 pytest 宽正则误吞）。
  return null;
}

/// **错误签名**：失败输出的归一化 hash（同一错误重复出现 ⇒ 同签名）。
///
/// 归一化做三件事（否则同一个错误每次签名都不同，判据失效）：
/// 1. 去掉时间戳/耗时（`0.5s` / `12ms` / ISO 时间）；
/// 2. 去掉绝对路径前缀（工作区路径每轮可能不同）；
/// 3. 折叠连续空白。
String? errorSignatureOf(String? output) {
  if (output == null || output.trim().isEmpty) return null;
  var s = output.toLowerCase();
  s = s.replaceAll(RegExp(r'\d+\.\d+\s*(ms|s|sec|seconds?)'), ' ');
  s = s.replaceAll(RegExp(r'\d{4}-\d{2}-\d{2}[ t]\d{2}:\d{2}:\d{2}[^\s]*'), ' ');
  s = s.replaceAll(RegExp(r'(?:[a-z]:\\|/)[^\s:]+\.(dart|kt|java|py|js|ts|go|rs)'), ' <path>');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 只取前 400 字符：错误正文后半段常是堆栈，归一化意义不大
  final head = s.length > 400 ? s.substring(0, 400) : s;
  return _sha1Like(head);
}

/// 稳定 40 位十六进制摘要（**不是**加密用途，只做"相同/不同"比较）。
///
/// 为什么不用 `Object.hash`：Dart 的 `hashCode` 每次进程启动可能不同
/// （字符串 hash 有随机种子）⇒ 跨进程比较 checkpoint 会失效。
String _sha1Like(String input) {
  // FNV-1a 64bit（确定性、无随机种子），输出 40 位十六进制（padding 到定长）。
  var hash = 0xcbf29ce484222325;
  for (final code in utf8.encode(input)) {
    hash ^= code;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  final a = hash.toRadixString(16).padLeft(16, '0');
  // 再混一次长度与前缀，降低碰撞（非加密）
  var h2 = 0x84222325cbf29ce4;
  for (final code in utf8.encode('${input.length}:$a')) {
    h2 ^= code;
    h2 = (h2 * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  final b = h2.toRadixString(16).padLeft(16, '0');
  final lenHex = (input.length % 256).toRadixString(16).padLeft(2, '0');
  return '$a$b$lenHex'.padRight(40, '0').substring(0, 40);
}
