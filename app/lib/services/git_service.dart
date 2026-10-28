/// **Git 能力的实现**（2026-10-27，Step 1）—— 基于纯 Dart 的 `git_dart`。
///
/// ## 为什么必须是纯 Dart
///
/// 设备 e35e48c6（Android 17 / arm64-v8a）上**没有 git 二进制**：
///
/// ```
/// /system/bin/git      → 不存在
/// /system/xbin/git     → 不存在
/// /vendor/bin/git      → 不存在
/// toolchain/termux/    → 只有 aapt2 / zip / apk 相关，没有 git
/// ```
///
/// 也不能借 Termux：跨 App 执行受限（`/data/data/com.termux` 对本 App
/// 是 `Permission denied`）。
///
/// pub 上的候选我逐个查过：
///
/// | 包 | 结论 |
/// |---|---|
/// | `git` (kevmoo) | ❌ **命令行包装器**，要有 git 二进制才工作 |
/// | `dart_git` | ❌ 停更 2021，SDK `<3.0.0`，编译不过 |
/// | `git_on_dart` | ⚠️ 可用但仅 1 star、更新停在 1 月 |
/// | **`git_dart`** | ✅ **选用**，纯 Dart、活跃（2026-09）|
///
/// ## Step 0 真机实测结论（这个文件的设计依据）
///
/// 在**真实工作区** `/storage/emulated/0/Android/data/com.theohowie.heracles/
/// files/app-workspace`（FUSE 挂载的外部私有目录）上跑完 11 项全绿：
///
/// ```
/// OK  init                17ms
/// OK  status              16ms   （中文/空格/emoji 文件名全识别）
/// OK  stage+commit        68ms
/// OK  log / readFile / CRLF 保持 / 200KB 二进制 / .git 1.4KB
/// ```
///
/// 三条**推翻最初假设**的结论，直接决定本文件不写 isolate：
///
/// 1. **不需要 up isolate** —— 全部操作 < 100ms；500 文件 status 也只要 19ms
///    （`git_dart` 有 stat 缓存）。最初担心"同步 API 卡 UI"，实测不成立。
/// 2. **CRLF 不被破坏** —— 这是本项目 `applyPatch` 历史上的数据损坏级 bug，
///    在 git 这条路上不复现。
/// 3. **生成物是标准 git 格式** —— 系统 `git fsck --full --strict` exit 0。
///
/// ## ⚠️ 关于 `git_dart` 的 API 形状（踩过的坑，写下来免得下次再猜）
///
/// · **远程操作是顶层函数，不是 Repository 方法**：
///   `clone(repo?... )` / `fetch(repository, remote, ...)` / `push(repository, remote, ...)`；
/// · **没有 `pull`** —— 必须自己组合 `fetch` + 快进合并；
/// · 分支走 `repo.refs.currentBranch`（返回 `refs/heads/xxx`），
///   不是 `repo.branchName()`；
/// · 取消暂存用 `repo.unstage(path)`（**有专门方法**，不必自己 reset）；
/// · 远程对象从 `repo.remotes.named('origin')` 取。
///
/// ## 失败语义
///
/// 所有方法 catch 住异常并转成 [CapabilityFailure] —— **绝不把栈抛给 agent 循环**
/// （模型读不懂栈，只会原地重试）。理由见 `capabilities.dart` 约束 2。
library;

import 'dart:io';

// ★ 为什么必须带 `as git` 前缀（这不是风格问题，是编译必须）
//
// `git_dart` 有**顶层函数** `clone` / `fetch` / `push`，而本类实现
// `GitCapability` 时也有同名方法。不带前缀时，类内的方法名会遮蔽顶层函数，
//   `clone(url, path, credentials: ...)` 会被解析成 `this.clone(...)`
//   ⇒ 报 "Too many positional arguments" / "named parameter isn't defined"。
// 加前缀后两者泾渭分明：`git.clone(...)` 是库函数，`clone(...)` 是接口实现。
import 'package:git_dart/git_dart.dart' as git;
import 'package:heracles_backend/heracles_backend.dart';

/// 基于 `git_dart` 的 [GitCapability] 实现。
///
/// 无状态：每次操作现开现关 `Repository`。
///
/// ## 为什么不在内存里缓存 Repository
///
/// `Repository` 持有 index 与对象库的句柄。用户随时可能在别的 App 里
/// 改了文件、或（将来）有其他进程动了仓库 —— 长生命周期对象会读到陈旧
/// index。现开现关最稳，代价只有几十毫秒（Step 0 实测）。
class GitService implements GitCapability {
  const GitService({this.workspaceRoot = ''});

