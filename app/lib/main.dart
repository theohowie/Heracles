import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/settings.dart';
import 'screens/chat_screen.dart';
import 'services/sandbox_service.dart';
import 'services/settings_controller.dart';
import 'theme/app_theme.dart';
import 'theme/theme_reveal.dart';

/// Heracles —— 手机上的开发智能体。
///
/// ## 架构分层（`16-Android兼容性验证.md` §4.1）
///
/// ```
/// Flutter UI（本层，Dart）        只做展示与输入
///        ↕ Platform Channel
/// :app（Kotlin，Android）         平台集成
///        ↕
/// :agent / :core / :provider-http / :workspace
///   ★ 已验证的核心（66 项测试 + 实测 06/07/08/09/10）
/// ```
///
/// **核心逻辑不得用 Dart 重写** —— 它们是已验证的资产，
/// 且缓存纪律（铁律 1）在 Kotlin 层由**类型**保障（`Session` 只暴露 `append`）。
Future<void> main() async {
  // ★ 仅当用 --dart-define=SANDBOX_SELFTEST=true 构建时执行：
  //   走完整的 Dart → MethodChannel → Kotlin SandboxBridge → PRoot 链路，
  //   结果打到 logcat（flutter 标签）。用来取「真的通了」的证据。
  //   release 默认构建不带这个 define，用户路径零影响。
  const bool runSelfTest = bool.fromEnvironment("SANDBOX_SELFTEST");
  WidgetsFlutterBinding.ensureInitialized();

  // 设置必须在 runApp 之前加载 —— 否则首帧会用默认主题再闪一下
  final settings = await SettingsController.load();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: HColors.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // ★ 仅 --dart-define=SANDBOX_SELFTEST=true 时跑（release 默认不带，零影响）
  if (runSelfTest) {
    unawaited(_sandboxSelfTest());
  }

  runApp(HeraclesApp(settings: settings));
}

