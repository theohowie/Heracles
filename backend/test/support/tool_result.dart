// Copyright (C) 2026 The Heracles Authors
//
// 测试辅助：从工具返回值里取出「给模型看的那段文本」。
//
// ============================================================================
// 为什么需要它（2026-10-29）
// ============================================================================
// 工具现在返回 `AgentToolResult`（而不是纯 `String`），目的是让
// `CapabilitySuccess.metadata`（执行面 / 退出码 / 耗时 / 截断）能顺着框架
// 流到 UI —— 框架只认 `AgentToolResult.metadata`。
//
// **模型看到的文本一个字都没变**，所以既有测试的断言内容不需要改，
// 只需要在「调用点」把结果转成文本再断言。
//
// 用法：
// ```dart
// final r = textOf(await tool.executable!(args));
// expect(r, contains('...'));
// ```
//
// ⚠️ 不要为了省事把断言改成 `result.toString()` —— `AgentToolResult` 的
// `toString()` 是对象摘要（`Instance of 'AgentToolResult'`），那样断言会变成
// 永远不可能命中的空跑。

import 'package:dart_agent_core/dart_agent_core.dart';

/// 取出工具结果里给模型看的文本；非 `AgentToolResult` 原样 `toString()`。
String textOf(dynamic result) {
  if (result is AgentToolResult) {
    final parts = result.contents ??
        (result.content == null
            ? const <UserContentPart>[]
            : <UserContentPart>[result.content!]);
    return parts.map((p) => p is TextPart ? p.text : p.toString()).join('\n');
  }
  return result.toString();
}

/// 取工具结果的结构化元数据（UI 用的执行面 / 退出码 / 耗时 / 截断）。
Map<String, dynamic>? metadataOf(dynamic result) =>
    result is AgentToolResult ? result.metadata : null;
