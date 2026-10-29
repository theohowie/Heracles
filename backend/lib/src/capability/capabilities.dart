/// **能力层抽象** —— 后端需要的所有"设备/系统能力"都在这里声明。
///
/// ## 为什么必须有这一层
///
/// 后端是**纯 Dart 包**（不 import Flutter，也不 import android）。它要在手机上
/// 干活，就必须调用一些 Dart 自己做不到的事：
///
/// | 能力 | Dart 能做吗 | 谁提供 |
/// |---|---|---|
/// | 读写工作区文件 | ⚠️ `dart:io` 能读普通路径，**读不了 SAF** | Android 桥 |
/// | 执行 shell 命令 | ⚠️ `Process.run` 有，但拿到的是 app 的 UID 权限 | Android 桥 |
/// | 构建 APK（aapt2/d8/apksigner） | ❌ | Android 桥 |
/// | 读电池/温度 | ❌ | Android 桥 |
/// | HTTP 请求（模型 API） | ✅ `dio` 直接做 | 本包自己做 |
///
/// ## 设计约束
///
/// 1. **接口在这里，实现不在**：本包只声明 `abstract class`，实现由宿主
///    （Flutter app 的 MethodChannel，或 CLI 的本地实现）注入。
/// 2. **每个方法都要能失败**：设备能力经常失败（权限、温度熔断、文件不存在）。
///    统一用 [CapabilityResult] 表达，**不抛异常给 agent 循环** ——
///    异常会让模型看到堆栈，它读不懂；失败要变成它读得懂的一句人话。
/// 3. **不做类型强转**：工具的 `Map<String, dynamic>` 原样传进来，
///    由实现自己按 JSON Schema 解。避免"传 `Map<String, String>` 再手工解引号"
///    那类 bug（旧实现踩过）。
library;

// ★ 内置 git 的接口（2026-10-27）：与其余能力同一条纪律 —— 接口在本包，
//   实现由宿主注入。
//
// `import` 与 `export` 都要写，别以为 export 就够了：
//   · `export` 只让**本库的导入方**看到那些符号；
//   · 本文件自己（`Capabilities.git` 的字段类型）需要 `import` 才看得见。
//   （这两个文件互相 import 是**有意为之**：`git_capability.dart` 要用
//     本文件的 `CapabilityResult`，本文件要用它的 `GitCapability`。
//     Dart 允许这种循环 —— 两边都只是类型声明，没有初始化顺序问题。）
import 'git_capability.dart';
export 'git_capability.dart';
import 'sandbox_capability.dart';
export 'sandbox_capability.dart';

/// 能力调用结果。
///
/// **为什么不用异常**：agent 循环里，工具失败是**常态**（文件不存在、权限不足、
/// 命令返回非 0）。异常会给模型看到 `FileSystemException: ...` 这种东西，
/// 它读不懂也不知道下一步该做什么。用 [CapabilityResult] 把它变成
/// 「失败 + 一句人话原因」，模型就能自愈。
sealed class CapabilityResult {
  const CapabilityResult();
}

/// 成功。[data] 是要回给模型看的内容（文件内容、命令输出、构建产物路径…）。
final class CapabilitySuccess extends CapabilityResult {
  const CapabilitySuccess(this.data, {this.metadata});

  /// 回给模型的正文。**不要在这里塞 JSON 信封** —— 模型看到什么就是什么。
  final String data;

  /// 附带的结构化信息（不进模型上下文，仅供 UI 用：耗时、文件数、改动行数…）。
  final Map<String, dynamic>? metadata;
}

/// 失败。[reason] 是给模型的解释，必须是人话。
final class CapabilityFailure extends CapabilityResult {
  const CapabilityFailure(this.reason, {this.isRetryable = false});

  final String reason;

  /// 模型能否换个方式重试。`false` 表示"这条路彻底不通，别试了"。
  final bool isRetryable;
}

/// 需要用户批准。[detail] 是给审批弹窗看的，要能让用户判断"这是不是我想要的"。
final class CapabilityNeedsApproval extends CapabilityResult {
  const CapabilityNeedsApproval(this.detail);

  final String detail;
}

