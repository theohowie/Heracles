/// **Git 能力接口**（2026-10-27，Step 1）—— 内置 git 的抽象层。
///
/// ## 为什么接口在 backend、实现在 app
///
/// 与 [WorkspaceCapability] / [ShellCapability] 同一条纪律（见 `capabilities.dart`
/// 文件头的「设计约束 1：接口在这里，实现不在」）：
///
/// · **backend 是纯 Dart 包**（`dart test` 毫秒级可跑，不 import flutter）
///   ⇒ 编排层的"git 怎么参与 agent 循环"（工具包装、审批、结果翻译）
///     可以脱离设备单测；
/// · **真正操作文件系统的是宿主**（`git_dart` 需要 `dart:io` + App 的存储权限）
///   ⇒ 实现放在 `app/lib/services/git_service.dart`。
///
/// ## 为什么"一个方法一件事"而不是 `run(args)` 直通
///
/// 旧思路是「给一个 `git(args)` 让模型自己拼命令」。那个形状在**审批层**上
/// 是灾难：审批要展示"用户将看到什么、会被改什么"，而一条自由命令无法归类
/// （`git push --force` 和 `git status` 在字符串层面长得一样）。
///
/// 现在每个动作是一个**类型化方法**：审批表能精确分类（只读 / 改工作区 /
/// 外发代码），拒绝文案能写明后果，测试能逐个钉住。
///
/// ## 与真实 git 的关系（Step 0 真机实测已验证）
///
/// 实现基于纯 Dart 的 `git_dart`（设备上没有 git 二进制，也不能调 Termux）。
/// 实测结论（设备 e35e48c6 / Android 17 / arm64）：
///
/// · `init` 17ms / `commit` 68ms / `status` 16ms —— **同步调用不卡 UI**，
///   不需要 up isolate（这条推翻了我最初的担心，有真机数据支撑）；
/// · 中文/空格/emoji 文件名全部正常；
/// · CRLF 不被破坏（这是本项目 `applyPatch` 历史上的数据损坏级 bug，
///   在 git 这条路上不复现）；
/// · 生成物经系统 `git fsck --full --strict` 校验通过（exit 0）⇒
///   **标准 git 格式**，用户可以把仓库拷到电脑上用真 git 接手。
///
/// ## 能力缺失的语义
///
/// 宿主传 `null` ⇒ 所有 git 工具"一调用就失败并明说原因"，与该文件里
/// 其他能力一致（不列出来会让模型凭记忆乱调）。
library;

import 'capabilities.dart';

/// 一次提交的元信息（给 UI 和模型看）。
///
/// ## 为什么字段是这些（不是照搬 git 的全套）
///
/// 模型做"这个仓库最近改了什么"这类判断，只需要：**谁、何时、一句话、
/// 动了什么**。完整作者邮箱/时区/父提交链对 agent 场景是噪音，
/// 但 `id` 和 `shortId` 都要给 —— 模型引用提交时用短哈希（人读），
/// 程序再操作时用全长哈希（避免歧义）。
class GitCommitInfo {
  const GitCommitInfo({
    required this.id,
    required this.shortId,
    required this.message,
    required this.authorName,
    required this.authorEmail,
    required this.timestamp,
  });

  /// 完整哈希（40 位 SHA-1）。
  final String id;

  /// 短哈希（前 7 位）—— 给人看、给模型引用。
  final String shortId;

  /// **首行**消息（多行正文已截断）。
  ///
  /// 为什么只留首行：`git log --oneline` 的惯例，且长正文会把工具结果撑爆。
  /// 需要正文的场合走 [GitCapability.showCommit]。
  final String message;

  final String authorName;
  final String authorEmail;

  /// 提交时间（Unix 秒）。
  final int timestamp;
}

/// 一个工作区里的改动（`status` 的一行）。
///
/// ## 为什么用 `String` 而不是 enum
///
/// 改动类型是 git 的**固定词表**（`M`/`A`/`D`/`R`/`?`），不需要我们发明
/// 一套 enum 再映射回去 —— 多一层映射就多一次"改了一处没改另一处"。
/// 但要提供 [isStaged] / [isUntracked] 这类**判据**，避免调用方自己比对字符。
class GitStatusEntry {
  const GitStatusEntry({
    required this.path,
    this.oldPath,
    this.isStaged = false,
    this.isUntracked = false,
    this.isConflicted = false,
    this.stagedKind,
    this.unstagedKind,
  });

  /// 工作区相对路径（用 `/` 分隔）。
  final String path;

  /// 重命名前的路径（只有重命名才有）。
  final String? oldPath;

  /// 已暂存（index 与 HEAD 有差异）。
  final bool isStaged;

  /// 未跟踪（新文件，从未 add 过）。
  final bool isUntracked;

  /// 冲突（merge/rebase 未解决）。
  final bool isConflicted;

  /// 暂存区的改动类型（`M` / `A` / `D` / `R`）。
  final String? stagedKind;

  /// 工作区的改动类型（`M` / `D`）。
  final String? unstagedKind;
}

/// 仓库当前状态（`status` 的完整结果）。
class GitStatus {
  const GitStatus({
    required this.branch,
    required this.entries,
    this.ahead = 0,
    this.behind = 0,
    this.hasUpstream = false,
  });

