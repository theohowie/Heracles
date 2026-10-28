/// **git 操作面板**（2026-10-27，Step 4）—— 用户手动做版本控制。
///
/// ## 设计立场：这是「给用户的按钮」，不是「给模型的工具」
///
/// 同一个 `GitService` 有两条入口：
///
/// | 入口 | 谁用 | 走审批吗 |
/// |---|---|---|
/// | `git_*` 工具（`backend/.../git_tools.dart`）| 模型 | ✅ 要（含 fail-closed）|
/// | **本文件** | 用户点按钮 | ❌ 不要（用户自己按的，他就是决策者）|
///
/// 所以这里**不经过** `_ApprovalHook` —— 那是给模型的闸。
///
/// ## 为什么先只做「看 + 提交 + 推」
///
/// 手机屏幕小，git 的完整能力塞不进来。按"用户在手机上真正会做的事"排：
///
/// · **看**：现在改了什么（status）—— 最高频
/// · **提交**：把这一小步固定成可回滚点 —— 第二高频
/// · **推**：推到远端 —— 有明确终点感
/// · 切换分支：放到次级（切分支会覆盖工作区，误触代价大）
/// · clone：放到「连接 Github」之后的引导里，不混进日常面板
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:heracles_backend/heracles_backend.dart';

import '../services/git_service.dart';
import '../services/github_auth.dart';
import '../services/github_config.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../widgets/bw_approval.dart';

/// 弹出 git 面板。
///
/// [workspacePath] 是当前工作区的**绝对路径**（由调用方从原生拿到）。
Future<void> showGitPanel(
  BuildContext context, {
  required String workspacePath,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: _GitPanel(
        h: Hue.of(context),
        workspacePath: workspacePath,
      ),
    ),
  );
}

class _GitPanel extends StatefulWidget {
  const _GitPanel({required this.h, required this.workspacePath});

  final Hue h;
  final String workspacePath;

  @override
  State<_GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<_GitPanel> {
  static const _git = GitService();
  final _auth = GitHubAuth(clientId: GitHubConfig.clientId);

  bool _loading = true;
  String? _error;

  /// 本地还没有这个仓库（选了一个 GitHub 仓库但没下载）。
  ///
  /// 与"不是仓库"区分：那种情况该问 init，这种情况该让用户回去下载。
  bool _notCloned = false;

  /// 是不是 git 仓库（否则显示"初始化"引导）。
  bool _isRepo = false;

  /// status 的渲染文本（直接给用户看，和给模型的是同一份）。
  String _statusText = '';

  /// 有没有改动（决定"提交"按钮可用性）。
  bool _dirty = false;

  /// 当前分支。
  String _branch = '';

  final _msgCtrl = TextEditingController();

  bool _busy = false;

  /// 分支列表（2026-10-28 用户要求：选了仓库要能切分支）。
  List<String> _branches = const [];

  /// 是否展开了分支选择区。
  bool _showBranches = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // ★ 先分清两件完全不同的事（2026-10-28）：
      //   · **目录不存在** ⇒ 用户选了一个 GitHub 仓库但还没下载
      //     （选仓库时我们刻意不自动克隆，见 `github_repo_sheet.dart`）
      //   · **目录存在但不是仓库** ⇒ 真的该问他要不要 init
      //
      // 不区分的话，"选了没下载的仓库"会看到「初始化 git 仓库」按钮 ——
      // 那个按钮点下去会失败（目录都不存在），是误导。
      if (!Directory(widget.workspacePath).existsSync()) {
        setState(() {
          _isRepo = false;
          _loading = false;
          _notCloned = true;
          _statusText = '本地还没有这个仓库。';
          _dirty = false;
          _branch = '';
        });
        return;
      }
      final isRepo = await _git.isRepository(widget.workspacePath);
      if (!isRepo) {
        setState(() {
          _isRepo = false;
          _notCloned = false;
          _loading = false;
          _statusText = '这个工作区还不是 git 仓库。';
          _dirty = false;
          _branch = '';
        });
        return;
      }
      // 顺带读分支列表（同一个面板要能切分支，见 `_showBranches`）
      final br = await _git.branches(widget.workspacePath);
      final branchNames = <String>[];
      if (br is CapabilitySuccess) {
        for (final line in br.data.split('\n')) {
          final t = line.trim();
          if (!t.startsWith('- ')) continue;
          // 形如 "- main  ← 当前"
          branchNames.add(t.substring(2).split('  ').first.trim());
        }
      }
      if (!mounted) return;
      setState(() => _branches = branchNames);

      final r = await _git.status(widget.workspacePath);
      if (!mounted) return;
      if (r is CapabilitySuccess) {
        final meta = r.metadata ?? const {};
        setState(() {
          _isRepo = true;
          _statusText = r.data;
          _dirty = meta['dirty'] == true;
          _branch = (meta['branch'] as String?) ?? '';
          _loading = false;
        });
      } else {
        setState(() {
          _isRepo = true;
          _loading = false;
          _error = r is CapabilityFailure ? r.reason : '读取状态失败';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取状态出错：$e';
      });
    }
  }