/// **需要用户「激活」某个能力**（2026-10-29）。
///
/// ============================================================================
/// 为什么它不是 [CapabilityFailure]
/// ============================================================================
/// 失败 = "这条路走不通，别试了"。而这里是：**用户点一下就能继续**。
/// 混淆两者的后果：
/// - 当失败 ⇒ 模型会放弃或换个歪招（比如偷偷改用手机 shell），用户永远不知道该激活；
/// - 当成功 ⇒ 更糟，模型以为命令跑了，基于假结果继续往下做。
///
/// 所以单独成一类：工具层翻译成「不要重试，已通知用户去激活」，
/// 同时带结构化 metadata，让宿主发 `activation_required` 事件弹引导卡。
///
/// ============================================================================
/// 当前唯一场景：T2 编译环境
/// ============================================================================
/// 基础沙箱（T0，Alpine rootfs）与常用工具（T1，aapt2 那套）都**内置在 APK**，
/// 随装随用。只有 **T2（JDK 17 + Gradle + android.jar，约 415 MB）** 要用户主动激活 ——
/// 它只服务「从源码编 APK」这一个低频重活。判据是「值不值得让所有人背这 415 MB」。
final class CapabilityNeedsActivation extends CapabilityResult {
  const CapabilityNeedsActivation({
    required this.capability,
    required this.downloadBytes,
    required this.summary,
    required this.benefit,
  });

  /// 能力标识（宿主据此决定装什么）。当前只有 `'apk-build'`。
  final String capability;

  /// 预计下载字节数（UI 要如实显示，别写"约几十 MB"糊弄）。
  final int downloadBytes;

  /// 一行说明，如 `JDK 17 + Gradle`。
  final String summary;

  /// 激活后能做到什么，如 `可以在沙箱内直接编译 APK`。
  final String benefit;
}

/// **工作区文件能力**。
///
/// 为什么参数是 `String path` 而不是 `Uri`/`File`：路径语义由实现决定
/// （POSIX 相对路径 vs SAF document id），后端不该知道。
abstract class WorkspaceCapability {
  /// 列目录。`path` 为空 = 工作区根。
  Future<CapabilityResult> list(String path, {bool recursive = false, int maxEntries = 200});

  /// 读文件。`offset` / `limit` 是行号（1-based），`limit = 0` 表示读到末尾。
  Future<CapabilityResult> read(String path, {int offset = 1, int limit = 0});

  /// 写文件（**整体覆盖**）。要追加语义由上层组合实现，不在能力层做。
  Future<CapabilityResult> write(String path, String content);

  /// 按行替换/插入（对应旧 `edit` 工具的语义）。失败要明确说明为什么匹配不上。
  Future<CapabilityResult> edit(String path, String oldText, String newText);

  /// 应用 unified diff。
  Future<CapabilityResult> applyPatch(String path, String patch);

  /// 建目录。
  Future<CapabilityResult> mkdir(String path);

  /// 删除。[recursive] 为 false 时目录非空则失败。
  Future<CapabilityResult> delete(String path, {bool recursive = false});

  /// 路径是否存在。
  Future<bool> exists(String path);

  /// 按 glob 找文件。glob 语法见 [GlobPattern]。
  Future<CapabilityResult> findFiles(String pattern, {int maxResults = 200});

  /// 按正则搜文件内容。
  Future<CapabilityResult> grepFiles(String pattern, {String pathFilter = '', int maxResults = 200});

  /// 移动 / 重命名。
  Future<CapabilityResult> move(String from, String to);

  /// 复制（保留源文件）。
  Future<CapabilityResult> copy(String from, String to);
}

/// **进程执行能力**。
abstract class ShellCapability {
  /// 在工作区里跑一条命令。
  ///
  /// ⚠️ **实现必须流式转发输出**，不得 `readAllBytes()` ——
  /// 长命令（构建）可能输出几 MB，全读进内存会 OOM。
  /// 进度通过 [onOutput] 回流，供 UI 显示。
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  });
}

/// **设备状态能力**（温度 / 电量）。
///
/// 这些是**安全熔断的输入**，不是可选信息：
/// 电池 < 20% 或温度 > 43°C 必须暂停长任务。
abstract class DeviceHealthCapability {
  Future<int?> batteryPercent();
  Future<double?> temperatureCelsius();
  Future<bool> isCharging();
}

/// **APK 构建 / 逆向能力**。
///
/// 这一块 Dart 完全做不到（要起 `aapt2`/`d8`/`apksigner` 进程并注入
/// bionic 环境）。接口留在这里，实现必须在 Android 侧。
abstract class ApkCapability {
  /// 从零构建 APK。`projectDir` 是工作区里的项目目录。
  Future<CapabilityResult> build({
    required String projectDir,
    void Function(String step)? onStep,
  });

