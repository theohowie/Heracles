/// Heracles 后端 —— 基于 `dart_agent_core` 的云端 Agent 编排层。
///
/// ## 设计原则：**能用框架的就用框架**
///
/// 自己实现的只有四样，其余全部复用 `dart_agent_core`：
///
/// | 自己写 | 为什么 | 框架对应物 |
/// |---|---|---|
/// | `capability/` | 框架不知道 Android 存储 / APK 构建 | 无（框架不碰设备） |
/// | `tools/` + `agent/tools/` | 工具的业务语义 | `Tool` 类（框架提供壳） |
/// | `context/deterministic_json.dart` | 框架的 JSON 不保证字节稳定 | 无（框架不管缓存） |
/// | `context/window_ratio_compressor.dart` | 触发阈值要按模型窗口自适应 | `ContextCompressor` 接口 |
/// | `prompt/system_prompt.dart` | 产品特定提示词 | `systemPrompts` 参数 |
/// | `agent/heracles_agent.dart` | 组装 + 事件翻译 | `StatefulAgent` / `AgentController` |
///
/// **框架提供、绝不重复实现的**：
/// - agent 循环（`StatefulAgent`）
/// - 事件总线（`AgentController` + `StreamingEvent`）
/// - 计划（`PlanMode` + `write_todos` + `PlanState`）
/// - 循环检测（`DefaultLoopDetector`）
/// - 摘要执行（`LLMBasedContextCompressor`）
/// - 多 provider（`OpenAIClient` / `ClaudeClient` / `ResponsesClient`）
/// - 状态持久化（`FileStateStorage`）
/// - hooks（10 阶段 `AgentHook`）
/// - 子代理（`SubAgent`）
/// - Skills、MCP、取消（`CancelToken`）
///
/// ## 硬约束
///
/// 1. **不 import `package:flutter/*`** —— 后端不该知道 UI 存在
/// 2. **不 import `dart:ui`** —— 同上
/// 3. **确定性优先**：进 prompt 的字符串必须字节稳定
library;

export 'src/agent/heracles_agent.dart';
// 会话历史 → 框架消息（2026-10-23）。宿主读会话文件后交给 `run(history:)`。
export 'src/agent/session_history.dart';
// 多模态输入边界类型（2026-10-23）。宿主演把图片压成 base64，框架类型不出 backend。
export 'src/agent/multimodal.dart';
export 'src/capability/capabilities.dart';
export 'src/context/deterministic_json.dart';
export 'src/context/window_ratio_compressor.dart';
export 'src/prompt/system_prompt.dart';
// 内置技能（S1/S2/S3 的 Skill 层，2026-10-24）。宿主开 RunOptions.enableSkills 后进目录。
export 'src/prompt/builtin_skills.dart';
export 'src/agent/tools/apk_tools.dart';
export 'src/agent/tools/file_manage_tools.dart';
export 'src/agent/tools/file_tools.dart';
export 'src/agent/tools/info_tools.dart';
export 'src/agent/tools/interaction_tools.dart';
export 'src/agent/tools/shell_tools.dart';
export 'src/tools/tool_factory.dart';

// ★ 契约常量（2026-10-22 补）：宿主（Flutter app）需要引用同一批数字。
//
// 为什么必须导出：`Contract*` 是**魔法数字的唯一来源**。宿主若自己写一份
// 镜像（例如 `read` 的行号宽度 `5`），就产生了第二份真相 —— 一边改了另一边
// 不会跟进，而且不会有任何编译错误提醒。App 侧的 `DeviceWorkspaceCapability`
// 正是需要 `ContractWorkspace.lineNumberWidth` 来对齐行号前缀的。
export 'src/contract/contract.dart';

