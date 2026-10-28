/// **能力装配完整性测试**（2026-10-28）。
///
/// ## 为什么必须有这个文件
///
/// 2026-10-27 我加了 `Capabilities.git` 字段、写了 11 个 git 工具、
/// 30 条工具测试全绿 —— 但**宿主根本没有注入实现**：
///
/// ```dart
/// // app/lib/services/device_capabilities.dart（修复前）
/// return Capabilities(
///   workspace: ...,
///   shell: ...,
///   apk: ...,
///   web: ...,
///   memory: ...,
///   // ❌ 没有 git
/// );
/// ```
///
/// 后果：11 个 git 工具在模型眼里**都在**（工具列表是 `_buildTools` 造的，
/// 与能力无关），但一调用就返回「当前环境不支持 git」。
///
/// ## 为什么单测抓不到（这是本文件存在的理由）
///
/// `backend/test/git_tools_test.dart` 自己 new 了一个 `_RecordingGit()`
/// 塞进 `Capabilities` —— 它验的是"工具有没有正确调用能力层"，
/// **不是"宿主有没有把能力接上"**。这两件事之间有一条缝，
/// 而 bug 正好掉在缝里（真机实测：底部有「连接 Github」，git 工具却全废）。
///
/// ⇒ 这里直接测**装配函数**本身：`buildDeviceCapabilities()` 必须交出 git。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:heracles/services/device_capabilities.dart';

void main() {
  group('★ buildDeviceCapabilities 必须把 git 接上（防"装配漏接"回归）', () {
    test('★★★ 默认参数下 caps.git 非空', () {
      final caps = buildDeviceCapabilities(workspaceRoot: '/tmp/ws');
      expect(
        caps.git,
        isNotNull,
        reason: '★ 这是 2026-10-27 的真实 bug：字段加了、工具写了、'
            '但宿主忘了注入 ⇒ 11 个 git 工具全部不可用。'
            '这条断言就是防止它再发生。',
      );
    });

    test('★★ git 是 GitCapability 的实现（不是别的类型）', () {
      final caps = buildDeviceCapabilities(workspaceRoot: '/tmp/ws');
      expect(caps.git, isA<GitCapability>());
    });

    test('★ 显式关掉（includeGit: false）时才是 null', () {
      final caps = buildDeviceCapabilities(
        workspaceRoot: '/tmp/ws',
        includeGit: false,
      );
      expect(caps.git, isNull,
          reason: '有了显式开关，null 才是一种"故意的选择"而不是"忘了"');
    });

    test('★★ 其余能力不被 git 的加入影响（回归保护）', () {
      final caps = buildDeviceCapabilities(workspaceRoot: '/tmp/ws');
      // 这几个必须还在 —— 加字段时最怕顺手改坏别的槽位
      expect(caps.workspace, isNotNull);
      expect(caps.shell, isNotNull);
      expect(caps.deviceHealth, isNotNull);
      expect(caps.apk, isNotNull);
      expect(caps.web, isNotNull);
      expect(caps.memory, isNotNull);
      expect(caps.git, isNotNull);
    });

    test('★ git 的 null 语义：工具"可见但调用即失败"', () async {
      // 装配层的责任只是"传进去"；这里再确认一遍 null 的后果，
      // 让"为什么不能忘"这件事在测试里可读。
      const caps = Capabilities();
      final tools = buildGitTools(ToolFactory(caps), caps);
      expect(tools, hasLength(11),
          reason: '工具始终会被列出来（否则模型凭记忆乱调，报"未知工具"）');

      final status = tools.firstWhere((t) => t.name == 'git_status');
      final r = await status.executable!(<String, dynamic>{});
      expect(r as String, contains('不支持'));
    });
  });
}
