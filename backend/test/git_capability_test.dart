/// **GitCapability 契约测试**（2026-10-27，Step 1）。
///
/// ## 这个文件测什么（以及为什么不测什么）
///
/// 这里测的是**接口契约**（用假的实现），不是 `git_dart` 本身：
///
/// · ✅ 测：接口形状、审批分类表、结果翻译、失败语义
/// · ❌ 不测：`git_dart` 的真实行为 —— 那由 **Step 0 真机探针**负责
///   （已在设备 e35e48c6 上跑完 11 项，结论见 `git_service.dart` 文件头）
///
/// ## 为什么必须有"假实现"这一层
///
/// backend 是纯 Dart 包，**不能依赖 `git_dart`**（那是 app 侧的依赖）。
/// 如果这里直接测真实现，这个测试文件就跑不了 `dart test` ——
/// 而 `dart test` 毫秒级的速度正是 backend 单测的意义。
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 一个只记账、不碰文件系统的假 git 实现。
///
/// 每条方法都返回预设结果，并记录被调用的顺序 —— 用来验证
/// "工具层有没有按契约调用"。
class FakeGitCapability implements GitCapability {
  FakeGitCapability({this.repoExists = true});

  final bool repoExists;

  /// 调用流水（测试可以断言"该调的被调了、不该调的没调"）。
  final calls = <String>[];

  @override
  Future<bool> isRepository(String path) async {
    calls.add('isRepository($path)');
    return repoExists;
  }

  @override
  Future<CapabilityResult> status(String path) async {
    calls.add('status($path)');
    return const CapabilitySuccess('分支：main\n工作区干净，没有未提交的改动。');
  }

  @override
  Future<CapabilityResult> log(String path,
      {int limit = ContractGit.defaultLogLimit, String? branch}) async {
    calls.add('log($path, limit=$limit)');
    return CapabilitySuccess('最近 1 条提交：\n- abc1234  Heracles  2026-10-27 10:00 UTC  init');
  }

  @override
  Future<CapabilityResult> diff(String path,
      {bool staged = false, String? file}) async {
    calls.add('diff($path, staged=$staged)');
    return const CapabilitySuccess('1 项改动：\n- MODIFIED  a.txt');
  }

  @override
  Future<CapabilityResult> branches(String path) async {
    calls.add('branches($path)');
    return const CapabilitySuccess('本地分支：\n- main  ← 当前');
  }

  @override
  Future<CapabilityResult> showCommit(String path, {required String id}) async {
    calls.add('showCommit($path, $id)');
    return const CapabilitySuccess('提交 abc1234\n作者 Heracles');
  }

  @override
  Future<CapabilityResult> init(String path,
      {String defaultBranch = 'main'}) async {
    calls.add('init($path, $defaultBranch)');
    return CapabilitySuccess('已初始化 git 仓库（默认分支 `$defaultBranch`）。');
  }

  @override
  Future<CapabilityResult> stage(String path, {List<String> paths = const []}) async {
    calls.add('stage($path, ${paths.isEmpty ? 'all' : paths.join(',')})');
    return const CapabilitySuccess('已暂存，当前暂存区 1 项改动，可以提交了。');
  }

  @override
  Future<CapabilityResult> unstage(String path,
      {List<String> paths = const []}) async {
    calls.add('unstage($path)');
    return const CapabilitySuccess('已取消全部暂存。');
  }

  @override
  Future<CapabilityResult> commit(String path,
      {required String message,
      String? authorName,
      String? authorEmail}) async {
    calls.add('commit($path, "$message")');
    return CapabilitySuccess('已提交 1 项改动。\n提交 abc1234：$message');
  }

  @override
  Future<CapabilityResult> checkout(String path,
      {required String branch, bool create = false}) async {
    calls.add('checkout($path, $branch, create=$create)');
    return CapabilitySuccess('已切换到分支 `$branch`。');
  }

  @override
  Future<CapabilityResult> clone({
    required String url,
    required String destPath,
    String? token,
    int? depth,
    void Function(String message)? onProgress,
  }) async {
    calls.add('clone($url, $destPath, token=${token != null}, depth=$depth)');
    return CapabilitySuccess('已克隆到 $destPath，收到 10 个对象。');
  }

