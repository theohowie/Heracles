/// **Git 工具**（2026-10-27，Step 2）—— 给 agent 用的 git 能力。
///
/// ## 三层分工（与 file/shell 工具同一套形状）
///
/// ```
/// git_tools.dart（本文件）   ← 工具壳：JSON Schema + 参数取值 + 结果翻译
///     ↓ 调
/// GitCapability              ← 抽象接口（backend/lib/src/capability/）
///     ↓ 实现
/// GitService                 ← git_dart 封装（app/lib/services/）
/// ```
///
/// **业务逻辑不在本层**：不在工具里判断"有没有未提交改动"、"分支是否存在" ——
/// 那是能力层的职责。工具只做三件事（见 `tool_factory.dart` 的核心原则）：
/// 1. 声明 JSON Schema（给模型看）
/// 2. 从 `Map<String, dynamic>` 类型化取参
/// 3. 调能力层，把 `CapabilityResult` 翻译成模型读得懂的文字
///
/// ## 为什么 git 值得给 agent 用（而不是只做 UI 按钮）
///
/// agent 做多步任务时，"我改完了"和"改动已经提交、能回滚"是两件事。
/// 有了 git 工具，模型可以自己：
/// · 改代码前后 `git_status` 看自己动了什么；
/// · 用小步 `git_commit` 形成可回滚的检查点（这是 Aider/Cursor 的核心做法）；
/// · 发现改坏了 `git_diff` 看差异、而不是重新读整个文件。
///
/// ## 审批（最重要的一节）
///
/// 工具名已登记在 `_ApprovalHook._readOnly`（只读那 5 个）与 `_riskOf`
/// （风险文案）里。分类：
///
/// | 工具 | 审批 | 理由 |
/// |---|---|---|
/// | git_status / git_log / git_diff / git_branches / git_show_commit | 免 | 纯读 |
/// | git_stage / git_unstage | 要 | 改 index |
/// | git_commit | 要 | 写对象库、动 HEAD |
/// | git_checkout | 要 | **覆盖工作区文件** |
/// | git_init | 要 | 建 `.git/` |
/// | git_clone | 要 | 大量写盘 |
/// | git_pull / git_fetch | 要 | 改本地仓库（pull 覆盖工作区）|
/// | git_push | 要 | **外发代码到公网** |
///
/// ⚠️ 前提前置：`_ApprovalHook.needsApproval` 已改成 **fail-closed**
/// （白名单放行 / 其余默认要批）。旧实现是 fail-open，未知工具会静默放行 ——
/// 那样加这批工具等于**绕过审批**。那条修复在 `heracles_agent.dart`
/// 的 `_readOnly` 注释里，附 5 条测试。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../contract/contract.dart';
import '../../tools/tool_factory.dart';

