import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/settings.dart';
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
    required this.onAccent,
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.text,
    required this.textDim,
    required this.textFaint,
    this.glowColors = const [],
  });

  final bool dark;
  final Color accent;

  /// 强调色上的文字/图标色（黑白深色是黑字在近白上，其余是白字在彩色上）
  final Color onAccent;
  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color text;
  final Color textDim;
  final Color textFaint;

  /// 背景光晕色（2026-10-24，用户要的极光/活力光斑背景）。
  ///
  /// 为空 = 纯色底（黑白、柔雾）；非空 = `ThemedBackground` 在底色上
  /// 画对应颜色的径向光斑。只改背景，不改布局。
  final List<Color> glowColors;

  /// 遮罩/棋盘等半透明层
  Color get scrim => dark ? const Color(0xCC000000) : const Color(0x33FFFFFF);

  static Hue of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<HueScope>();
    assert(s != null, 'HueScope 未挂载 —— 检查 main.dart 是否包了 HueScope');
    return s!.hue;
  }

  /// 深色（默认）—— 黑白方向：强调色即文字色本身
  static const darkHue = Hue(
    dark: true,
    accent: Color(0xFFF2F2F2),
    onAccent: Color(0xFF0A0A0B),
    bg: Color(0xFF0A0A0B),
    surface: Color(0xFF141415),
    surfaceAlt: Color(0xFF1C1C1E),
    border: Color(0xFF2A2A2C),
    text: Color(0xFFF2F2F2),
    textDim: Color(0xFFA3A3A3),
    textFaint: Color(0xFF6E6E73),
  );

  /// 浅色 —— 黑白简约方向（2026-10-24 用户拍板）：底 #F7F7F7、卡片白、文字 #161616
  static const lightHue = Hue(
    dark: false,
    accent: Color(0xFF161616),
    onAccent: Color(0xFFFFFFFF),
    bg: Color(0xFFF7F7F7),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF0F0F0),
    border: Color(0xFFE3E3E6),
    text: Color(0xFF161616),
    textDim: Color(0xFF5C5C5C),
    // 浅色下 faint 必须比深色下更深，否则不可读
    textFaint: Color(0xFFA3A3A3),
  );

  /// 柔雾浅色（2026-10-23 定过的方向）：奶油底、淡紫强调、薄荷点缀
  static const mistLightHue = Hue(
    dark: false,
    accent: Color(0xFF7C6AE8),
    onAccent: Color(0xFFFFFFFF),
    bg: Color(0xFFFAF6EF),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF3EDE0),
    border: Color(0xFFE8DFCE),
    text: Color(0xFF2E2A26),
    textDim: Color(0xFF7A7268),
    textFaint: Color(0xFFB0A696),
  );

  /// 柔雾深色：深紫底 + 淡紫强调
  static const mistDarkHue = Hue(
    dark: true,
    accent: Color(0xFF9B8AFB),
    onAccent: Color(0xFFFFFFFF),
    bg: Color(0xFF211D2E),
    surface: Color(0xFF2B2540),
    surfaceAlt: Color(0xFF332C4A),
    border: Color(0xFF453B5E),
    text: Color(0xFFF1EDE6),
    textDim: Color(0xFFB5AEC4),
    textFaint: Color(0xFF7E7690),
  );

  /// 极光深色：近黑蓝紫底 + 青色强调（概念图像素：青色允许键、紫色气泡）
  static const auroraDarkHue = Hue(
    dark: true,
    accent: Color(0xFF22D3EE),
    onAccent: Color(0xFF0B0B16),
    bg: Color(0xFF0B0B16),
    surface: Color(0xFF171726),
    surfaceAlt: Color(0xFF1E1E33),
    border: Color(0xFF2E2E4A),
    text: Color(0xFFF2F2F8),
    textDim: Color(0xFF9A9AB5),
    textFaint: Color(0xFF666680),
    // 左上紫、右上青、底部品红三处光斑
    glowColors: [Color(0xFF8B5CF6), Color(0xFF22D3EE), Color(0xFFEC4899)],
  );

  /// 极光浅色：淡紫灰底 + 紫色强调
  static const auroraLightHue = Hue(
    dark: false,
    accent: Color(0xFF7C3AED),
    onAccent: Color(0xFFFFFFFF),
    bg: Color(0xFFF0F0FA),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFE8E8F6),
    border: Color(0xFFDDDDF0),
    text: Color(0xFF1B1B2E),
    textDim: Color(0xFF5A5A78),
    textFaint: Color(0xFF9A9AB8),
    glowColors: [Color(0xFFC4B5FD), Color(0xFF67E8F9), Color(0xFFF9A8D4)],
  );

  /// 活力浅色：暖奶油底 + 珊瑚橙强调（概念图像素：珊瑚色允许键、米白底）
  static const vitalityLightHue = Hue(
    dark: false,
    accent: Color(0xFFFF6B4A),
    onAccent: Color(0xFFFFFFFF),
    bg: Color(0xFFFDF3E7),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFFBE9D8),
    border: Color(0xFFF0DCC8),
    text: Color(0xFF2B2118),
    textDim: Color(0xFF7A6A5C),
    textFaint: Color(0xFFB8A894),
    glowColors: [Color(0xFFFFB08A), Color(0xFFFFC46B), Color(0xFFFF8A7A)],
  );

  /// 活力深色：深暖棕底 + 珊瑚橙强调
  static const vitalityDarkHue = Hue(
    dark: true,
    accent: Color(0xFFFF7A59),
    onAccent: Color(0xFFFFFFFF),
    bg: Color(0xFF1F1712),
    surface: Color(0xFF2A2018),
    surfaceAlt: Color(0xFF352A1F),
    border: Color(0xFF453729),
    text: Color(0xFFF8EFE4),
    textDim: Color(0xFFC4B4A2),
    textFaint: Color(0xFF8A7A68),
    glowColors: [Color(0xFFFF6B4A), Color(0xFFFF9E5C), Color(0xFFB45309)],
  );

  /// 黑白方向下强调色不再由用户自选：深色 = 近白，浅色 = 近黑。
  ///
  /// `accentHex` 参数保留只是为了不破坏现有调用点，**传入值会被忽略**。
  /// 强调色选择 UI 已从外观页移除（2026-10-24），`AppSettings.accentHex`
  /// 仅作持久化兼容残留。
  static Hue forDark(bool dark, [int? accentHex]) {
    return dark ? darkHue : lightHue;
  }

  /// 主题选择（2026-10-24）：只换颜色与背景，不换布局。
  /// 切换后整个 App 的 Hue 与 ThemeData 一起换，调用方只需传 `themeStyle`。
  static Hue forTheme(AppThemeStyle style, bool dark) {
    switch (style) {
      case AppThemeStyle.bw:
        return dark ? darkHue : lightHue;
      case AppThemeStyle.mist:
        return dark ? mistDarkHue : mistLightHue;
      case AppThemeStyle.aurora:
        return dark ? auroraDarkHue : auroraLightHue;
      case AppThemeStyle.vitality:
        return dark ? vitalityDarkHue : vitalityLightHue;
    }
  }
}