class HeraclesApp extends StatelessWidget {
  const HeraclesApp({super.key, required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    // ★ 设置是真实生效的：外观 / 强调色 / 字号 全部驱动主题重建
    return ValueListenableBuilder<AppSettings>(
      valueListenable: settings,
      builder: (context, s, _) {
        final dark = switch (s.appearance) {
          AppAppearance.dark => true,
          AppAppearance.light => false,
          AppAppearance.system =>
            MediaQuery.platformBrightnessOf(context) == Brightness.dark,
        };

        return MaterialApp(
          title: 'Heracles',
          debugShowCheckedModeBanner: false,
          theme: buildHeraclesTheme(
            accentHex: s.accentHex,
            dark: dark,
            fontSize: s.fontSize,
            themeStyle: s.themeStyle,
          ),
          // ★ 2026-10-22 Cupertino 化：iOS 转场（CupertinoPageTransitionsBuilder）
          //   配在 `buildHeraclesTheme` 的 ThemeData.pageTransitionsTheme 里 ——
          //   `MaterialApp` 没有这个参数（第一次放错了地方，analyze 抓住）。
          //   根件保留 `MaterialApp`：全 App 的 `Theme.of`/`Scaffold`/`Hue`
          //   体系都挂在 Material 上，换 `CupertinoApp` 会整树崩 ——
          //   设计语言由**控件与转场**决定，不由根件名字决定。
          // ThemeRevealHost：深浅切换的圆形扩散过渡（快照圆揭），
          // 边界包住整个 App 内容、旧图盖在最上层
          builder: (context, child) => ThemeRevealHost(
            child: HueScope(
            hue: Hue.forTheme(s.themeStyle, dark),
            // ★ 字号设置的真实落点：MediaQuery.textScaler
            //
            // 不用 textTheme.apply(fontSizeFactor:) —— 真机崩溃：
            //   'fontSize != null || (fontSizeFactor == 1.0 && ...)'
            // 因为主题里有 fontSize 为 null 的 TextStyle。
            //
            // textScaler 是 Flutter 官方的全局缩放机制，
            // 对所有文本生效且不受 null fontSize 影响。
            child: MediaQuery.withClampedTextScaling(
              minScaleFactor: s.fontSize / 15,
              maxScaleFactor: s.fontSize / 15,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          ),
          home: ChatScreen(settings: settings),
        );
      },
    );
  }
}

/// **仅 debug 自检用**：走 Dart → Kotlin → PRoot 全链路，结果打 logcat。
///
/// 存在的理由：沙箱能力暂时还没有 UI 入口（UI 归前端线），
/// 但没有真机证据就不能说「打通了」。这是最小侵入的取证方式。
Future<void> _sandboxSelfTest() async {
  final sandbox = SandboxService();
  void log(String m) => debugPrint('SANDBOX_SELFTEST $m');

  try {
    log('=== 开始 ===');
    final st0 = await sandbox.status();
    log('status: installed=${st0.installed} prootReady=${st0.prootReady} '
        'rootfs="${st0.rootfsSummary}"');

    final st1 = st0.installed ? st0 : await sandbox.activate();
    log('activate: installed=${st1.installed} rootfs="${st1.rootfsSummary}"');

    // 流式输出：拿到什么打什么
    final done = Completer<SandboxExecResult>();
    final subOut = sandbox.outputStream.listen((c) {
      if (c.chunk.trim().isNotEmpty) log('out> ${c.chunk.trimRight()}');
    });
    final subDone = sandbox.doneStream.listen((d) {
      if (!done.isCompleted) done.complete(d.result);
    });
    final subErr = sandbox.errorStream.listen((e) {
      if (!done.isCompleted) {
        log('error: code=${e.code} msg=${e.message}');
        done.completeError(StateError(e.message));
      }
    });

    final submit = await sandbox.execute(
      'echo dart-to-kotlin-ok; pwd; id -u; cat /etc/alpine-release 2>/dev/null',
      workdir: '/',
      timeoutMs: 60000,
    );
    log('submit: ok=${submit.ok} id=${submit.id}');

    if (submit.ok) {
      final r = await done.future.timeout(const Duration(seconds: 90));
      log('done: exit=${r.exitCode} ${r.durationMs}ms success=${r.success}');
      log('stdout="${r.stdout.trim()}" stderr="${r.stderr.trim()}"');
    }

    // 命名挂载：Dart 侧只给 @name
    final w = await sandbox.writeFile('@workspace/dart_selftest.txt', 'dart-mount-ok');
    log('write @workspace/dart_selftest.txt: ok=${w.ok} err=${w.error}');

    // 四条通道的**真实原因**（写进验证手册用）
    final chans = await sandbox.queryChannels();
    for (final c in chans) {
      log('channel ${c.name}: available=${c.available} risk=${c.risk} '
          'reason="${c.reason}"');
    }

    final mounts = await sandbox.listMounts();
    log('mounts: ${mounts.map((m) => "${m.prefix}${m.readOnly ? "(只读)" : ""}").join(", ")}');

    // ---- T1 内置工具（aapt2/aidl/zipalign）是否真的解包并能执行 ----
    // 这是「内置≠生效」的唯一证据：资产在 APK 里躺着但没解包出来时，
    // 沙箱里 `command -v aapt2` 会找不到。
    final t1 = await _sandboxRunOnce(
      sandbox,
      'ls -l /opt/as 2>&1; echo "---"; /opt/as/aapt2 version 2>&1',
      log,
    );
    log('T1(aapt2): ${t1.trim().replaceAll("\n", " | ")}');

    // ---- T2 编译环境状态（不触发 415 MB 下载，只看装没装）----
    final t2 = await sandbox.buildSuiteStatus();
    log('T2: ready=${t2.ready} version="${t2.version}" '
        'missing=${t2.missing.join(",")} err=${t2.error ?? ""}');

    await subOut.cancel();
    await subDone.cancel();
    await subErr.cancel();
    log('=== 结束 ===');
  } catch (e) {
    log('!! 自检异常: $e');
  } finally {
    sandbox.dispose();
  }
}

/// 自检用：在沙箱里跑一条命令并收集输出（不依赖全局流监听）。
Future<String> _sandboxRunOnce(
  SandboxService sandbox,
  String command,
  void Function(String) log,
) async {
  final out = StringBuffer();
  final done = Completer<SandboxExecResult>();
  final subs = <StreamSubscription<Object?>>[
    sandbox.outputStream.listen((c) {
      if (c.isProgress || c.chunk.isEmpty) return;
      out.write(c.chunk);
    }),
    sandbox.doneStream.listen((d) {
      if (!done.isCompleted) done.complete(d.result);
    }),
    sandbox.errorStream.listen((e) {
      if (!done.isCompleted) {
        log('run error: code=${e.code} msg=${e.message}');
        done.complete(const SandboxExecResult(
          exitCode: -1,
          stdout: '',
          stderr: '',
          durationMs: 0,
          timedOut: false,
          cancelled: false,
          truncated: false,
        ));
      }
    }),
  ];
  final submit = await sandbox.execute(command, workdir: '/', timeoutMs: 120000);
  if (!submit.ok) {
    for (final s in subs) {
      await s.cancel();
    }
    return '提交失败：${submit.error}';
  }
  final r = await done.future.timeout(
    const Duration(seconds: 150),
    onTimeout: () => const SandboxExecResult(
      exitCode: -1,
      stdout: 'TIMEOUT',
      stderr: '',
      durationMs: 0,
      timedOut: true,
      cancelled: false,
      truncated: false,
    ),
  );
  for (final s in subs) {
    await s.cancel();
  }
  if (r.exitCode != 0) out.write(' [exit=${r.exitCode}]');
  return out.toString();
}