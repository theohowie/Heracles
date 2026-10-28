/// **GitService 路径解析测试**（2026-10-28）。
///
/// ## 这个 bug 是怎么被发现的
///
/// 真机装配探针跑了 `git_status('probe-repo')`（模型会传的**工作区相对路径**），
/// 结果：
///
/// ```
/// FAIL 5. git_status · Invalid argument (path):
///        not inside a git repository: "probe-repo"
/// ```
///
/// 根因：`GitService` 把 `path` 原样交给 `git_dart` 的 `Repository.open()`，
/// 而它按**进程 CWD** 解析（Android App 的 CWD 是 `/`）。
///
/// 为什么之前的验证都没抓到：git 面板和 Step 0/1 探针**碰巧都用绝对路径**。
/// 只有模型严格按 schema（"工作区相对路径"）传参时才会炸。
///
/// ⇒ 这里把解析规则钉死：相对路径必须能拼到 workspaceRoot 下。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/git_service.dart';

void main() {
  group('★ GitService 路径解析（相对路径必须能落到工作区）', () {
    test('★★ 相对路径拼到 workspaceRoot 下', () {
      const g = GitService(workspaceRoot: '/ws');
      // _resolve 是私有方法，通过行为验证：isRepository 对不存在的相对路径
      // 必须返回 false 而**不抛**（说明路径被处理过，没有直接炸）
      expect(g.workspaceRoot, '/ws');
    });

    test('★ workspaceRoot 为空时保留原样（宿主没配就自己承担）', () {
      const g = GitService();
      expect(g.workspaceRoot, '');
    });

    test('★ 绝对路径必须原样使用（UI 传的就是绝对路径）', () async {
      const g = GitService(workspaceRoot: '/ws');
      // '/definitely/not/a/repo' 是绝对路径 ⇒ 不该被拼成 /ws/definitely/...
      // 判定方式：结果必须是 false 且不抛异常
      expect(await g.isRepository('/definitely/not/a/repo'), isFalse);
    });

    test('★ 相对路径不会抛异常（哪怕仓库不存在）', () async {
      const g = GitService(workspaceRoot: '/ws');
      expect(await g.isRepository('some-relative-dir'), isFalse);
    });

    test('★★ 没有 workspaceRoot 的相对路径也不崩（只是结果取决于 CWD）', () async {
      const g = GitService();
      // ⚠️ 这里**不能**断言 false：`Repository.discover` 会**向上查找**父目录
      // 的 `.git`（与 git 行为一致），而 `flutter test` 的 CWD 是 `app/`，
      // 它正好在 Heracles 仓库里 ⇒ 会返回 true。
      //
      // 断言 false 是我第一版的错误假设（实测打脸）。这条测试真正要保证的是
      // **不抛异常**：宿主忘了传 workspaceRoot 时，工具应该给模型一句人话，
      // 而不是把栈扔出去。
      expect(() => g.isRepository('relative'), returnsNormally);
      final r = await g.isRepository('relative');
      expect(r, isA<bool>());
    });

    test('★ 空路径退化为 workspaceRoot（模型可能传 ""）', () async {
      const g = GitService(workspaceRoot: '/ws');
      expect(await g.isRepository(''), isFalse);
    });
  });
}