/// 构建全部 git 工具（**10 个**）。
///
/// 数量由 `test/git_tools_test.dart` 钉住：加工具必须同时改测试与
/// `_ApprovalHook` 的分类表，不允许"加了工具忘了登记审批"。
List<Tool> buildGitTools(ToolFactory f, Capabilities caps) {
  final git = caps.git;

  /// 所有工具共用的可用性判定。
  bool available() => git != null;

  const unavailable = '当前环境不支持 git（宿主没有注入 git 能力）';

  return [
    // ==================================================================
    // 只读（5 个）—— 免审批
    // ==================================================================
    f.build(
      name: 'git_status',
      description: '查看 git 仓库当前状态：在哪个分支、有哪些未提交的改动。'
          '返回：分支名 + 逐条改动（已暂存 / 未暂存 / 未跟踪 / 冲突）。'
          '适合：动手前了解现状、改完后确认自己动了什么。'
          '⚠️ 不是 git 仓库时会明确告知（不会自动 init）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.` 表示工作区根。',
            'default': '.',
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        return git!.status(path);
      },
    ),

    f.build(
      name: 'git_log',
      description: '查看提交历史（新 → 旧）。'
          '返回：每条提交的短哈希、作者、时间、首行消息。'
          '适合：了解最近改了什么、找到要回看的提交。'
          '⚠️ 只给首行消息 —— 需要完整正文用 git_show_commit。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'limit': {
            'type': 'integer',
            'description': '最多返回几条，默认 ${ContractGit.defaultLogLimit}，'
                '上限 ${ContractGit.maxLogLimit}。',
            'default': ContractGit.defaultLogLimit,
            'minimum': 1,
            'maximum': ContractGit.maxLogLimit,
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final limit = optionalInt(args, 'limit') ?? ContractGit.defaultLogLimit;
        return git!.log(path, limit: limit);
      },
    ),

    f.build(
      name: 'git_diff',
      description: '查看未提交的改动清单。'
          '返回：逐条改动（类型 + 文件路径）。'
          '适合：确认自己改了什么，不必重新读整个文件。'
          '⚠️ `staged=true` 看暂存区，否则看工作区。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'staged': {
            'type': 'boolean',
            'description': 'true = 看暂存区（将被提交的内容）；默认 false = 看工作区。',
            'default': false,
          },
          'file': {
            'type': 'string',
            'description': '只看某个文件（相对路径）。不填 = 全部。',
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final staged = optionalBool(args, 'staged') ?? false;
        final file = optionalString(args, 'file');
        return git!.diff(path, staged: staged, file: file);
      },
    ),

    f.build(
      name: 'git_branches',
      description: '列出所有本地分支，标出当前分支。'
          '返回：分支清单（当前分支带 ← 标记）。'
          '适合：切分支前确认有哪些可选、确认自己在哪个分支上。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        return git!.branches(path);
      },
    ),

    f.build(
      name: 'git_show_commit',
      description: '查看某次提交的详情（完整提交信息 + 作者 + 时间）。'
          '返回：哈希、作者、时间、完整提交消息。'
          '适合：git_log 看到某条感兴趣后展开看全文。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'id': {
            'type': 'string',
            'description': '提交哈希（短的 7 位或完整 40 位都行）。',
          },
        },
        'required': ['id'],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final id = requireString(args, 'id');
        return git!.showCommit(path, id: id);
      },
    ),

    // ==================================================================
    // 改本地仓库（4 个）—— 要审批
    // ==================================================================
    f.build(
      name: 'git_stage',
      description: '把改动加入暂存区（相当于 `git add`）。'
          '返回：暂存后还有几项待提交。'
          '适合：提交前挑要包含的文件。'
          '⚠️ 不传 paths 表示**全部暂存**（含新文件）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'paths': {
            'type': 'array',
            'description': '要暂存的文件（相对路径）。不填 = 全部暂存。',
            'items': {'type': 'string'},
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final paths = _stringList(args['paths']);
        return git!.stage(path, paths: paths);
      },
    ),

    f.build(
      name: 'git_unstage',
      description: '把已暂存的改动撤出暂存区（工作区文件不变）。'
          '返回：撤了几项。'
          '适合：发现暂存了不该提交的文件。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'paths': {
            'type': 'array',
            'description': '要撤出的文件。不填 = 全部撤销暂存。',
            'items': {'type': 'string'},
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final paths = _stringList(args['paths']);
        return git!.unstage(path, paths: paths);
      },
    ),

    f.build(
      name: 'git_commit',
      description: '提交暂存区的改动（**只提交已暂存的**，与 git 一致）。'
          '返回：提交的短哈希 + 首行消息。'
          '适合：完成一小步后建立可回滚的检查点。'
          '⚠️ 暂存区为空会失败（先用 git_stage）。'
          '⚠️ 首行建议 ≤${ContractGit.recommendedMessageChars} 字符。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'message': {
            'type': 'string',
            'description': '提交信息。首行写"这次改了什么"，需要时可加正文。',
          },
        },
        'required': ['message'],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final message = requireString(args, 'message');
        return git!.commit(path, message: message);
      },
    ),

    f.build(
      name: 'git_checkout',
      description: '切换分支（`create=true` 时新建并切换）。'
          '返回：切换后的分支名。'
          '⚠️ 会**覆盖工作区文件**。有未提交改动时会被拒绝（不会强切）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'branch': {
            'type': 'string',
            'description': '分支名。',
          },
          'create': {
            'type': 'boolean',
            'description': 'true = 新建该分支并切过去；默认 false = 切到已存在的分支。',
            'default': false,
          },
        },
        'required': ['branch'],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final branch = requireString(args, 'branch');
        final create = optionalBool(args, 'create') ?? false;
        return git!.checkout(path, branch: branch, create: create);
      },
    ),

    // ==================================================================
    // 远程（1 个）
    // ==================================================================
    //
    // ## 为什么只开 push，不开 clone/pull/fetch
    //
    // 这三个在 Step 1 已经实现了能力层，但**先不给 agent 用**：
    //
    // · `clone` —— 要 URL + token，且会大量写盘；用户手动点更合适
    //   （UI 那边有「连接 Github」入口）。
    // · `pull` —— 会覆盖工作区文件，且需要处理"本地有分叉"的人话引导；
    //   在没有 UI 反馈的情况下让 agent 自己拉，出现冲突就卡死。
    // · `fetch` —— 只取不合并，agent 拿它没什么能做的（要合并还得 pull）。
    //
    // `push` 反而值得开：agent 完成一串提交后，"推上去"是明确的终点动作，
    // 且**能被审批拦住**（风险文案会写明"代码离开这台设备"）。
    f.build(
      name: 'git_push',
      description: '把当前分支的提交推送到远程仓库（origin）。'
          '返回：推送结果或拒绝原因。'
          '⚠️ 代码会离开这台设备。推到公开仓库等于对外发布。'
          '⚠️ 推送被拒通常是远端有你没有的提交 —— 让用户先拉取。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '仓库路径（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'set_upstream': {
            'type': 'boolean',
            'description': '首次推送新分支时是否把它设为上游（`-u`）。默认 false。',
            'default': false,
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      // 推送还需要 token —— 但 token 由宿主在 GitService 里注入，
      // 工具层不碰（也不该出现在参数里：那会把凭据写进模型上下文）。
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final setUpstream = optionalBool(args, 'set_upstream') ?? false;
        return git!.push(path, setUpstream: setUpstream);
      },
    ),

    // ==================================================================
    // 初始化（1 个）
    // ==================================================================
    f.build(
      name: 'git_init',
      description: '在工作区（或其子目录）初始化一个 git 仓库。'
          '返回：初始化成功的分支名。'
          '适合：用户的项目还不是 git 仓库、但想要版本控制时。'
          '⚠️ 已经是 git 仓库时会失败（不会重复初始化）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要初始化的目录（工作区相对路径）。默认 `.`。',
            'default': '.',
          },
          'default_branch': {
            'type': 'string',
            'description': '默认分支名，默认 `${ContractGit.defaultBranch}`。',
            'default': ContractGit.defaultBranch,
          },
        },
        'required': <String>[],
      },
      isAvailable: available,
      unavailableReason: unavailable,
      run: (args) async {
        final path = optionalString(args, 'path') ?? '.';
        final branch =
            optionalString(args, 'default_branch') ?? ContractGit.defaultBranch;
        return git!.init(path, defaultBranch: branch);
      },
    ),
  ];
}

/// 从参数里取字符串列表。
///
/// ## 为什么**不**容忍"模型传单个字符串"
///
/// 一开始我想宽容处理（`"a.txt"` 当成 `["a.txt"]`），但实测发现更早的一道
/// 闸已经拦住了：`ToolFactory._validateAgainstSchema` 按 schema 的
/// `type: 'array'` 判定，字符串会得到一条明确的
/// 「参数 `paths` 应是 `array`，收到 String」。
///
/// 而那条**正是我们想要的** —— 与 `optionalInt` 的立场一致：
/// "宽容会让它一直错下去；明确的类型错误它一轮就能改对"。
/// 所以这里只处理 List，不做额外宽容（那会成为一段永远走不到的代码）。
List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is String && e.trim().isNotEmpty) e.trim(),
  ];
}
