import 'dart:io';

import 'package:heracles_backend/heracles_backend.dart';
import 'package:heracles_backend/src/capability/process_shell_capability.dart';
import 'package:test/test.dart';

/// **shell 能力门禁** —— 三条产品红线的可执行版本。
///
/// 1. **内置命令守卫**（`kill` / `am force-stop` / `pm uninstall` …）
///    —— 2026-10-09 真实事故：误杀了用户的监控 App。
///    AGENTS.md 的硬约束，**不许有"记住我的选择"**。
/// 2. **退出码如实回告** —— 非 0 不许当成功（模型会据此判断"构建成功了"）。
/// 3. **超时只杀自己起的那个进程** —— 绝不按名字找进程。
///
/// ## 它顺带钉住的编译期问题
///
/// `ProcessShellCapability.run` 的默认超时是
/// `const Duration(seconds: ContractShell.defaultTimeoutSeconds)` ——
/// **const 位置引用契约常量**。这在旧写法（`Contract.Shell.…` 嵌在类里）
/// 直接 `invalid_constant` / `const_eval_throws_exception`：
/// 常量根本不存在，const 求值时抛异常。现在常量是顶层类的 `static const`，
/// const 求值正常。下面的 `const` 声明就是那个回归锁。
void main() {
  // ⚠️ 这行本身**就是测试**：它在编译期求值。
  // 旧写法下这里编译不过（`Contract.Shell` 不存在 ⇒ 常量求值抛异常）。
  const defaultShellTimeout = Duration(seconds: ContractShell.defaultTimeoutSeconds);

  group('const 上下文能引用契约常量（旧写法下 compile error）', () {
    test('★★★ Duration 可以在 const 位置用契约常量', () {
      expect(defaultShellTimeout, const Duration(minutes: 5));
      expect(defaultShellTimeout.inSeconds, 300);
    });

    test('★★★ RunOptions 的 const 构造能求值（heracles_agent.dart:134 那条）', () {
      // 旧代码 `RunOptions options = const RunOptions()` 里的默认值引用
      // `Contract.Agent.maxTurns` —— 那个 getter 不存在 ⇒ 默认值退化成 null
      // ⇒ `const_constructor_param_type_mismatch`（Null 不能赋给 int）。
      const options = RunOptions();
      expect(options.maxTurns, ContractAgent.maxTurns);
      expect(options.maxToolCalls, ContractAgent.maxToolCalls);
      expect(options.enablePlan, isTrue);
      expect(options.systemPrompts, isEmpty);
    });

    test('★★★ BackendConfig 的 const 构造能求值（默认值全来自契约）', () {
      const cfg = BackendConfig(apiKey: 'k', modelName: 'm');
      expect(cfg.baseUrl, ContractModel.defaultBaseUrl);
      expect(cfg.modelWindowTokens, ContractModel.defaultWindowTokens);
      expect(cfg.maxOutputTokens, ContractModel.maxOutputTokens);
      expect(cfg.temperature, isNull);
      expect(cfg.summarizerModel, isNull);
    });

    test('★★ BackendConfig 显式传值时不被默认值覆盖', () {
      const cfg = BackendConfig(
        apiKey: 'k',
        modelName: 'm',
        baseUrl: 'https://relay.example',
        modelWindowTokens: 8192,
        maxOutputTokens: 2048,
      );
      expect(cfg.baseUrl, 'https://relay.example');
      expect(cfg.modelWindowTokens, 8192);
      expect(cfg.maxOutputTokens, 2048);
    });
  });

  group('命令守卫 —— 产品硬约束（2026-10-09 事故）', () {
    /// 每一条都必须被拦。
    const blocked = [
      'kill 1234',
      'killall foo',
      'pkill bar',
      'am force-stop com.example.app',
      'am kill com.example.app',
      'pm uninstall com.example.app',
      'pm clear com.example.app',
      'pm disable com.example.app',
      // 混在复合命令里的也要拦住
      'echo hi; kill 1234',
      'echo hi && pkill x',
      'sudo kill -9 1',
    ];

    test('★★★ 这些命令一条都不许执行', () {
      for (final cmd in blocked) {
        final v = ProcessShellCapability.checkCommand(cmd);
        expect(v.blocked, isTrue, reason: '必须拦住：$cmd');
        expect(v.reason, isNotNull, reason: '拦住必须给原因：$cmd');
        expect(v.reason, contains('产品硬约束'), reason: '原因要点明这是产品约束：$cmd');
      }
    });

    test('★★★ 大小写不敏感（`KILL` / `Am Force-Stop` 同样拦）', () {
      expect(ProcessShellCapability.checkCommand('KILL 1').blocked, isTrue);
      expect(
          ProcessShellCapability.checkCommand('Am Force-Stop com.x').blocked, isTrue);
      expect(ProcessShellCapability.checkCommand('PM UNINSTALL com.x').blocked,
          isTrue);
    });

    test('★★★ 正常命令不许误伤（误拦 = 模型干不了活）', () {
      const allowed = [
        'ls -la',
        'cat a.txt',
        'gradlew.bat check',
        'git status',
        'echo "kill switch" > a.txt', // 有 kill 这个词但不是一个 kill 命令
        'grep -r "pkill" .',          // 同上
        'npm run build',
        'python x.py',
      ];
      for (final cmd in allowed) {
        expect(ProcessShellCapability.checkCommand(cmd).blocked, isFalse,
            reason: '不该误拦：$cmd');
      }
    });
  });

  group('真实执行（本机 shell）', () {
    late Directory tmp;
    late ProcessShellCapability shell;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('heracles_shell_test_');
      shell = ProcessShellCapability(tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('★★★ 正常命令：退出码 0、输出回得来', () async {
      final r = await shell.run(
        Platform.isWindows ? 'echo hello-heracles' : 'echo hello-heracles',
      );
      expect(r, isA<CapabilitySuccess>());
      final data = (r as CapabilitySuccess).data;
      expect(data, contains('hello-heracles'));
      expect(r.metadata?['exitCode'], 0);
    });

    test('★★★ 非 0 退出码必须如实报（不许当成功悄悄咽下）', () async {
      final r = await shell.run(
        Platform.isWindows ? 'exit /b 3' : 'exit 3',
      );
      // 这是本实现的关键取舍：**退出码非 0 仍是 CapabilitySuccess**
      // （命令跑通了，只是它自己失败了），但正文里必须写清退出码 ——
      // 因为模型会读正文判断"构建到底成没成"。
      expect(r, isA<CapabilitySuccess>());
      final success = r as CapabilitySuccess;
      expect(success.data, contains('退出码：3'),
          reason: '必须把真实退出码写给模型看');
      expect(success.metadata?['exitCode'], 3);
    });

    test('★★★ 被守卫拦的命令：一次都不执行，且说清原因', () async {
      final r = await shell.run('kill 1');
      expect(r, isA<CapabilityFailure>());
      final failure = r as CapabilityFailure;
      expect(failure.reason, contains('产品硬约束'));
      expect(failure.reason, contains('kill'),
          reason: '要点名是哪条命令被拦了');
      expect(failure.isRetryable, isFalse,
          reason: '这条路彻底不通，别让模型重试');
    });

    test('★★ 空命令 ⇒ 失败（不是"跑了个空 shell"）', () async {
      final r = await shell.run('   ');
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('命令为空'));
    });

    test('★★ 工作目录不存在 ⇒ 失败并说明（不静默用别的目录）', () async {
      final bad = ProcessShellCapability('${tmp.path}/definitely-not-here');
      final r = await bad.run('echo x');
      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('工作目录不存在'));
    });

    test('★★ 命令在指定工作目录里跑（cwd 不能是进程的 CWD）', () async {
      await File('${tmp.path}${Platform.pathSeparator}marker.txt')
          .writeAsString('here');

      final r = await shell.run(
        Platform.isWindows ? 'dir /b marker.txt' : 'cat marker.txt',
      );
      expect(r, isA<CapabilitySuccess>());
      expect((r as CapabilitySuccess).data, contains('marker'),
          reason: '命令必须在 shell 的工作目录里跑');
    });

    test('★★ 超时能被中止，且明确说"只杀了自己起的进程"', () async {
      // 让命令睡 10 秒，超时 300ms ⇒ 必然超时
      final r = await shell.run(
        Platform.isWindows ? 'ping -n 10 127.0.0.1 > nul' : 'sleep 10',
        timeout: const Duration(milliseconds: 300),
      );

      expect(r, isA<CapabilityFailure>(), reason: '超时要报失败，不能报成功');
      final reason = (r as CapabilityFailure).reason;
      expect(reason, contains('超时'));
      expect(reason, contains('本命令自己启动的进程'),
          reason: '必须说清只杀了自己的进程（产品硬约束）');
    });
  });
}
