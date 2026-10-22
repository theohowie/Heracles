import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'cupertino_kit.dart';

/// 当前主题的语义色 —— **跟随外观设置变化**。
///
/// ## 为什么需要这个，而不直接用 `HColors` 常量
///
/// `HColors` 是**深色模式的常量**。组件直接引用它，浅色模式下
/// 就会出现"白底上的浅灰字"这种不可读的对比度问题 ——
/// 实测发现："手机上的开发智能体"在浅色模式下几乎看不见。
///
/// `HColors` 保留给**不随主题变化**的语义色（成功/警告/错误/信息）——
/// 它们在深浅两色下都有足够对比度。
///
/// 组件里凡是要显示**文字、背景、边框**的地方，都用 `Hue.of(context)`。
class Hue {
  const Hue({
    required this.dark,
    required this.accent,
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.text,
    required this.textDim,
    required this.textFaint,
  });

  final bool dark;
  final Color accent;
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color text;
  final Color textDim;
  final Color textFaint;

  /// 遮罩/棋盘等半透明层
  Color get scrim => dark ? const Color(0xCC000000) : const Color(0x33FFFFFF);

  static Hue of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<HueScope>();
    assert(s != null, 'HueScope 未挂载 —— 检查 main.dart 是否包了 HueScope');
    return s!.hue;
  }

  /// 深色（默认）
  static const darkHue = Hue(
    dark: true,
    accent: HColors.accent,
    bg: HColors.bg,
    surface: HColors.surface,
    surfaceAlt: HColors.surfaceAlt,
    border: HColors.border,
    text: HColors.text,
    textDim: HColors.textDim,
    textFaint: HColors.textFaint,
  );

  /// 浅色
  static const lightHue = Hue(
    dark: false,
    accent: HColors.accent,
    bg: Color(0xFFF7F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF0F0F4),
    border: Color(0xFFE2E2E8),
    text: Color(0xFF17171A),
    textDim: Color(0xFF5A5A66),
    // 浅色下 faint 必须比深色下更深，否则不可读
    textFaint: Color(0xFF8A8A96),
  );

  static Hue forDark(bool dark, int accentHex) {
    final base = dark ? darkHue : lightHue;
    return Hue(
      dark: dark,
      accent: Color(accentHex),
      bg: base.bg,
      surface: base.surface,
      surfaceAlt: base.surfaceAlt,
      border: base.border,
      text: base.text,
      textDim: base.textDim,
      textFaint: base.textFaint,
    );
  }
}

/// 把 [Hue] 注入 widget 树。
class HueScope extends InheritedWidget {
  const HueScope({super.key, required this.hue, required super.child});

  final Hue hue;

  @override
  bool updateShouldNotify(HueScope old) =>
      old.hue.dark != hue.dark || old.hue.accent != hue.accent;
}

/// 全应用配色 token —— 深色值为基准。
///
/// **组件里不得直接用这些常量渲染文字/背景**，
/// 应该用 `Hue.of(context)`。这里保留是为了：
/// 1. 语义色（success/warn/error/info）在两种主题下都可用
/// 2. `Hue` 的定义引用它们，避免色值散落
class HColors {
  HColors._();

  /// 背景：接近纯黑但不刺眼
  static const bg = Color(0xFF0B0B0D);

  /// 卡片/面板
  static const surface = Color(0xFF141419);

  /// 次级面板（代码块、工具输出）
  static const surfaceAlt = Color(0xFF1B1B22);

  /// 分隔线 —— 用细边框代替阴影，更"终端"
  static const border = Color(0xFF2A2A33);

  static const text = Color(0xFFE9E9EC);
  static const textDim = Color(0xFF9A9AA6);
  static const textFaint = Color(0xFF66666F);

  /// 主强调色：暖橙。终端美学里冷色太"企业"，暖色更有工具感
  static const accent = Color(0xFFFF7A45);

  // ---- 语义色：不随主题变化（深浅两色下对比度都够） ----
  static const success = Color(0xFF4ADE80);
  static const successDeep = Color(0xFF16A34A);
  static const warn = Color(0xFFFBBF24);
  static const warnDeep = Color(0xFFD97706);
  static const error = Color(0xFFF87171);
  static const errorDeep = Color(0xFFDC2626);
  static const info = Color(0xFF60A5FA);
  static const infoDeep = Color(0xFF2563EB);

