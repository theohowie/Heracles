import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **确定性序列化门禁** —— 前缀缓存能不能命中的唯一判据。
///
/// ## 为什么这个文件最重要
///
/// 云端 84.6% 的缓存命中率（旧 Kotlin 实测）**全部依赖**"前缀字节完全一致"。
/// 只要序列化有一处不确定，命中率就掉到 0，token 成本 ×5~10。
///
/// 而"不确定性"往往藏在看不见的地方：
/// - Map 插入顺序（`jsonEncode` 按插入序，不排序）
/// - `double` 的 `.0`（`1.0` vs `1`）
/// - `toString()` 的默认实现（对象地址）
///
/// ⇒ 每一条都要有断言钉住。
void main() {
  group('deterministicJsonEncode — 字节稳定性', () {
    test('★ 同一份数据两次序列化，字节完全相同', () {
      final data = {
        'model': 'gpt-4o',
        'messages': [
          {'role': 'system', 'content': '你是 Heracles'},
          {'role': 'user', 'content': '读一下 a.txt'},
        ],
        'temperature': 0.7,
        'max_tokens': 16384,
      };

      final a = deterministicJsonEncode(data);
      final b = deterministicJsonEncode(data);
      expect(a, b, reason: '同一份数据必须产生同一份字节');
    });

    test('★★★ 键序保持插入顺序（不排序，因为 role/content 顺序是语义）', () {
      final a = deterministicJsonEncode({'role': 'user', 'content': 'hi'});
      expect(a, '{"role":"user","content":"hi"}');
    });

    test('★★★ 整数与浮点：1.0 必须写成 1（否则两次请求字节不同）', () {
      // 服务端返回的 usage 里常出现 1.0，本地算出来是 1
      expect(deterministicJsonEncode(1.0), '1');
      expect(deterministicJsonEncode(1), '1');
      expect(deterministicJsonEncode(1.0), deterministicJsonEncode(1),
          reason: '1.0 和 1 必须序列化成同一份字节');
    });

    test('★★ 浮点去尾零', () {
      expect(deterministicJsonEncode(1.50), '1.5');
      expect(deterministicJsonEncode(0.7), '0.7');
    });

    test('★★ 中文不转义（转义与否会改变字节数，必须固定一种）', () {
      final out = deterministicJsonEncode({'msg': '你好世界'});
      expect(out, '{"msg":"你好世界"}');
      expect(out.contains(r'\u'), isFalse, reason: '中文不该被转义成 \\u 形式');
    });

    test('★★ 必须转义的只用最短形式', () {
      expect(deterministicJsonEncode('a"b'), r'"a\"b"');
      expect(deterministicJsonEncode('a\nb'), r'"a\nb"');
      expect(deterministicJsonEncode('a\\b'), r'"a\\b"');
      // `/` 不转义（JSON 允许，转义会多余）
      expect(deterministicJsonEncode('a/b'), '"a/b"');
    });

    test('★★ 不支持的类型必须抛错（不静默 toString）', () {
      // 静默 toString 会产生 `Instance of 'X'` —— 每次可能不同，直接毁缓存
      expect(() => deterministicJsonEncode(Object()), throwsArgumentError);
      expect(() => deterministicJsonEncode(DateTime.now()), throwsArgumentError);
    });

    test('★★ NaN / Infinity 必须抛错（JSON 无此表示）', () {
      expect(() => deterministicJsonEncode(double.nan), throwsArgumentError);
      expect(() => deterministicJsonEncode(double.infinity), throwsArgumentError);
    });

    test('★ 嵌套结构稳定', () {
      final data = {
        'tools': [
          {'name': 'read_file', 'parameters': {'type': 'object', 'properties': {}}},
        ],
        'nested': {
          'deep': {'value': [1, 2, 3]},
        },
      };
      final a = deterministicJsonEncode(data);
      final b = deterministicJsonEncode(data);
      expect(a, b);
      expect(a.contains('Instance of'), isFalse);
    });
  });

  group('renderToolsCanonical — 工具定义的前缀稳定', () {
    List<Map<String, dynamic>> tools() => [
          {'name': 'write_file', 'description': '写文件', 'parameters': {'type': 'object'}},
          {'name': 'read_file', 'description': '读文件', 'parameters': {'type': 'object'}},
          {'name': 'list_files', 'description': '列目录', 'parameters': {'type': 'object'}},
        ];

    test('★★★ 工具顺序不影响输出（按名字排序）', () {
      final a = renderToolsCanonical(tools());
      final b = renderToolsCanonical(tools().reversed);
      expect(a, b, reason: '工具列表可能来自 Set 遍历，顺序不可信 ⇒ 必须排序');
    });

    test('★★ 重复渲染字节一致', () {
      expect(renderToolsCanonical(tools()), renderToolsCanonical(tools()));
    });

    test('★★ 缺 description / parameters 时有确定的兜底', () {
      final a = renderToolsCanonical([
        {'name': 'x'},
      ]);
      expect(a.contains('"description":""'), isTrue);
      expect(a.contains('"parameters":{"type":"object","properties":{}}'), isTrue);
    });
  });

  group('sortedObject', () {
    test('★ 键按字典序', () {
      final out = sortedObject({'b': 2, 'a': 1, 'c': 3});
      expect(out.keys.toList(), ['a', 'b', 'c']);
    });
  });
}
