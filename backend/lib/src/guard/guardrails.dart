/// **统一 Guardrails 门面**（SEC5，2026-10-25）。
///
/// ## 这个文件解决什么
///
/// 对照表 SEC5 的欠账："护栏散布各层（shell 禁令/路径沙箱/schema 校验/
/// 审批/预算/SSRF/密钥过滤），但没有统一的入口与清单"。这个类把**输入侧**
/// 的静态校验聚合成一个入口 + 一份自描述清单 —— 调用方（宿主/CLI/测试）
/// 一处可见全部防线；各护栏的执行位置不变（它们必须在正确的层：沙箱在
/// 能力层、审批在 hook、禁令在工具层 —— 聚合的是**可见性与入口**，
/// 不是把逻辑搬过来）。
///
/// ## 输入侧 vs 输出侧
///
/// - **输入侧**（本类）：模型产出的工具调用参数在执行前的静态校验。
/// - **输出侧**：SEC1 包裹（web/read/shell 三路）、resultIsError 假信息
///   防线 —— 在工具层已实施，此处只登记不重复。
///
/// ## 红队入口
///
/// `test/red_team_test.dart` 逐条打这些层 —— 那是本清单的活性证明。
library;

import '../agent/tools/shell_tools.dart' show checkCommandSafety;
import '../tools/tool_factory.dart' show EditReadTracker;

/// 输入侧静态校验的统一入口。
///
/// 每个方法对应一条独立防线，返回拒绝原因（`null` = 放行）。
/// **只做静态判定**：不联网、不问用户、不碰文件系统。
abstract final class Guardrails {
  /// ① shell 硬禁令：kill/force-stop/pm disable 等产品铁律
  /// （执行层在 `shell_tools.dart`，红队攻击 1）。
  static String? commandSafety(String command) => checkCommandSafety(command);

  /// ② 疑似密钥/令牌（记忆写入的 SEC4 双闸之一；同源正则在 App
  /// `GlobalMemory` 也有一份）。
  static final RegExp secretPattern = RegExp(
      r'(sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}'
      r'|gho_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{15,}|[A-Fa-f0-9]{32,})');

  static bool looksLikeSecret(String text) => secretPattern.hasMatch(text);

  /// ③ 路径沙箱（工作区相对路径、拒 `..`/绝对路径）—— 执行层在
  /// `LocalWorkspaceCapability._resolve`（红队攻击 2）。
  ///
  /// 静态预判版：明显的越界姿势在发起调用前就能看出来（供 UI 预检）。
  static String? pathLooksOutside(String path) {
    final p = path.replaceAll('\\', '/');
    if (p.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(p)) {
      return '绝对路径不被接受（工作区相对路径 only）：$path';
    }
    // 深度对齐判定交给能力层（它能 resolve 符号链接）—— 这里只挡
    // 文本上就带 ../ 的显式穿越
    if (p.split('/').contains('..')) {
      return '路径包含 .. （显式穿越姿势）：$path';
    }
    return null;
  }

  /// ④ "先读再改"准入（K1）—— 执行层在文件工具 + [EditReadTracker]。
  /// 此处静态版：该路径是否已被记账。
  static String? editWithoutRead(String path, EditReadTracker tracker) =>
      tracker.canEdit(path)
          ? null
          : '该文件还没被读过（先 read_file 再改）';

  /// 全部防线的自描述清单（文档 + 审计用；与上面方法一一对应）。
  static const List<(String, String, String)> layers = [
    (
      'shell 硬禁令',
      '工具层（shell_tools）',
      'kill/force-stop/pm disable 拒绝 —— 产品铁律，不许杀用户应用'
    ),
    (
      '路径沙箱',
      '能力层（LocalWorkspaceCapability）',
      '绝对路径拒绝、.. 越界检查、软链 resolve 后二次比对'
    ),
    (
      'schema 校验',
      '工具工厂（_validateAgainstSchema）',
      '未知字段/类型/范围三层，执行前拦截'
    ),
    (
      '审批门禁',
      'hook（_ApprovalHook）',
      '三档审批 + fail-closed（无 UI 即拒绝）'
    ),
    (
      '预算护栏',
      'hook（_ToolBudgetHook）',
      '调用上限熔断 + 75%/90% 预警'
    ),
    (
      'SSRF 闸',
      '能力层（DeviceWebCapability）',
      'scheme 白名单/凭据 URL/内网与元数据 IP 段'
    ),
    (
      '密钥过滤',
      '工具（save_memory）+ App（GlobalMemory）',
      '疑似密钥/令牌拒收（双闸）'
    ),
    (
      '先读再改',
      '工具（EditReadTracker）',
      'edit/apply_patch/已存在文件覆盖须先读'
    ),
    (
      '输出包裹（SEC1）',
      '工具层（web/read/shell）',
      '外部内容起止标记 + 夹带指令处理规则'
    ),
    (
      '假信息防线',
      '工具工厂（resultIsError）',
      '失败必被框架认成失败（不画绿色成功卡）'
    ),
  ];
}