  /// 当前分支名（分离 HEAD 时是 `(detached)`）。
  final String branch;

  final List<GitStatusEntry> entries;

  /// 领先上游多少个提交。
  final int ahead;

  /// 落后上游多少个提交。
  final int behind;

  /// 是否配置了上游（没配 ⇒ ahead/behind 恒 0，不代表"同步"）。
  ///
  /// ⚠️ 这个字段存在的理由：`ahead=0 && behind=0` 有两种完全不同的含义 ——
  /// "已同步" 和 "压根没上游"。不给这一位，UI 会把没配置上游的仓库
  /// 画成"已同步"，那是假信息。
  final bool hasUpstream;

  /// 有没有任何改动（含未跟踪）。
  bool get isDirty => entries.isNotEmpty;
}

/// 一个分支。
class GitBranch {
  const GitBranch({required this.name, required this.isCurrent});

  final String name;
  final bool isCurrent;
}

/// **Git 能力**。
///
/// ## 方法分组（决定审批档位，见 `agent/tools/git_tools.dart`）
///
/// | 组 | 方法 | 审批 |
/// |---|---|---|
/// | 只读 | [status] [log] [diff] [branches] [showCommit] | 不需要 |
/// | 改本仓库 | [init] [stage] [unstage] [commit] [checkout] [createBranch] | 需要 |
/// | 改工作区文件 | [checkout] [reset] | 需要（会覆盖用户的文件）|
/// | 网络 | [clone] [pull] [push] [fetch] | 需要（**push 最严**）|
///
/// ## 失败语义（与 [CapabilityResult] 一致）
///
/// 所有方法返回 [CapabilityResult]，**不抛异常**。理由见 `capabilities.dart`：
/// agent 循环里工具失败是常态，模型要看到"一句人话"，不是栈。
abstract class GitCapability {
  /// 这个路径是不是 git 仓库（含向上查找父目录，与 git 行为一致）。
  Future<bool> isRepository(String path);

  /// 初始化仓库。
  ///
  /// [defaultBranch] 默认 `main`（不是 git 的老默认 `master` —— 新仓库
  /// 用哪个是产品决定，用户可在设置里改）。
  Future<CapabilityResult> init(String path, {String defaultBranch = 'main'});

  /// 仓库状态。
  Future<CapabilityResult> status(String path);

  /// 提交历史（新 → 旧）。
  ///
  /// [limit] 默认 20：够看"最近改了什么"，又不至于把结果撑爆。
  Future<CapabilityResult> log(
    String path, {
    int limit = 20,
    String? branch,
  });

  /// 工作区改动（unified diff 文本）。
  ///
  /// [staged] = true 看暂存区（`git diff --cached` 语义），
  /// false 看工作区（`git diff` 语义）。
  Future<CapabilityResult> diff(
    String path, {
    bool staged = false,
    String? file,
  });

  /// 暂存。
  ///
  /// [paths] 为空表示暂存全部改动（含新文件）。
  Future<CapabilityResult> stage(String path, {List<String> paths = const []});

  /// 取消暂存。
  Future<CapabilityResult> unstage(String path, {List<String> paths = const []});

  /// 提交（**只提交已暂存的内容**，与 git 一致）。
  Future<CapabilityResult> commit(
    String path, {
    required String message,
    String? authorName,
    String? authorEmail,
  });

  /// 列出分支。
  Future<CapabilityResult> branches(String path);

  /// 切换分支。
  ///
  /// ⚠️ 会**覆盖工作区文件**。有未提交改动时按 git 语义失败（不 force）——
  /// 强制覆盖用户正在编辑的文件是不可接受的默认行为。
  Future<CapabilityResult> checkout(
    String path, {
    required String branch,
    bool create = false,
  });

  /// 看单个提交的详情（含完整正文）。
  Future<CapabilityResult> showCommit(String path, {required String id});

  // ------------------------------------------------------------------
  // 远程（HTTPS only）
  // ------------------------------------------------------------------
  //
  // ⚠️ **不支持 SSH**：`git_dart` 的 SSH 依赖外部 `ssh` 命令，Android 上没有。
  // 所有远程操作走 `https://...`，认证用 OAuth token（Device Flow 拿到）。

  /// 克隆。
  ///
  /// [depth] 非空 ⇒ 浅克隆（省流量，手机场景常用）。
  Future<CapabilityResult> clone({
    required String url,
    required String destPath,
    String? token,
    int? depth,
    void Function(String message)? onProgress,
  });

  /// 拉取（当前分支）。
  Future<CapabilityResult> pull(String path, {String? token});

  /// 推送（当前分支）。
  ///
  /// [setUpstream] = 首次推送新分支时把 `origin/<branch>` 设为上游。
  ///
  /// ⚠️ **这是最危险的操作**（把手机上的代码推到公网）。实现与工具层
  /// 都必须让它走最严的审批档。
  Future<CapabilityResult> push(
    String path, {
    String? token,
    bool setUpstream = false,
  });

  /// 只取不合并。
  Future<CapabilityResult> fetch(String path, {String? token});
}