  /// 云端后端标识色（隐私指示，FR-11.9）
  static const cloud = Color(0xFFA78BFA);

  /// 本地后端标识色
  static const local = Color(0xFF34D399);

  /// 根据主题选语义色 —— 浅色下用更深的变体保证对比度
  static Color successOn(bool dark) => dark ? success : successDeep;
  static Color warnOn(bool dark) => dark ? warn : warnDeep;
  static Color errorOn(bool dark) => dark ? error : errorDeep;
  static Color infoOn(bool dark) => dark ? info : infoDeep;
}

/// 间距 —— 8pt 栅格
class HSpace {
  HSpace._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// 圆角
class HRadius {
  HRadius._();
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
  /// 大容器圆角（2026-10-12）—— 输入框改为「大容器」形态
  /// （仿 llama.cpp Web UI：+/发送键内嵌容器内部，容器占满宽度）。
  /// 14(lg) 在占满宽度的容器上显得太「方」，参考图是明显的胶囊感。
  static const xl = 24.0;
  static const pill = 999.0;
}

/// 移动端最小触控热区（dp）。
///
/// 44 是 `docs/25` §7 第 3 条给的下限（也是 iOS HIG 的值；Android
/// 官方建议 48 —— 取 44 为**下限**，允许实现方做到更大）。
///
/// **为什么要有这个常量**：热区太小是那种"看起来能用、实际点不到"
/// 的缺陷，没有测试会失败、构建也不会报错，只有真机上手才知道。
const kMinTapTarget = 44.0;

/// 等宽字体族。
///
/// **必须提供回退链** —— Android 上不一定有 'JetBrains Mono'，
/// 直接写单一字体名会导致代码块用默认字体渲染，失去对齐。
const kMonoFontFamily = 'JetBrains Mono';
const kMonoFallback = <String>[
  'JetBrains Mono',
  'Roboto Mono',
  'Droid Sans Mono',
  'monospace',
];

ThemeData buildHeraclesTheme({
  int accentHex = 0xFFFF7A45,
  bool dark = true,
  double fontSize = 15,
}) {
  final hue = Hue.forDark(dark, accentHex);

  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: hue.accent,
    onPrimary: dark ? const Color(0xFF1A0E08) : const Color(0xFFFFFFFF),
    secondary: hue.accent,
    onSecondary: const Color(0xFF04121F),
    surface: hue.surface,
    onSurface: hue.text,
    error: HColors.errorOn(dark),
    onError: const Color(0xFF2A0A0A),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: hue.bg,
    fontFamily: 'Roboto',
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: hue.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: hue.text),
      titleTextStyle: TextStyle(
        color: hue.text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    dividerTheme: DividerThemeData(color: hue.border, thickness: 1, space: 1),
    // ★ 字号缩放**不在这里做**（2026-10-09 修正）
    //
    // 首版用 `textTheme.apply(fontSizeFactor: fontSize / 15)`，真机白屏崩溃：
    //   Failed assertion: 'fontSize != null ||
    //     (fontSizeFactor == 1.0 && fontSizeDelta == 0.0)'
    // 因为 Material 主题里有些 TextStyle 的 fontSize 是 null，
    // Flutter 不允许对它们套 fontSizeFactor。
    //
    // 正确做法：用 `MediaQuery.textScaler` —— 这是 Flutter 官方的
    // 全局字号缩放机制，它对**所有**文本生效且不受 null fontSize 影响。
    // 落点在 main.dart 的 MaterialApp.builder。
    textTheme: base.textTheme.apply(
      bodyColor: hue.text,
      displayColor: hue.text,
    ),
    // ★ 全局关掉 Material 波纹（2026-10-22 Cupertino 化）—— iOS 上按下
    //   **没有水波纹**。`kNoSplash` 一行就让全 App 现存的 InkWell/按钮
    //   立刻失去 Material 波纹，不必逐个换控件（见 cupertino_kit.dart）。
    //   旧值是 InkSparkle.splashFactory（Material 3 的星屑波纹）。
    splashFactory: kNoSplash,
    // ★ iOS 转场（2026-10-22 Cupertino 化）：页面切换用 Cupertino 的横向推拉+视差。
    // 注意 pageTransitionsTheme 是 ThemeData 的参数，MaterialApp 上没有这个参数。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