  /// **工作区根目录**（绝对路径，2026-10-28 补）。
  ///
  /// ## 为什么必须有它（真机发现的 bug）
  ///
  /// git 工具的 schema 写的是「仓库路径（**工作区相对路径**）」，模型因此传
  /// `"probe-repo"` 这种相对路径。但第一版把 `path` **原样**交给
  /// `git_dart` 的 `Repository.open()` —— 那是按**进程当前工作目录**解析的，
  /// 而 Android App 的 CWD 是 `/`，于是：
  ///
  /// ```
  /// 真机实测：git_status('probe-repo')
  ///   → Invalid argument (path): not inside a git repository: "probe-repo"
  /// ```
  ///
  /// 之前没暴露是因为两条路都碰巧传了绝对路径：
  /// · git 面板传 `ensureAppWorkspace()` 给的绝对路径；
  /// · Step 0/1 探针也传绝对路径。
  /// **只有模型按 schema 传相对路径时才会炸** —— 这正是"工具层必须真机验"的原因。
  ///
  /// ## 解析规则
  ///
  /// · 绝对路径（`/...` 或 `C:\...`）⇒ 原样用（UI 传的就是这种）
  /// · 相对路径 ⇒ 拼到 [workspaceRoot] 下
  /// · `workspaceRoot` 为空 ⇒ 原样传（宿主没配就自己承担后果，
  ///   但会在失败信息里看到原始路径，便于排查）
  final String workspaceRoot;

