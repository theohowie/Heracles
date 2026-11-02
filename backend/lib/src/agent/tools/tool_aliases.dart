// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **工具别名（V0.4 T1-4，2026-11-02）** —— 名字对齐但不破坏旧名。
//
// ## 为什么需要
//
// 不同模型的工具调用习惯不同：有的爱 `read_file`，有的爱 `Read`；有的写
// `grep_files`，有的写 `Grep`。**只增别名、不删旧名**：旧名继续可用（历史会话
// 里出现过、模型记住过），别名让"另一种写法"也能落到同一个工具上。
//
// ## 纪律
//
// - **别名只增**：不许把某个名字从正式名改成别名（那会破坏旧会话/旧测试）；
// - **未知别名必须报错**，不许"猜一个最像的"（猜错比报错更糟：静默执行错工具）；
// - 别名表是**纯数据**，执行层的转调由宿主/框架决定（本文件只做解析）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

/// 正式工具名 → 允许的别名（**只增**）。
///
/// 键 = 现有正式名（与 `tool_factory` 里 `name:` 逐字一致）；值 = 额外接受的写法。
const Map<String, List<String>> toolAliases = {
  'read_file': ['Read', 'read'],
  'write_file': ['Write', 'write'],
  'edit': ['Edit'],
  'apply_patch': ['ApplyPatch', 'applyPatch'],
  'list_files': ['List', 'ls', 'Glob', 'glob'],
  'find_files': ['Find', 'find'],
  'grep_files': ['Grep', 'grep', 'Search'],
  'run_shell_command': ['Exec', 'exec', 'Bash', 'bash', 'Shell'],
  'web_fetch': ['WebFetch', 'fetch'],
  'web_search': ['WebSearch', 'Search'],
  'save_memory': ['Memory', 'memory_write'],
  'ask_user': ['Ask', 'ask'],
  'notify_user': ['Notify', 'notify'],
};

/// 别名 → 正式名（反向索引，构造一次）。
final Map<String, String> _aliasToCanonical = {
  for (final e in toolAliases.entries)
    for (final a in e.value) a: e.key,
};

/// **把任意写法解析成正式工具名**。
///
/// - 正式名 ⇒ 原样返回；
/// - 已知别名 ⇒ 返回对应正式名；
/// - 未知 ⇒ `null`（**不猜**；调用方应报"未知工具"）。
String? resolveToolName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return null;
  if (toolAliases.containsKey(name)) return name;
  return _aliasToCanonical[name];
}

/// 该写法是否是已知别名（用于"旧名仍可用、别名也算合法"的断言）。
bool isKnownToolName(String raw) => resolveToolName(raw) != null;

/// **为已注册工具生成"别名转调工具"**（V0.4 T1-4，执行层接线）。
///
/// ## 为什么要生成独立 Tool 而不是只做字符串解析
///
/// 框架按 **`Tool.name` 精确匹配**调用 —— 光有解析函数，模型写 `Read` 仍然会
/// 报"未知工具"。所以别名必须作为**独立 Tool 注册**，执行体转调正式工具。
///
/// ## 纪律
///
/// - 只给**已存在**的正式名生成别名（不凭空造工具）；
/// - 别名的 schema/描述**完全复制**正式工具（模型看到的参数说明一致）；
/// - 转调失败（正式工具不存在）⇒ 明确失败，不静默成功。
List<Tool> buildAliasTools(List<Tool> tools) {
  final byName = {for (final t in tools) t.name: t};
  final out = <Tool>[];
  for (final entry in toolAliases.entries) {
    final canonical = byName[entry.key];
    if (canonical == null) continue; // 该环境下没有这个正式工具 ⇒ 不生成
    for (final alias in entry.value) {
      if (byName.containsKey(alias)) continue; // 别名与正式名冲突 ⇒ 跳过（安全）
      out.add(Tool(
        name: alias,
        description: canonical.description,
        parameters: canonical.parameters,
        parameterMode: canonical.parameterMode,
        resultIsError: canonical.resultIsError,
        executable: canonical.executable,
      ));
    }
  }
  return out;
}
