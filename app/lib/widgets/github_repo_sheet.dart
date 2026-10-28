/// **选择仓库面板**（2026-10-28）—— 已连接 GitHub 后点「@用户名」就是它。
///
/// ## 用户提的需求（原话）
///
/// > 连上了点击 github 就是选择仓库，上拉抽屉的上部有一个搜索框，
/// > 下面全是自己的仓库，搜索框可以搜索自己的仓库。
///
/// ## 布局（自上而下）
///
/// ```
/// ┌──────────────────────────────┐
/// │  ▔▔▔  抓手                   │
/// │  选择仓库                     │
/// │  ┌────────────────────────┐  │
/// │  │ 🔍 搜索你的仓库…        │  │  ← 搜索框（本地过滤，秒出）
/// │  └────────────────────────┘  │
/// │  ┌────────────────────────┐  │
/// │  │ Heracles     私有 2.3MB│  │  ← 列表：名字 + 私有标 + 体积
/// │  │ 把 Codex 做成安卓版…    │  │     描述（一行省略）
/// │  │ Heracles-taixu… 公开   │  │
/// │  └────────────────────────┘  │
/// │  共 12 个仓库                 │
/// └──────────────────────────────┘
/// ```
///
/// ## 为什么搜索是**本地过滤**而不是调 GitHub Search API
///
/// · `listRepos()` 一次拉 100 个（够覆盖绝大多数个人账号）；
/// · 搜索 API 限流 30 次/分钟，而用户每敲一个字就要打一次 ⇒ 很容易撞限流；
/// · 本地过滤是**零延迟**的，敲即出结果。
///
/// 代价：超过 100 个仓库时搜不到第 101 个之后的。这个限制写在 UI 的
/// 计数行里（"共 N 个"），不藏着。
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

/// 选中仓库后返回给调用方的结果。
class GitHubRepoChoice {
  const GitHubRepoChoice({
    required this.repo,
    required this.localPath,
    this.isLocal = false,
  });

  final GitHubRepo repo;

  /// 该仓库在本地的绝对路径（`<工作区>/<仓库名>`）。
  ///
  /// ⚠️ **路径存在 ≠ 已经下载**。是否已经下载看 [isLocal] ——
  /// 这是 2026-10-28 用户纠正的语义：选中不等于克隆。
  final String localPath;

  /// **本地是否已经有这个仓库**（工作区下的同名子目录带 `.git`）。
  ///
  /// `false` 时 UI 应该说清"还没下载"，不能假装能直接操作。
  final bool isLocal;
}

/// 弹出「选择仓库」抽屉。
///
/// [workspacePath] = 当前工作区绝对路径（克隆目标建在它下面）。
///
/// @return 选中的仓库（含本地路径）；`null` = 用户取消。
Future<GitHubRepoChoice?> showGitHubRepoSheet(
  BuildContext context, {
  required String workspacePath,
}) async {
  return showModalBottomSheet<GitHubRepoChoice>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: _GitHubRepoSheet(
        h: Hue.of(context),
        workspacePath: workspacePath,
      ),
    ),
  );
}

class _GitHubRepoSheet extends StatefulWidget {
  const _GitHubRepoSheet({required this.h, required this.workspacePath});

  final Hue h;
  final String workspacePath;

  @override
  State<_GitHubRepoSheet> createState() => _GitHubRepoSheetState();
}

class _GitHubRepoSheetState extends State<_GitHubRepoSheet> {
  static const _git = GitService();
  final _auth = GitHubAuth(clientId: GitHubConfig.clientId);
  final _searchCtrl = TextEditingController();

  bool _loading = true;

  /// 全部仓库（已拉到）。
  List<GitHubRepo> _all = const [];

  /// 网络/限流导致的失败信息（空 = 没失败）。
  String? _error;

  String _query = '';

  /// 本地已有的仓库名（工作区下有 .git 的子目录）。
  final Set<String> _cloned = <String>{};

  /// 正在克隆的仓库名（非空时列表禁用并显示进度）。
  String? _cloning;

