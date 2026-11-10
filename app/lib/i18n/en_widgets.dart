/// `app/lib/widgets/**` 的英文词条。
///
/// **归属：前端组件线（fe-ix）**。别人不要往这里加。
///
/// 规则：
/// - key = 代码里的中文原文，**逐字一致**（含全角标点、空格、`…`）。
/// - 只放**用户可见**的文案；注释、日志、debugPrint、异常技术细节不翻。
/// - 技术名词保留原样：MCP / JSONL / append-only / BYOK / PRoot / token / diff / commit。
/// - 缺失的条目在英文模式下会退回中文（安全回退），所以可以分批补。
library;

Map<String, String> get enWidgets => const <String, String>{
      // 由 fe-ix 填充。
    };