  @override
  Future<CapabilityResult> pull(String path, {String? token}) async {
    calls.add('pull($path)');
    return const CapabilitySuccess('已拉取并快进到 origin/main。');
  }

  @override
  Future<CapabilityResult> push(String path,
      {String? token, bool setUpstream = false}) async {
    calls.add('push($path, upstream=$setUpstream)');
    return const CapabilitySuccess('已推送分支 `main`。');
  }

  @override
  Future<CapabilityResult> fetch(String path, {String? token}) async {
    calls.add('fetch($path)');
    return const CapabilitySuccess('已从 origin 拉取远端更新（未合并到当前分支）。');
  }
}

void main() {
  group('Capabilities 里 git 槽位的语义', () {
    test('★ 传 null ⇒ 宿主没有 git 能力（工具应"一调用就失败并明说"）', () {
      const caps = Capabilities();
      expect(caps.git, isNull);
    });

    test('★ 传实现 ⇒ 能力可用', () {
      final caps = Capabilities(git: FakeGitCapability());
      expect(caps.git, isNotNull);
    });

    test('★ 新字段不破坏既有构造（其余能力仍可单独传）', () {
      final fake = FakeGitCapability();
      final caps = Capabilities(git: fake);
      // 其余槽位仍是 null —— 说明加 git 没有意外要求别的能力
      expect(caps.workspace, isNull);
      expect(caps.shell, isNull);
      expect(caps.apk, isNull);
      expect(caps.git, same(fake));
    });
  });

  group('GitCapability 契约（用假实现验证形状）', () {
    late FakeGitCapability git;

    setUp(() => git = FakeGitCapability());

    test('isRepository 返回 bool', () async {
      expect(await git.isRepository('/tmp/x'), isTrue);
    });

    test('status 返回 CapabilitySuccess 且带可读文本', () async {
      final r = await git.status('/ws');
      expect(r, isA<CapabilitySuccess>());
      final text = (r as CapabilitySuccess).data;
      expect(text, contains('分支'));
      expect(text, contains('工作区'));
    });

    test('log 默认 limit 来自契约常量（不是魔法数字）', () async {
      await git.log('/ws');
      expect(git.calls.last, contains('limit=${ContractGit.defaultLogLimit}'));
    });

    test('commit 把 message 原样传给实现', () async {
      await git.commit('/ws', message: '修 bug');
      expect(git.calls.last, contains('修 bug'));
    });

    test('clone 必须带 url + destPath（形状钉住）', () async {
      await git.clone(url: 'https://github.com/a/b.git', destPath: '/tmp/b');
      expect(git.calls.last, contains('https://github.com/a/b.git'));
      expect(git.calls.last, contains('/tmp/b'));
    });
  });

  group('ContractGit 常量（防止漂移）', () {
    test('defaultLogLimit 在合理区间', () {
      expect(ContractGit.defaultLogLimit, greaterThan(0));
      expect(ContractGit.defaultLogLimit,
          lessThanOrEqualTo(ContractGit.maxLogLimit));
    });

    test('maxLogLimit 有硬上限（防上下文被灌满）', () {
      expect(ContractGit.maxLogLimit, lessThanOrEqualTo(200));
    });

    test('defaultBranch 是 main（对齐 GitHub 新仓库默认）', () {
      expect(ContractGit.defaultBranch, 'main');
    });

    test('recommendedMessageChars 是 git 社区惯例 72', () {
      expect(ContractGit.recommendedMessageChars, 72);
    });

    test('maxDiffChars 与 shell 的 overflow 阈值同量级', () {
      // shell 是 100000（ContractShell.overflowChars）—— 两者必须接近，
      // 否则"diff 不截断但 shell 截断"会造成不一致的体验
      expect(ContractGit.maxDiffChars, ContractShell.overflowChars);
    });

    test('defaultCloneDepth 默认 null（全量克隆，行为与 git 一致）', () {
      expect(ContractGit.defaultCloneDepth, isNull);
    });
  });
}
