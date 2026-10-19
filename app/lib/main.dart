import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/settings.dart';
import 'screens/chat_screen.dart';
import 'services/settings_controller.dart';
import 'theme/app_theme.dart';

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
  WidgetsFlutterBinding.ensureInitialized();

  // 设置必须在 runApp 之前加载 —— 否则首帧会用默认主题再闪一下
  final settings = await SettingsController.load();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: HColors.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

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
          ),
          builder: (context, child) => HueScope(
            hue: Hue.forDark(dark, s.accentHex),
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
          home: ChatScreen(settings: settings),
        );
      },
    );
  }
}