  /// 统一处理"要跑一个会改状态的 git 操作"。
  Future<void> _run(
    Future<CapabilityResult> Function() action, {
    String? successToast,
    bool clearMessage = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await action();
      if (!mounted) return;
      if (r is CapabilitySuccess) {
        if (clearMessage) _msgCtrl.clear();
        showIosToast(context, successToast ?? '完成');
      } else if (r is CapabilityFailure) {
        // 失败必须原样告诉用户 —— 不吞、不美化
        showIosToast(context, r.reason);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  Future<void> _init() => _run(
        () => _git.init(widget.workspacePath),
        successToast: '已初始化仓库',
      );

  /// 切到一个已有的分支。
  ///
  /// ## 有未提交改动时**不切**（能力层会拒绝，这里如实转达）
  ///
  /// `GitService.checkout` 在脏工作区时返回失败（"有未提交的改动，不能直接
  /// 切换分支"）—— 这条保护是**故意**的：切分支会覆盖工作区文件，
  /// 把用户正在编辑的东西冲掉是不可接受的默认行为。
  Future<void> _switchBranch(String name) async {
    if (_busy || name == _branch) return;
    setState(() => _busy = true);
    try {
      final r = await _git.checkout(widget.workspacePath, branch: name);
      if (!mounted) return;
      if (r is CapabilitySuccess) {
        showIosToast(context, '已切换到 $name');
        setState(() => _showBranches = false);
      } else if (r is CapabilityFailure) {
        showIosToast(context, r.reason);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  /// 新建分支并切过去。
  Future<void> _createBranch() async {
    final name = await _promptBranchName();
    if (name == null || name.trim().isEmpty) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _git.checkout(
        widget.workspacePath,
        branch: name.trim(),
        create: true,
      );
      if (!mounted) return;
      if (r is CapabilitySuccess) {
        showIosToast(context, '已创建并切到 ${name.trim()}');
        setState(() => _showBranches = false);
      } else if (r is CapabilityFailure) {
        showIosToast(context, r.reason);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  /// 让用户输入新分支名。
  Future<String?> _promptBranchName() async {
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (sheetCtx) => BwSheetShell(
        onDismissRequest: () => Navigator.of(sheetCtx).pop(false),
        // ★ 2026-10-28 真机 bug：输入框 `autofocus: true` 会弹键盘，
        //   而弹层贴着屏幕底 ⇒ **整个"新建分支"弹层被键盘盖住**，
        //   用户只看到键盘、看不到输入框和按钮。
        //   修法：把键盘高度作为底部内边距，弹层整体抬到键盘上方。
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  HSpace.lg, HSpace.xs, HSpace.lg, HSpace.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: HSpace.sm),
                    decoration: BoxDecoration(
                      color: widget.h.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('新建分支',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: widget.h.text)),
                const SizedBox(height: HSpace.sm),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '分支名，例如 feature/login',
                    hintStyle: TextStyle(
                        fontSize: 14, color: widget.h.textFaint),
                    filled: true,
                    fillColor: widget.h.surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(HRadius.md),
                      borderSide: BorderSide(color: widget.h.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(HRadius.md),
                      borderSide: BorderSide(color: widget.h.border),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: HSpace.md, vertical: HSpace.sm),
                  ),
                  style: TextStyle(fontSize: 14, color: widget.h.text),
                ),
                const SizedBox(height: HSpace.md),
                FilledButton(
                  onPressed: () => Navigator.of(sheetCtx).pop(true),
                  child: const Text('创建并切换'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(sheetCtx).pop(false),
                  child: Text('取消',
                      style: TextStyle(
                          color: widget.h.textDim, fontSize: 14)),
                ),
              ],
            ),
          ),
        ),
        ), // ← 键盘内边距 Padding 的收尾（2026-10-28 修「弹层被键盘盖住」）
      ),
    );
    if (ok == true) return ctrl.text.trim();
    return null;
  }