  /// 克隆失败的原因（**显示在界面上**，不只是一闪而过的 toast）。
  ///
  /// 2026-10-28 真机教训：第一次克隆失败时只有 toast，等我截图时它已经
  /// 消失了 ⇒ 完全不知道错在哪。错误必须留在屏幕上直到用户采取动作。
  String? _cloneError;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim();
      if (q != _query) setState(() => _query = q);
    });
    // 先扫本地（同步、毫秒级），再拉远端列表 —— 这样列表一出来就带着
    // 「本地已有」标记，不会先显示"都没下载"再突然变。
    _scanLocal();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repos = await _auth.listRepos();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (repos == null) {
        _error = '还没有连接 GitHub';
        _all = const [];
      } else if (repos.isEmpty) {
        _error = '没有拉到仓库。可能是网络问题，或者这个账号还没有仓库。';
        _all = const [];
      } else {
        _all = repos;
      }
    });
  }

  /// 可见列表（按搜索词过滤）。
  List<GitHubRepo> get _visible {
    if (_query.isEmpty) return _all;
    return _all.where((r) => r.matches(_query)).toList();
  }

  /// **选中**一个仓库 —— 只是选中，**不克隆**。
  ///
  /// ## 2026-10-28 用户纠正的设计错误
  ///
  /// 第一版「点一下就克隆」。用户原话：
  ///
  /// > 为什么选择仓库是克隆这个仓库？这对吗？难道不是直接选择吗？
  /// > 然后下面的显示仓库名
  ///
  /// 他说得对。**选择是选择，下载是下载**，两件事不该绑在一起：
  ///
  /// · 用户可能只想看看这个仓库有哪些分支，不想为它下载 6.9 MB；
  /// · 克隆要几十秒，期间面板上行内的小转圈很容易被忽略，
  ///   看起来像"点了没反应"（真机上我一开始就以为失败了）；
  /// · 手机流量和存储都是真实成本，不该由一次"选择"隐式支付。
  ///
  /// ⇒ 现在：**点行 = 立即选中**（面板立刻关闭、底部显示仓库名）；
  /// 行尾的下载图标才是克隆，已下载过的行标「本地已有」。
  void _select(GitHubRepo repo) {
    debugPrint('GITREPO| select ${repo.name} (local=${_cloned.contains(repo.name)})');
    Navigator.of(context).pop(
      GitHubRepoChoice(
        repo: repo,
        localPath: '${widget.workspacePath}/${repo.name}',
        isLocal: _cloned.contains(repo.name),
      ),
    );
  }

  /// 明确点了下载图标才克隆到 `<工作区>/<仓库名>`。
  ///
  /// ## 为什么克隆到子目录而不是工作区根
  ///
  /// 工作区根可能已经有别的东西，而 `git clone` 要求目标目录为空 ⇒
  /// 直接克隆到根会失败。建子目录既避开冲突，也让"一个工作区放多个项目"可行。
  Future<void> _clone(GitHubRepo repo) async {
    if (_cloning != null) return;
    setState(() {
      _cloning = repo.name;
      _cloneError = null;
    });
    final dest = '${widget.workspacePath}/${repo.name}';
    try {
      final token = await _auth.readToken();
      final r = await _git.clone(
        url: repo.cloneUrl,
        destPath: dest,
        token: token,
      );
      if (!mounted) return;
      if (r is CapabilitySuccess) {
        debugPrint('GITREPO| clone ok: ${r.data}');
        if (!mounted) return;
        // 克隆成功后**只标记"本地已有"，不关闭面板** ——
        // 用户来这个面板的目的是"选仓库"，克隆是顺手做的事。
        setState(() => _cloned.add(repo.name));
        showIosToast(context, '已下载 ${repo.name}');
        return;
      }
      if (r is CapabilityFailure) {
        // 落日志 + 留在界面上：toast 会消失，错误不该消失
        debugPrint('GITREPO| clone failed: ${r.reason}');
        if (mounted) {
          setState(() => _cloneError = r.reason);
          showIosToast(context, r.reason);
        }
      }
    } finally {
      if (mounted) setState(() => _cloning = null);
    }
  }

  /// 扫工作区，找出**本地已有**的仓库（带 `.git` 的子目录）。
  ///
  /// 用来在列表上标「本地已有」，让用户一眼看出点下去是"直接切过去"
  /// 还是"只有远端"。不扫的话他会以为每个仓库都点得开。
  void _scanLocal() {
    final found = <String>{};
    try {
      final ws = Directory(widget.workspacePath);
      if (ws.existsSync()) {
        for (final e in ws.listSync()) {
          if (e is! Directory) continue;
          if (Directory('${e.path}/.git').existsSync()) {
            final segs = e.path.split('/');
            final name = segs.isEmpty ? '' : segs.last;
            if (name.isNotEmpty) found.add(name);
          }
        }
      }
    } catch (_) {
      // 扫不到就当"都没有" —— 只是少一个标记，不影响功能
    }
    if (mounted) setState(() => _cloned.addAll(found));
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            HSpace.lg, HSpace.xs, HSpace.lg, HSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抓手
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: HSpace.sm),
                decoration: BoxDecoration(
                  color: h.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '选择仓库',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: h.text,
              ),
            ),
            const SizedBox(height: HSpace.sm),

            // ---- 搜索框（在顶部，用户要求）----
            _searchBox(h),
            const SizedBox(height: HSpace.sm),

            // ---- 克隆失败的原因（留在界面上，不随 toast 消失）----
            if (_cloneError != null) ...[
              Container(
                padding: const EdgeInsets.all(HSpace.sm),
                decoration: BoxDecoration(
                  color: h.surfaceAlt,
                  borderRadius: BorderRadius.circular(HRadius.md),
                  border: Border.all(color: HColors.errorOn(h.dark)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(CupertinoIcons.exclamationmark_circle_fill,
                      size: 15, color: HColors.errorOn(h.dark)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _cloneError!,
                      style: TextStyle(fontSize: 12, color: h.text, height: 1.4),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: HSpace.sm),
            ],

            // ---- 列表 ----
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HSpace.lg),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: h.accent),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Text('正在读取你的仓库…',
                      style: TextStyle(fontSize: 13, color: h.textDim)),
                ]),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HSpace.md),
                child: Column(children: [
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: h.textDim, height: 1.5)),
                  const SizedBox(height: HSpace.sm),
                  TextButton(
                    onPressed: _load,
                    child: Text('重试',
                        style: TextStyle(fontSize: 14, color: h.accent)),
                  ),
                ]),
              )
            else if (_visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HSpace.lg),
                child: Text(
                  '没有匹配「$_query」的仓库',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: h.textDim),
                ),
              )
            else
              // ★ 列表限高：面板本身不会长太高，列表内部滚动。
              //   高度取 360 是「大约一屏能看 5~6 个仓库」，再多就该滚了。
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _visible.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 1,
                    color: h.border,
                  ),
                  itemBuilder: (_, i) => _repoRow(h, _visible[i]),
                ),
              ),
            const SizedBox(height: HSpace.sm),

            // ---- 计数（如实说明只拉了最近 100 个）----
            Text(
              _loading
                  ? ''
                  : '共 ${_all.length} 个仓库'
                      '${_all.length >= 100 ? '（只列最近更新的 100 个）' : ''}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: h.textFaint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBox(Hue h) => TextField(
        controller: _searchCtrl,
        enabled: _cloning == null,
        decoration: InputDecoration(
          hintText: '搜索你的仓库…',
          hintStyle: TextStyle(fontSize: 14, color: h.textFaint),
          prefixIcon: Icon(CupertinoIcons.search,
              size: 17, color: h.textFaint),
          suffixIcon: _query.isEmpty
              ? null
              : GestureDetector(
                  onTap: () => _searchCtrl.clear(),
                  child: Icon(CupertinoIcons.clear_circled_solid,
                      size: 17, color: h.textFaint),
                ),
          filled: true,
          fillColor: h.surfaceAlt,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HRadius.pill),
            borderSide: BorderSide(color: h.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(HRadius.pill),
            borderSide: BorderSide(color: h.border),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: HSpace.md, vertical: 10),
        ),
        style: TextStyle(fontSize: 14, color: h.text),
      );

  Widget _repoRow(Hue h, GitHubRepo r) {
    final busy = _cloning == r.name;
    final isLocal = _cloned.contains(r.name);

    // 行本身 = **选中**；行尾的图标 = **下载/已下载**。
    //
    // 2026-10-28 用户纠正：选择不该触发克隆。两个动作分开后，
    // 用户点行立刻得到反馈（面板关闭、底部显示仓库名），
    // 想下载再明确点那个图标。
    return InkWell(
      onTap: _cloning == null ? () => _select(r) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(
          children: [
            Icon(
              r.isPrivate ? CupertinoIcons.lock : CupertinoIcons.folder,
              size: 16,
              color: h.textFaint,
            ),
            const SizedBox(width: HSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 名字 + 体积 + 本地标记
                  Row(children: [
                    Flexible(
                      child: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: h.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: HSpace.xs),
                    Text(r.sizeLabel,
                        style:
                            TextStyle(fontSize: 11, color: h.textFaint)),
                    if (isLocal) ...[
                      const SizedBox(width: HSpace.xs),
                      Text('本地已有',
                          style: TextStyle(fontSize: 10.5, color: h.accent)),
                    ],
                  ]),
                  // 描述（没有就显示分支名，别留空行）
                  if (r.description.isNotEmpty || r.defaultBranch.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        r.description.isNotEmpty
                            ? r.description
                            : '默认分支 ${r.defaultBranch}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: h.textDim),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: HSpace.xs),
            // ---- 下载按钮（唯一会克隆的入口）----
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (isLocal)
              Icon(CupertinoIcons.checkmark_alt,
                  size: 16, color: h.accent)
            else
              GestureDetector(
                // 用 GestureDetector 包住：InkWell 的 onTap 会吞掉行内点击，
                // 这里要保证点图标**不会**同时触发"选中"
                onTap: _cloning == null ? () => unawaited(_clone(r)) : null,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(CupertinoIcons.arrow_down_circle,
                      size: 19, color: h.textDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