  /// 把工具/UI 给的路径解析成**进程可用的绝对路径**。
  String _resolve(String path) {
    if (path.isEmpty) return workspaceRoot;
    // Unix 绝对路径
    if (path.startsWith('/')) return path;
    // Windows 盘符（桌面端 dart test 会走到）
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) return path;
    if (workspaceRoot.isEmpty) return path;
    // 去掉可能的前导 './'
    final rel = path.startsWith('./') ? path.substring(2) : path;
    return '$workspaceRoot/$rel';
  }

  // ==========================================================================
  // 内部工具
  // ==========================================================================

  CapabilityFailure _fail(Object e, {bool retryable = false}) {
    final s = e.toString();
    final clipped = s.length > 300 ? '${s.substring(0, 300)}…' : s;
    return CapabilityFailure(clipped, isRetryable: retryable);
  }

  git.Repository _open(String path, {bool writable = true}) => git.Repository.open(
        _resolve(path),
        access: writable
            ? git.RepositoryAccess.full
            : git.RepositoryAccess.inspection,
      );

  /// 当前分支名（去掉 `refs/heads/` 前缀）。
  String _branchOf(git.Repository repo) {
    final raw = repo.refs.currentBranch; // "refs/heads/main"
    if (raw == null) return '(detached)';
    const prefix = 'refs/heads/';
    return raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
  }

  /// 构造 [Identity]。
  ///
  /// 时区固定 `+0000`：不把用户本地时区写进提交，避免「同一份代码在不同
  /// 时区产生不同 SHA」。代价是提交时间显示为 UTC，展示层要折算。
  git.Identity _identity({String? name, String? email}) => git.Identity(
        name: name ?? 'Heracles',
        email: email ?? 'heracles@local',
        seconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        timezone: '+0000',
      );

  String _fmtTime(int seconds) {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)} UTC';
  }

  /// `status` 的文本渲染（模型读的东西）。
  String _renderStatus(git.RepositoryStatus raw, String branch) {
    final buf = StringBuffer('分支：$branch\n');
    if (raw.entries.isEmpty) {
      buf.write('工作区干净，没有未提交的改动。');
      return buf.toString();
    }
    buf.writeln('改动 ${raw.entries.length} 项：');
    for (final e in raw.entries) {
      final marks = <String>[];
      if (e.isConflicted) marks.add('冲突');
      if (e.isUntracked) marks.add('未跟踪');
      if (e.staged != null) marks.add('已暂存(${e.staged!.name})');
      if (e.unstaged != null) marks.add('未暂存(${e.unstaged!.name})');
      final rename = e.oldPath == null ? '' : '  ← ${e.oldPath}';
      buf.writeln('- ${e.path}$rename  [${marks.join(' / ')}]');
    }
    return buf.toString().trimRight();
  }

  // ==========================================================================
  // 只读
  // ==========================================================================

  @override
  Future<bool> isRepository(String path) async {
    try {
      return git.Repository.discover(_resolve(path)) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<CapabilityResult> status(String path) async {
    git.Repository? repo;
    try {
      repo = _open(path, writable: false);
      final raw = repo.status();
      final branch = _branchOf(repo);
      final text = _renderStatus(raw, branch);
      return CapabilitySuccess(
        text,
        metadata: {
          'branch': branch,
          'dirty': raw.entries.isNotEmpty,
          'count': raw.entries.length,
        },
      );
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> log(
    String path, {
    int limit = ContractGit.defaultLogLimit,
    String? branch,
  }) async {
    git.Repository? repo;
    try {
      final clipped = limit.clamp(1, ContractGit.maxLogLimit);
      repo = _open(path, writable: false);
      final start = branch == null ? null : repo.resolve(branch);
      if (branch != null && start == null) {
        return CapabilityFailure('找不到分支或提交 `$branch`', isRetryable: true);
      }
      final commits = repo.log(start: start, limit: clipped).toList();
      if (commits.isEmpty) {
        return const CapabilitySuccess('这个仓库还没有任何提交。');
      }
      final buf = StringBuffer('最近 ${commits.length} 条提交（新 → 旧）：\n');
      for (final c in commits) {
        // 只要首行：长正文会把工具结果撑爆，需要全文走 showCommit
        final first = c.message.trim().split('\n').first;
        buf.writeln('- ${c.id.hex.substring(0, 7)}  '
            '${c.author.name}  ${_fmtTime(c.committer.seconds)}  $first');
      }
      return CapabilitySuccess(buf.toString().trimRight());
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> diff(
    String path, {
    bool staged = false,
    String? file,
  }) async {
    git.Repository? repo;
    try {
      repo = _open(path, writable: false);
      final raw = repo.status();
      // staged：HEAD↔index；否则 index↔工作区。
      // `status` 已经把两者分别标好了（staged / unstaged 字段），
      // 直接用它比再算一遍 diff 更省（Step 0 实测 status 只要 16ms）。
      final picked = <(String, git.ChangeKind?)>[
        for (final e in raw.entries)
          if (file == null || e.path == file)
            if (staged && e.staged != null) (e.path, e.staged)
            else if (!staged && e.unstaged != null) (e.path, e.unstaged),
      ];
      if (picked.isEmpty) {
        return CapabilitySuccess(staged ? '暂存区是空的。' : '工作区没有未暂存的改动。');
      }
      final buf = StringBuffer('${picked.length} 项改动：\n');
      for (final (p, kind) in picked) {
        buf.writeln('- ${(kind?.name ?? 'modified').toUpperCase()}  $p');
      }
      // 截断保护：真实 行级 diff 在 Step 2 接 UI 时补（git_dart 有
      // `diffBlobs`，需要按文件读 blob，等 UI 要展示时再加）。
      final text = buf.toString().trimRight();
      if (text.length > ContractGit.maxDiffChars) {
        return CapabilitySuccess(
          '${text.substring(0, ContractGit.maxDiffChars)}\n\n'
          '⚠️ 改动清单过长已截断。用 `file` 参数看单个文件。',
        );
      }
      return CapabilitySuccess(text);
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> branches(String path) async {
    git.Repository? repo;
    try {
      repo = _open(path, writable: false);
      final current = _branchOf(repo);
      // 本地分支
      // `refs.list()` 返回 `List<Ref>`（字段是 `.path`），不是字符串列表；
      // `refs.branches` 已经是 `refs/heads/` 前缀过滤好的。
      final names = <String>{...repo.refs.branches.map((r) => r.shortName)};
      // ★ 远端跟踪分支也列进来（2026-10-28 真机发现）
      //
      // `git clone` 只给**默认分支**建本地分支，其它分支（比如 dev）只存在于
      // `refs/remotes/origin/dev`。第一版只列 `refs/heads/` ⇒ 用户在
      // 「选择分支」里**看不到 dev**，以为仓库只有 main。
      //
      // 现在把远端跟踪分支也列出来（去掉 `origin/` 前缀、跳过 `HEAD`），
      // 选中它们时 `checkout` 会自动从远端建本地分支。
      for (final r in repo.refs.remoteBranches) {
        final short = r.shortName; // "origin/dev"
        final slash = short.indexOf('/');
        if (slash < 0) continue;
        final name = short.substring(slash + 1);
        if (name == 'HEAD' || name.isEmpty) continue;
        names.add(name);
      }
      final locals = names.toList()..sort();
      if (locals.isEmpty) {
        return const CapabilitySuccess('这个仓库还没有任何分支（还没有提交）。');
      }
      final buf = StringBuffer('本地分支（${locals.length} 个）：\n');
      for (final b in locals) {
        buf.writeln('- $b${b == current ? '  ← 当前' : ''}');
      }
      return CapabilitySuccess(buf.toString().trimRight());
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> showCommit(String path, {required String id}) async {
    git.Repository? repo;
    try {
      repo = _open(path, writable: false);
      final oid = repo.resolve(id);
      if (oid == null) {
        return CapabilityFailure('找不到提交 `$id`（仓库里没有这个 id）',
            isRetryable: true);
      }
      final obj = repo.peel(oid);
      if (obj is! git.Commit) {
        return CapabilityFailure('`$id` 不是一次提交');
      }
      return CapabilitySuccess(
        '提交 ${obj.id.hex}\n'
        '作者 ${obj.author.name} <${obj.author.email}>\n'
        '时间 ${_fmtTime(obj.committer.seconds)}\n\n'
        '${obj.message.trimRight()}',
      );
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  // ==========================================================================
  // 改本仓库
  // ==========================================================================

  @override
  Future<CapabilityResult> init(String path,
      {String defaultBranch = 'main'}) async {
    try {
      final target = _resolve(path);
      if (!Directory(target).existsSync()) {
        return CapabilityFailure('目录不存在：$path', isRetryable: true);
      }
      if (Directory('$path/.git').existsSync()) {
        return const CapabilityFailure('这个目录已经是一个 git 仓库了');
      }
      git.Repository.init(target, defaultBranch: defaultBranch);
      return CapabilitySuccess(
        '已初始化 git 仓库（默认分支 `$defaultBranch`）。'
        '接下来可以用 `git_stage` + `git_commit` 把现有文件提交进去。',
      );
    } catch (e) {
      return _fail(e);
    }
  }

  @override
  Future<CapabilityResult> stage(String path,
      {List<String> paths = const []}) async {
    git.Repository? repo;
    try {
      repo = _open(path);
      if (paths.isEmpty) {
        // 暂存全部：先按 status 拿清单（含未跟踪），逐个 stage
        final raw = repo.status();
        if (raw.entries.isEmpty) {
          return const CapabilitySuccess('没有需要暂存的改动。');
        }
        for (final e in raw.entries) {
          repo.stage(e.path);
        }
      } else {
        for (final p in paths) {
          repo.stage(p);
        }
      }
      final after = repo.status();
      final n = after.entries.where((e) => e.staged != null).length;
      return CapabilitySuccess('已暂存，当前暂存区 $n 项改动，可以提交了。');
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> unstage(String path,
      {List<String> paths = const []}) async {
    git.Repository? repo;
    try {
      repo = _open(path);
      if (repo.resolve('HEAD') == null) {
        return const CapabilityFailure(
            '这个仓库还没有提交，暂存区没法取消（没有 HEAD 可回退）');
      }
      if (paths.isEmpty) {
        // 全部取消：按 status 找出已暂存的逐个 unstage
        final raw = repo.status();
        final staged = raw.entries.where((e) => e.staged != null).toList();
        if (staged.isEmpty) {
          return const CapabilitySuccess('暂存区本来就是空的。');
        }
        for (final e in staged) {
          repo.unstage(e.path);
        }
        return CapabilitySuccess('已取消全部暂存（${staged.length} 项，工作区文件未变）。');
      }
      for (final p in paths) {
        repo.unstage(p);
      }
      return CapabilitySuccess('已取消暂存：${paths.join('、')}');
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> commit(
    String path, {
    required String message,
    String? authorName,
    String? authorEmail,
  }) async {
    git.Repository? repo;
    try {
      final msg = message.trim();
      if (msg.isEmpty) {
        return const CapabilityFailure('提交信息不能为空 —— 写一句"这次改了什么"',
            isRetryable: true);
      }
      repo = _open(path);
      final raw = repo.status();
      final staged = raw.entries.where((e) => e.staged != null).toList();
      if (staged.isEmpty) {
        return const CapabilityFailure(
          '暂存区是空的，没有东西可提交。先用 `git_stage` 把改动加上。',
          isRetryable: true,
        );
      }
      final ident = _identity(name: authorName, email: authorEmail);
      final id = repo.commitIndex(
        message: msg,
        author: ident,
        committer: ident,
      );
      final first = msg.split('\n').first;
      final warn = first.length > ContractGit.recommendedMessageChars
          ? '\n（提示：首行 ${first.length} 字符，超过建议的 '
              '${ContractGit.recommendedMessageChars}；`git log --oneline` 会折行）'
          : '';
      return CapabilitySuccess(
        '已提交 ${staged.length} 项改动。\n'
        '提交 ${id.hex.substring(0, 7)}：$first$warn',
        metadata: {'id': id.hex, 'count': staged.length},
      );
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  @override
  Future<CapabilityResult> checkout(
    String path, {
    required String branch,
    bool create = false,
  }) async {
    git.Repository? repo;
    try {
      repo = _open(path);
      if (!create) {
        // 有未提交改动时**不强切**：覆盖用户正在编辑的文件不可接受。
        final raw = repo.status();
        if (raw.entries.isNotEmpty) {
          return CapabilityFailure(
            '有未提交的改动（${raw.entries.length} 项），不能直接切换分支。'
            '先提交或取消这些改动，再切分支。',
            isRetryable: true,
          );
        }
        // ★ 本地没有这个分支、但远端有 ⇒ 从远端跟踪分支建一个本地分支
        //   （`git checkout dev` 的语义：自动建立跟踪）
        if (repo.resolve('refs/heads/$branch') == null) {
          final remoteRef = repo.resolve('refs/remotes/origin/$branch');
          if (remoteRef != null) {
            repo.createBranch(branch, at: remoteRef);
          }
        }
      }
      final problem = git.Repository.branchNameProblem(branch);
      if (problem != null) {
        return CapabilityFailure('分支名不合法：$problem', isRetryable: true);
      }
      if (create) repo.createBranch(branch);
      // 注意：`checkout` 的第一个参数是**位置参数** `revision`，
      // 不是命名参数（这个包没有 `checkout(ref:)` 这种写法）。
      repo.checkout('refs/heads/$branch');
      return CapabilitySuccess(
          create ? '已创建并切换到分支 `$branch`。' : '已切换到分支 `$branch`。');
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  // ==========================================================================
  // 远程（HTTPS only）
  // ==========================================================================

  /// `clone` 是**顶层函数**（不是 Repository 方法）—— 见文件头「API 形状」。
  @override
  Future<CapabilityResult> clone({
    required String url,
    required String destPath,
    String? token,
    int? depth,
    void Function(String message)? onProgress,
  }) async {
    try {
      if (!url.startsWith('https://')) {
        return const CapabilityFailure(
          '只支持 HTTPS 克隆。设备上没有 ssh，SSH 地址（git@github.com:...）用不了；'
          '请改用 `https://github.com/用户/仓库.git`。',
          isRetryable: true,
        );
      }
      final destPathAbs = _resolve(destPath);
      final dest = Directory(destPathAbs);
      if (dest.existsSync() && dest.listSync().isNotEmpty) {
        return CapabilityFailure('目标目录已存在且非空：$destPath（克隆要求空目录）');
      }
      final result = await git.clone(
        url,
        destPathAbs,
        credentials: token == null
            ? null
            : git.Credentials(username: 'x-access-token', password: token),
        depth: depth,
        onProgress: onProgress,
      );
      return CapabilitySuccess(
        '已克隆到 ${result.path}，收到 ${result.objectsReceived} 个对象。'
        '${depth == null ? '' : '（浅克隆，深度 $depth，历史不完整）'}',
        metadata: {'path': result.path, 'objects': result.objectsReceived},
      );
    } catch (e) {
      return _fail(e);
    }
  }

  @override
  Future<CapabilityResult> fetch(String path, {String? token}) async {
    git.Repository? repo;
    try {
      repo = _open(path);
      final remote = repo.remotes.named('origin');
      if (remote == null) {
        return const CapabilityFailure(
            '这个仓库没有配置 `origin` 远端。先加上远端地址再拉取。');
      }
      final r = await git.fetch(
        repo,
        remote,
        credentials: token == null
            ? null
            : git.Credentials(username: 'x-access-token', password: token),
      );
      // FetchResult 的字段是 `updates`（List<RefUpdate>），不是 `updated`。
      return CapabilitySuccess(
        '已从 origin 拉取远端更新（未合并到当前分支）。'
        '${r.updates.isEmpty ? '远端没有新内容。' : '更新了 ${r.updates.length} 个引用，'
            '收到 ${r.objectsReceived} 个对象。'}',
      );
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  /// `git_dart` **没有 pull** —— 自己组合 fetch + 快进。
  ///
  /// 只做 **fast-forward**：非快进的情况（本地有分叉提交）如实失败并
  /// 告诉模型"需要先处理分叉"，**不自动 merge** —— 手机上自动合并产出的
  /// 冲突态用户很难收拾，而这正是 git 最容易把人坑住的地方。
  @override
  Future<CapabilityResult> pull(String path, {String? token}) async {
    git.Repository? repo;
    try {
      repo = _open(path);
      final remote = repo.remotes.named('origin');
      if (remote == null) {
        return const CapabilityFailure('这个仓库没有配置 `origin` 远端。');
      }
      final branch = _branchOf(repo);
      if (branch.startsWith('(')) {
        return const CapabilityFailure('当前是分离 HEAD 状态，无法拉取。');
      }
      await git.fetch(
        repo,
        remote,
        credentials: token == null
            ? null
            : git.Credentials(username: 'x-access-token', password: token),
      );
      final remoteRef = repo.resolve('refs/remotes/origin/$branch');
      if (remoteRef == null) {
        return CapabilityFailure(
            '远端没有 `origin/$branch` 分支（这个分支可能还没推过）。');
      }
      final head = repo.resolve('HEAD');
      if (head == remoteRef) {
        return const CapabilitySuccess('已经是最新的，没有需要合并的内容。');
      }
      // 快进：HEAD 必须是 remoteRef 的祖先
      if (!_isAncestor(repo, head!, remoteRef)) {
        return const CapabilityFailure(
          '本地有远端没有的提交（历史分叉），不能直接快进。'
          '需要你先决定怎么处理（合并/变基），我不擅自做 —— '
          '手机上自动合并产生冲突很难收拾。',
          isRetryable: false,
        );
      }
      // ⚠️ `reset` 是**顶层函数**，不是 Repository 方法（与 clone/fetch/push 同类）。
      git.reset(repo, remoteRef, mode: git.ResetMode.hard);
      return CapabilitySuccess('已拉取并快进到 origin/$branch。');
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }

  bool _isAncestor(git.Repository repo, git.ObjectId maybeAncestor, git.ObjectId of) {
    // 沿着 of 的父链往上找，看能不能碰到 maybeAncestor。
    final seen = <git.ObjectId>{};
    final queue = <git.ObjectId>[of];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      if (cur == maybeAncestor) return true;
      if (!seen.add(cur)) continue;
      final obj = repo.peel(cur);
      if (obj is git.Commit) queue.addAll(obj.parents);
    }
    return false;
  }

  @override
  Future<CapabilityResult> push(
    String path, {
    String? token,
    bool setUpstream = false,
  }) async {
    git.Repository? repo;
    try {
      repo = _open(path);
      final remote = repo.remotes.named('origin');
      if (remote == null) {
        return const CapabilityFailure('这个仓库没有配置 `origin` 远端。');
      }
      final branch = _branchOf(repo);
      if (branch.startsWith('(')) {
        return const CapabilityFailure('当前是分离 HEAD 状态，无法推送。');
      }
      final r = await git.push(
        repo,
        remote,
        branches: [branch],
        credentials: token == null
            ? null
            : git.Credentials(username: 'x-access-token', password: token),
      );
      if (!r.ok) {
        final rejected = r.rejected.map((s) => s.ref).join('、');
        return CapabilityFailure(
          '推送被拒绝：$rejected。通常是远端有你本地没有的提交 —— '
          '先 `git_pull` 再推。',
          isRetryable: true,
        );
      }
      if (setUpstream) {
        repo.setUpstream(branch, 'origin', 'refs/heads/$branch');
      }
      return CapabilitySuccess(
        '已推送分支 `$branch`'
        '${r.objectsSent > 0 ? '（${r.objectsSent} 个对象）' : '（已是最新）'}。',
      );
    } catch (e) {
      return _fail(e);
    } finally {
      repo?.close();
    }
  }
}