  Future<void> _commit() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty) {
      showIosToast(context, '先写一句"这次改了什么"');
      return;
    }
    // 先全部暂存（手机上用户不想逐个挑文件），再提交。
    // 两步都成功才提示成功 —— 否则用户会以为提交了。
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final st = await _git.stage(widget.workspacePath);
      if (st is CapabilityFailure) {
        if (mounted) showIosToast(context, st.reason);
        return;
      }
      final r =
          await _git.commit(widget.workspacePath, message: msg);
      if (!mounted) return;
      if (r is CapabilitySuccess) {
        _msgCtrl.clear();
        showIosToast(context, '已提交');
      } else if (r is CapabilityFailure) {
        showIosToast(context, r.reason);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  Future<void> _push() async {
    final token = await _auth.readToken();
    if (token == null || token.isEmpty) {
      if (mounted) showIosToast(context, '先连接 Github 才能推送');
      return;
    }
    await _run(
      () => _git.push(widget.workspacePath, token: token, setUpstream: true),
      successToast: '已推送',
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              HSpace.lg, HSpace.sm, HSpace.lg, HSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: HSpace.md),
                  decoration: BoxDecoration(
                    color: h.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(CupertinoIcons.arrow_branch,
                      size: 18, color: h.textDim),
                  const SizedBox(width: HSpace.sm),
                  Expanded(
                    child: Text(
                      _branch.isEmpty ? '版本控制' : '版本控制 · $_branch',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: h.text,
                      ),
                    ),
                  ),
                  if (!_loading && _isRepo)
                    TextButton(
                      onPressed: _busy ? null : _refresh,
                      child: Text('刷新',
                          style: TextStyle(fontSize: 13, color: h.accent)),
                    ),
                ],
              ),
              const SizedBox(height: HSpace.md),
              if (_loading)
                Row(children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: h.accent),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Text('读取中…',
                      style: TextStyle(fontSize: 13, color: h.textDim)),
                ])
              else if (_error != null)
                _errorRow(h, _error!)
              else if (_notCloned)
                _notClonedPrompt(h)
              else if (!_isRepo)
                _initPrompt(h)
              else
                ..._repoBody(h),
              const SizedBox(height: HSpace.md),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('关闭',
                    style: TextStyle(color: h.textDim, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorRow(Hue h, String msg) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(CupertinoIcons.exclamationmark_circle_fill,
              size: 18, color: HColors.errorOn(h.dark)),
          const SizedBox(width: HSpace.sm),
          Expanded(
            child: Text(msg,
                style: TextStyle(fontSize: 13.5, color: h.text, height: 1.5)),
          ),
        ],
      );

  /// 选中了 GitHub 仓库但**本地还没下载**时的提示。
  ///
  /// 为什么不能直接给「初始化」按钮：那个目录根本不存在，
  /// 点下去必然失败（"目录不存在"），属于**误导性按钮**。
  /// 这里如实说明现状 + 告诉用户去哪下载。
  Widget _notClonedPrompt(Hue h) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '本地还没有这个仓库。',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: h.text),
          ),
          const SizedBox(height: HSpace.xs),
          Text(
            '回到「选择仓库」，点这个仓库右侧的 ↓ 下载图标即可。'
            '下载完成后回来这里就能切分支、提交。',
            style: TextStyle(fontSize: 13, color: h.textDim, height: 1.55),
          ),
        ],
      );

  Widget _initPrompt(Hue h) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '这个工作区还不是 git 仓库。初始化之后，你就能把每次改动提交成'
            '可回滚的检查点。',
            style: TextStyle(fontSize: 14, color: h.textDim, height: 1.6),
          ),
          const SizedBox(height: HSpace.md),
          FilledButton(
            onPressed: _busy ? null : _init,
            child: const Text('初始化 git 仓库'),
          ),
        ],
      );

  List<Widget> _repoBody(Hue h) => [
        // ---- 状态（等宽字体，保留换行）----
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(HSpace.md),
          decoration: BoxDecoration(
            color: h.surfaceAlt,
            borderRadius: BorderRadius.circular(HRadius.md),
            border: Border.all(color: h.border),
          ),
          child: Text(
            _statusText,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.55,
              color: h.text,
            ),
          ),
        ),
        const SizedBox(height: HSpace.md),

        // ---- 提交 ----
        if (_dirty) ...[
          TextField(
            controller: _msgCtrl,
            maxLines: 2,
            minLines: 1,
            decoration: InputDecoration(
              hintText: '这次改了什么？（提交信息）',
              hintStyle: TextStyle(fontSize: 14, color: h.textFaint),
              filled: true,
              fillColor: h.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(HRadius.md),
                borderSide: BorderSide(color: h.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(HRadius.md),
                borderSide: BorderSide(color: h.border),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: HSpace.md, vertical: HSpace.sm),
            ),
            style: TextStyle(fontSize: 14, color: h.text),
          ),
          const SizedBox(height: HSpace.sm),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : _commit,
                child: const Text('提交全部改动'),
              ),
            ),
          ]),
          const SizedBox(height: HSpace.md),
        ] else
          Text('没有未提交的改动。',
              style: TextStyle(fontSize: 13.5, color: h.textDim)),

        // ---- 分支（2026-10-28 用户要求：选定仓库后要能切分支）----
        const SizedBox(height: HSpace.md),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => setState(() => _showBranches = !_showBranches),
          icon: const Icon(CupertinoIcons.arrow_branch, size: 16),
          label: Text(
            _showBranches ? '收起分支' : '切换分支（${_branches.length} 个）',
          ),
        ),
        if (_showBranches) ...[
          const SizedBox(height: HSpace.sm),
          Container(
            decoration: BoxDecoration(
              color: h.surfaceAlt,
              borderRadius: BorderRadius.circular(HRadius.md),
              border: Border.all(color: h.border),
            ),
            child: Column(
              children: [
                if (_branches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(HSpace.md),
                    child: Text('还没有分支（仓库还没有提交）',
                        style: TextStyle(fontSize: 13, color: h.textDim)),
                  )
                else
                  ..._branches.map((b) {
                    final current = b == _branch;
                    return InkWell(
                      onTap: _busy || current ? null : () => unawaited(_switchBranch(b)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: HSpace.md, vertical: 11),
                        child: Row(
                          children: [
                            Icon(
                              current
                                  ? CupertinoIcons.checkmark_alt
                                  : CupertinoIcons.arrow_branch,
                              size: 15,
                              color: current ? h.accent : h.textFaint,
                            ),
                            const SizedBox(width: HSpace.sm),
                            Expanded(
                              child: Text(
                                b,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: current
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: h.text,
                                ),
                              ),
                            ),
                            if (current)
                              Text('当前',
                                  style: TextStyle(
                                      fontSize: 11, color: h.textFaint)),
                          ],
                        ),
                      ),
                    );
                  }),
                Divider(height: 1, thickness: 1, color: h.border),
                InkWell(
                  onTap: _busy ? null : () => unawaited(_createBranch()),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: HSpace.md, vertical: 11),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.add,
                            size: 15, color: h.accent),
                        const SizedBox(width: HSpace.sm),
                        Text('新建分支',
                            style: TextStyle(fontSize: 14, color: h.accent)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: HSpace.xs),
          Text(
            '切换分支会覆盖工作区文件。有未提交改动时会被拒绝 —— 先提交再切。',
            style: TextStyle(fontSize: 11, color: h.textFaint, height: 1.45),
          ),
        ],

        // ---- 推送 ----
        const SizedBox(height: HSpace.md),
        OutlinedButton.icon(
          onPressed: _busy ? null : _push,
          icon: const Icon(CupertinoIcons.cloud_upload, size: 16),
          label: const Text('推送到 GitHub'),
        ),
        const SizedBox(height: HSpace.xs),
        Text(
          '推送会把本地提交发到远端仓库。首次推送会自动把当前分支设为上游。',
          style: TextStyle(fontSize: 11.5, color: h.textFaint, height: 1.45),
        ),
      ];
}
