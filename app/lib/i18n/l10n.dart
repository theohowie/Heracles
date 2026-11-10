/// Heracles 的国际化底座（v0.5.1 第一版）。
///
/// ## 为什么不用 `gen_l10n` / ARB / 代码生成
///
/// 这个 App 的中文文案是**直接写在控件里**的（`Text('新建会话')`），
/// 全量改造成 `AppLocalizations.of(context).newChat` 要动两千多处调用点，
/// 而且每改一次文案就得重新生成代码。
///
/// 第一版取「**按中文原文查表**」的做法：
///
/// ```dart
/// Text(tr('新建会话'))              // → en: "New chat"
/// Text(tr('共 {n} 条', args: {'n': n}))
/// ```
///
/// **缺词条时原样返回中文** —— 所以「只翻了一半」不会渲染出乱码或空串，
/// 而是在英文模式下显示中文。这是刻意的安全回退：宁可半中文，不能空白。
///
/// ## 词条归属（各区域各自维护，互不冲突）
///
/// | 文件 | 归属 | 内容 |
/// |---|---|---|
/// | `en_common.dart` | 通用 | 按钮、状态、单位、跨模块文案 |
/// | `en_screens.dart` | 前端界面线 | `app/lib/screens/**` 的文案 |
/// | `en_widgets.dart` | 前端组件线 | `app/lib/widgets/**` 的文案 |
///
/// key **必须与代码里的中文字面量逐字一致**（含全角标点）。
library;

import 'package:flutter/widgets.dart';

import 'en_common.dart';
import 'en_screens.dart';
import 'en_widgets.dart';

/// 当前语言（默认中文）。改动后 App 根会整体重建。
final ValueNotifier<Locale> appLocale = ValueNotifier(const Locale('zh'));

/// 支持的语言；顺序即设置页展示顺序。
const List<Locale> kSupportedLocales = <Locale>[Locale('zh'), Locale('en')];

/// 中文（默认语言）的显示名 —— 用各自语言的写法，切换列表里更好认。
const Map<String, String> kLanguageNames = <String, String>{
  'zh': '中文',
  'en': 'English',
};

/// 当前是否英文。
bool get isEnglish => appLocale.value.languageCode == 'en';

/// 切换语言。空值/未知值忽略（保持原语言），绝不抛。
void setAppLocale(String? languageCode) {
  final code = (languageCode ?? '').trim().toLowerCase();
  if (code.isEmpty) return;
  if (code != 'zh' && code != 'en') return;
  if (appLocale.value.languageCode == code) return;
  appLocale.value = Locale(code);
}

Map<String, String>? _merged;

/// 合并后的英文字典（懒加载，只建一次）。
///
/// 冲突策略：**先注册者胜** ⇒ 顺序为 common → screens → widgets。
/// 同一句中文在通用表里已有英译时，区域表里的重复条目会被忽略，
/// 这样各区域可以放心加词条，不会互相打架。
Map<String, String> get _dict {
  final cached = _merged;
  if (cached != null) return cached;
  final merged = <String, String>{};
  for (final part in <Map<String, String>>[enCommon, enScreens, enWidgets]) {
    for (final entry in part.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
  }
  _merged = merged;
  return merged;
}

/// 当前已登记的英文词条数（诊断/测试用）。
int get englishEntryCount => _dict.length;

/// 把中文原文翻成当前语言。
///
/// - 中文模式：**原样返回**（不做任何字符串拼接，零开销）。
/// - 英文模式：查表；**查不到返回中文原文**。
/// - `args` 用 `{name}` 占位，两种语言都会替换。
String tr(String zh, {Map<String, Object>? args}) {
  var s = zh;
  if (isEnglish) {
    s = _dict[zh] ?? zh;
  }
  if (args != null && args.isNotEmpty) {
    for (final entry in args.entries) {
      s = s.replaceAll('{${entry.key}}', '${entry.value}');
    }
  }
  return s;
}

/// 仅测试用：清掉合并缓存（改字典内容后需要重新合并）。
@visibleForTesting
void resetTranslationCache() => _merged = null;
