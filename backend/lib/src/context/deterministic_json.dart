/// **确定性 JSON 序列化** —— 保住前缀缓存的核心。
///
/// ## 为什么必须自己写（不能用 `jsonEncode`）
///
/// 云端的前缀缓存只在**字节完全一致**时命中。Dart 的 `Map` 是
/// `LinkedHashMap`（插入序），**同一份逻辑数据只要插入顺序不同，
/// `jsonEncode` 出来的字节就不同** ⇒ 缓存全灭。
///
/// 实测代价（旧 Kotlin 实现）：稳态命中率 **84.6%**（token 加权）。
/// 一旦前缀抖动，命中率掉到 0，输入 token 成本 ×5~10。
///
/// ## 三层保证
///
/// 1. **键序固定**：对象按**插入顺序写出，但调用方保证插入顺序确定**
///    （见 [DeterministicMap]）；需要"按名字排序"的地方显式用 [sortedObject]。
/// 2. **数字规范化**：整数不写 `.0`，浮点去掉无意义的尾零。
/// 3. **字符串转义固定**：只用最短转义（`"` `\` 控制符），
///    **不转义** `/`、中文、emoji（`jsonEncode` 已经这么做，但这里显式保证）。
///
/// ## 不做的事
///
/// - 不排序对象的键（会破坏消息里"字段语义顺序"，且 OpenAI 系对顺序敏感）
/// - 不做 key 去重（重复键是上游 bug，应该炸出来而不是静默合并）
library;

/// 序列化为确定性 JSON 字符串（**无缩进**，字段顺序 = Map 插入顺序）。
///
/// 与 `jsonEncode` 的区别：
/// - 数字格式固定（`1.0` → `1`，`1.50` → `1.5`）
/// - 不支持的对象类型**直接抛错**，不静默 `toString()`
///   （静默 toString 会产生 `Instance of 'X'` 这种垃圾进 prompt，且每次可能不同）
String deterministicJsonEncode(Object? value) {
  final buf = StringBuffer();
  _write(buf, value);
  return buf.toString();
}

void _write(StringBuffer buf, Object? value) {
  switch (value) {
    case null:
      buf.write('null');
    case bool b:
      buf.write(b ? 'true' : 'false');
    case int i:
      buf.write(i);
    case double d:
      buf.write(_formatDouble(d));
    case String s:
      _writeString(buf, s);
    case List l:
      buf.write('[');
      for (var i = 0; i < l.length; i++) {
        if (i > 0) buf.write(',');
        _write(buf, l[i]);
      }
      buf.write(']');
    case Map m:
      buf.write('{');
      var first = true;
      for (final entry in m.entries) {
        if (entry.key is! String) {
          throw ArgumentError(
            'deterministicJsonEncode: 对象的键必须是 String，收到 ${entry.key.runtimeType}',
          );
        }
        if (!first) buf.write(',');
        first = false;
        _writeString(buf, entry.key as String);
        buf.write(':');
        _write(buf, entry.value);
      }
      buf.write('}');
    default:
      throw ArgumentError(
        'deterministicJsonEncode: 不支持的类型 ${value.runtimeType}。'
        '请先转成 Map/List/num/String/bool/null —— '
        '静默 toString 会产生每次都不一样的字符串，直接毁掉前缀缓存。',
      );
  }
}

/// 浮点格式化：去掉尾零与多余的 `.0`。
///
/// 为什么不用 `toString()`：`1.0.toString()` 是 `"1.0"`，而同样的值
/// 从 JSON 解回来可能是 `int` 1 ⇒ 两次请求字节不同。统一成 `"1"`。
String _formatDouble(double d) {
  if (d.isNaN || d.isInfinite) {
    throw ArgumentError('deterministicJsonEncode: 不支持 NaN / Infinity（JSON 无此表示）');
  }
  if (d == d.truncateToDouble() && d.abs() < 1e21) {
    return d.toInt().toString();
  }
  // toStringAsPrecision 会引入浮动误差，用最短往返表示
  final s = d.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// 字符串转义 —— **最短转义**，保证同一字符串永远同一份字节。
void _writeString(StringBuffer buf, String s) {
  buf.write('"');
  for (final code in s.codeUnits) {
    switch (code) {
      case 0x22: // "
        buf.write(r'\"');
      case 0x5C: // \
        buf.write(r'\\');
      case 0x08:
        buf.write(r'\b');
      case 0x0C:
        buf.write(r'\f');
      case 0x0A:
        buf.write(r'\n');
      case 0x0D:
        buf.write(r'\r');
      case 0x09:
        buf.write(r'\t');
      default:
        if (code < 0x20) {
          buf.write(r'\u');
          buf.write(code.toRadixString(16).padLeft(4, '0'));
        } else {
          // 中文 / emoji / `/` 原样写出（不转义）—— 服务端接受，
          // 且转义与否会改变字节数，必须固定一种。
          buf.writeCharCode(code);
        }
    }
  }
  buf.write('"');
}

/// 构造一个**键按字典序**排列的 JSON 对象。
///
/// 用于「集合类」数据（工具定义、标签列表…）—— 这类数据的语义与键序无关，
/// 排序能消除"上游用了 HashSet 导致顺序随机"的风险。
///
/// ⚠️ **不要**用它处理消息体（`role`/`content` 的顺序是语义，不能排）。
Map<String, dynamic> sortedObject(Map<String, dynamic> input) {
  final keys = input.keys.toList()..sort();
  return {for (final k in keys) k: input[k]};
}

/// 把工具定义渲染成**确定**的 JSON 文本。
///
/// 顺序规则：
/// 1. 工具列表按 `name` 字典序（调用方传进来的顺序可能是 Set 遍历序，不可信）
/// 2. 每个工具内部按 `name` / `description` / `parameters` 固定顺序
/// 3. `parameters.properties` 的键**保持声明顺序**（参数顺序影响模型理解）
///
/// 这个函数是「缓存能不能命中」的第一道闸 —— 它输出的字节必须稳定。
String renderToolsCanonical(Iterable<Map<String, dynamic>> tools) {
  final sorted = tools.toList()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  final buf = StringBuffer();
  for (final t in sorted) {
    buf.write(deterministicJsonEncode({
      'name': t['name'],
      'description': t['description'] ?? '',
      'parameters': t['parameters'] ?? const {'type': 'object', 'properties': {}},
    }));
    buf.write('\n');
  }
  return buf.toString();
}
