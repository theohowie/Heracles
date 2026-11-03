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
///
/// ## ★ 别名值必须**全局唯一**（2026-11-03 真机 400 修）
///
/// 违反这条有两个后果：
///
/// 1. **请求直接 400**：`buildAliasTools` 给每个正式工具生成独立别名 Tool，
///    `openai_client` 又把每个 `Tool` 一对一写进 `body.tools` —— 两个正式工具
///    共用同一别名 ⇒ 两个同名 `function.name` ⇒ 网关回
///    `Tool names must be unique`，整轮任务什么都没做就失败；
/// 2. **解析指错工具**：`_aliasToCanonical` 是 map 字面量，同名别名后者覆盖前者
///    ⇒ 模型写那个别名时落到哪个工具取决于表里的书写顺序。
///
/// 实测踩过：`grep_files` 与 `web_search` 都写过 `Search`。
/// 回归闸见 `test/tool_alias_uniqueness_test.dart`。
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
  // ★ `Search` 曾经也列在这里，与 `grep_files` 撞名 ⇒ 请求 400
  //   （见上方「别名值必须全局唯一」）。搜索类意图统一给 `grep_files`：
  //   联网搜索有自己的正式名 `web_search`，模型本来就直接写它。
  'web_search': ['WebSearch'],
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
/// - 转调失败（正式工具不存在）⇒ 明确失败，不静默成功；
/// - ★ **输出里绝不出现重名**：数据表已保证别名值全局唯一（见 [toolAliases]），
///   这里再兜一层 —— 万一将来表写错，也只保留**第一个**所有者，
///   不把同名工具交给模型（那会让整轮请求 400，比"少一个别名"严重得多）。
List<Tool> buildAliasTools(List<Tool> tools) {
  final byName = {for (final t in tools) t.name: t};
  // ★ 已占用的名字：正式名 + 已生成的别名。别名之间撞名时后来者跳过。
  final taken = <String>{...byName.keys};
  final out = <Tool>[];
  for (final entry in toolAliases.entries) {
    final canonical = byName[entry.key];
    if (canonical == null) continue; // 该环境下没有这个正式工具 ⇒ 不生成
    for (final alias in entry.value) {
      if (!taken.add(alias)) continue; // 与正式名/别的别名冲突 ⇒ 跳过（安全）
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