/// 把 [Hue] 注入 widget 树。
class HueScope extends InheritedWidget {
  const HueScope({super.key, required this.hue, required super.child});

  final Hue hue;

  @override
  bool updateShouldNotify(HueScope old) =>
      old.hue.dark != hue.dark ||
      old.hue.accent != hue.accent ||
      old.hue.bg != hue.bg;
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
  static const bg = Color(0xFF0A0A0B);

  /// 卡片/面板
  static const surface = Color(0xFF141415);

  /// 次级面板（代码块、工具输出）
  static const surfaceAlt = Color(0xFF1C1C1E);

  /// 分隔线 —— 用细边框代替阴影，更"终端"
  static const border = Color(0xFF2A2A2C);

  static const text = Color(0xFFF2F2F2);
  static const textDim = Color(0xFFA3A3A3);
  static const textFaint = Color(0xFF6E6E73);

  /// 主强调色：黑白方向下 = 文字色本身（深色为近白）。
  /// 旧值是暖橙 0xFFFF7A45，2026-10-24 随黑白简约方向退役。
  static const accent = Color(0xFFF2F2F2);

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

/// 统一字阶（2026-10-24 用户拍板，概念图同款）。
///
/// 全 App 只用这一组字号：页面标题 22 粗体、分组标题 13 半粗体、
/// 正文 15、次要 13、说明 12；等宽字体只用于代码与数字。
class HTxt {
  HTxt._();

  /// 页面标题（设置页、外观页等）
  static const pageTitle =
      TextStyle(fontSize: 22, fontWeight: FontWeight.w700);

  /// 分组小字标题（设置页的「通用设置」等）
  static const sectionTitle =
      TextStyle(fontSize: 13, fontWeight: FontWeight.w600);

  /// 正文
  static const body = TextStyle(fontSize: 15);

  /// 次要文字（副标题、状态值）
  static const secondary = TextStyle(fontSize: 13);

  /// 说明文字（脚注、提示）
  static const caption = TextStyle(fontSize: 12);

  /// 代码 / 数字（等宽，回退链见 kMonoFallback）
  static TextStyle mono(double size) => TextStyle(
        fontSize: size,
        fontFamily: kMonoFontFamily,
        fontFamilyFallback: kMonoFallback,
      );
}

ThemeData buildHeraclesTheme({
  // ignore: unused_parameter — 黑白方向下强调色固定，见 Hue.forDark 注释
  int accentHex = 0xFF161616,
  bool dark = true,
  double fontSize = 15,
  AppThemeStyle themeStyle = AppThemeStyle.bw,
}) {
  final hue = Hue.forTheme(themeStyle, dark);

  final scheme = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: hue.accent,
    onPrimary: hue.onAccent,
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