  /// 反编译 APK（产物是 smali 目录）。
  Future<CapabilityResult> decompile(String apkPath, String outDir);

  /// 重打包（smali 目录 → APK），含对齐与签名。
  Future<CapabilityResult> recompile({
    required String smaliDir,
    required String outApkPath,
    void Function(String step)? onStep,
  });

  /// 签名。
  Future<CapabilityResult> sign(String apkPath);

  /// 安装到设备。
  Future<CapabilityResult> install(String apkPath);
}

/// **网络抓取能力**。
///
/// 为什么不直接用 `dio`：SSRF 防护（禁止访问内网/回环/元数据地址）是产品级
/// 安全要求，必须在**发起请求的那一层**做，不能交给工具参数校验。
abstract class WebCapability {
  /// 抓取网页并转成可读文本。
  ///
  /// ⚠️ **实现必须做 SSRF 防护**：拒绝 `127.0.0.1`、`169.254.169.254`、
  /// `10./172.16-31./192.168.`、`file://` 等。理由：模型可能被网页内容
  /// 诱导去读内网服务（提示注入），那一层必须在能力层挡，不能靠提示词。
  Future<CapabilityResult> fetch(String url, {int maxChars = 50000});
}

/// **长期记忆能力**（跨会话保留的项目知识与用户偏好）。
abstract class MemoryCapability {
  Future<String> read();
  Future<CapabilityResult> append(String note);
}

/// **全部能力的注入点**。
///
/// 后端只认这个聚合接口。宿主（Flutter app / CLI）决定每一项怎么实现，
/// 也可以传 `null` 表示"这个环境下不支持"—— 那个工具就会被标记为不可用，
/// 而不是跑起来才发现崩。
class Capabilities {
  const Capabilities({
    this.workspace,
    this.shell,
    this.deviceHealth,
    this.apk,
    this.web,
    this.memory,
    this.git,
    this.sandbox,
  });

  final WorkspaceCapability? workspace;
  final ShellCapability? shell;
  final DeviceHealthCapability? deviceHealth;
  final ApkCapability? apk;
  final WebCapability? web;
  final MemoryCapability? memory;

  /// **内置 git**（2026-10-27，Step 1）。
  ///
  /// 接口定义在 `git_capability.dart`，实现由宿主注入
  /// （App 侧是 `app/lib/services/git_service.dart`，基于纯 Dart 的 `git_dart`）。
  ///
  /// `null` ⇒ `git_*` 系列工具"一调用就失败并明说当前环境不支持 git"。
  /// 为什么不是"干脆不列出来"：与其余能力同一条纪律 —— 模型从历史里看到过
  /// 工具名，不列出来它会凭记忆乱调，报"未知工具"更难排查。
  final GitCapability? git;

  /// **沙箱执行面**（内联 PRoot rootfs）。
  ///
  /// 产品定调（2026-10-28）：**agent 的命令默认走沙箱**，只有「需要动 Android
  /// 本身」的才落手机 shell —— 路由规则见 `sandbox_capability.dart` 的
  /// `decideSurface`，**不由模型决定**（`run_shell_command` 不暴露 surface 参数）。
  ///
  /// `null` ⇒ 没接沙箱：一切回落手机 shell（路由会自动这么做）。
  final SandboxCapability? sandbox;
}

// ============================================================================
// 任务计划 —— 由框架的 Planner 管理，这里只做事件载体
// ============================================================================

/// 计划步骤状态。
///
/// 与 `dart_agent_core` 的 `StepStatus` 一一对应，**刻意保留 `cancelled`**：
/// 模型需要能说"这步不用做了"而不丢失历史（删掉步骤会丢掉"曾计划过"这个事实）。
enum PlanStepStatus { pending, active, done, cancelled }

/// 一个计划步骤（UI 视角）。
class PlanStep {
  const PlanStep(this.text, this.status);
  final String text;
  final PlanStepStatus status;
}

// ============================================================================
// 提问模型
// ============================================================================

/// 一个问题。
class AskQuestion {
  const AskQuestion({
    required this.id,
    required this.question,
    this.multi = false,
    this.options = const [],
  });

  final String id;
  final String question;

  /// 是否允许多选。
  final bool multi;

  /// 可选项；空 = 自由输入。
  final List<AskOption> options;
}

/// 一个选项。
class AskOption {
  const AskOption(this.label, {this.description});
  final String label;
  final String? description;
}