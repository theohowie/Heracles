/// **搜索服务配置测试**（V0.4 F4，2026-11-02）。
///
/// ## 为什么这里有一条内存版存储（而不是用真的 `FlutterSecureStorage`）
///
/// `flutter_secure_storage` 在 `flutter test` 里没有平台通道，任何 `read`
/// 都会抛 `MissingPluginException`。就算能通，测试也会读写**开发者真机/
/// 模拟器的 KeyStore** —— 既不可重复（上一次跑留下的值会影响下一次），
/// 又可能把真凭据搅坏。所以服务层把存储抽成 [SearchCredStore]，
/// 测试塞 [_MemoryStore]：
///
/// - 测的是**本文件的分支与脱敏规则**（该拒的拒、该掩的掩、读失败要报错）；
/// - 平台能不能用是 `flutter_secure_storage` 的事，真机验证，不在单测里假装。
///
/// 另外用 [_MemoryStore] 的 `throwOnXxx` 造"存储坏了"——这正是"读取失败"
/// 与"未配置"必须分开的那条分支，靠真存储造不出来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/search_config_service.dart';
import 'package:heracles_backend/heracles_backend.dart';

/// 内存版凭据存储：可控地"不存在 / 存在 / 抛异常"。
class _MemoryStore implements SearchCredStore {
  final Map<String, String> data = <String, String>{};

  /// 按调用顺序记下写过的键（用于验证"先 Key 后 endpoint"的提交顺序）。
  final List<String> writes = <String>[];

  Object? throwOnRead;
  Object? throwOnWrite;
  Object? throwOnDelete;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead != null) throw throwOnRead!;
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (throwOnWrite != null) throw throwOnWrite!;
    writes.add(key);
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (throwOnDelete != null) throw throwOnDelete!;
    data.remove(key);
  }
}

void main() {
  // 测试里反复用到的一把"看起来像真的"的 Key。
  const useKey = 'sk-1234567890abcd';

  group('① 保存后读取', () {
    test('★★★ 带 Key 保存 ⇒ 整个拒绝，一个字节都不写（本版本免鉴权）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);

      final saved = await svc.save(
        'https://api.example.com/search',
        key: useKey,
      );
      // 不许"存了 endpoint 却丢掉 Key"的半截成功 —— 那会让设置页显示
      // "已保存"，而请求根本没有鉴权，用户只会看到 401。
      expect(saved.ok, isFalse, reason: '带 Key 保存必须被明确拒绝');
      expect(saved.code, ContractSearch.errKeyUnsupported);
      expect(saved.message, contains('免鉴权'));
      // endpoint 也没写进去（整笔拒绝，不是部分成功）
      expect(store.data.containsKey(ContractSearch.endpointKey), isFalse);
      expect(store.data.containsKey(ContractSearch.apiKeyKey), isFalse);
      expect(store.writes, isEmpty, reason: '拒绝时不得落任何一笔写');
    });

    test('不带 Key ⇒ 只写 endpoint（本版本没有"先 Key 后 endpoint"的顺序）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      expect(
        (await svc.save('https://api.example.com/search')).ok,
        isTrue,
      );
      expect(store.writes, <String>[ContractSearch.endpointKey]);
    });

    test('不给 Key ⇒ hasKey 为假（但 endpoint 仍然存下）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      expect((await svc.save('http://127.0.0.1:8080/search')).ok, isTrue);

      final cfg = await svc.read();
      expect(cfg.endpoint, 'http://127.0.0.1:8080/search');
      expect(cfg.hasKey, isFalse);
      expect(store.data.containsKey(ContractSearch.apiKeyKey), isFalse);
    });

    test('★★★ 上一版本遗留的 Key 会在 read 时被清掉（迁移，不留半截）', () async {
      final store = _MemoryStore();
      // 上一版本存过 Key：它发不出去（能力层没有请求头的位置），
      // 留着只会让人以为"鉴权生效了"。
      store.data[ContractSearch.apiKeyKey] = useKey;
      store.data[ContractSearch.endpointKey] = 'https://api.example.com/s';

      final svc = SearchConfigService(store: store);
      final cfg = await svc.read();

      expect(cfg.hasKey, isFalse, reason: '免鉴权版本必须如实报"没有 Key"');
      expect(cfg.endpoint, 'https://api.example.com/s');
      expect(store.data.containsKey(ContractSearch.apiKeyKey), isFalse,
          reason: '发不出去的凭据必须删掉，不能躺在存储里装样子');
    });

    test('传空白字符串 key 等于没传（不拒、不写）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      final saved = await svc.save('https://a.example.com/s', key: '   ');
      expect(saved.ok, isTrue);
      expect(store.writes, <String>[ContractSearch.endpointKey]);
    });

    test('endpoint 两端空白被裁掉（否则存进去的地址没法直接用）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      await svc.save('  https://api.example.com/s  ');
      expect((await svc.read()).endpoint, 'https://api.example.com/s');
    });

    test('大小写 scheme 接受，并按原样存（Uri 已归一，不影响请求）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      expect((await svc.save('HTTPS://API.Example.com/S')).ok, isTrue);
      expect((await svc.read()).endpoint, 'HTTPS://API.Example.com/S');
    });

    test('首次使用（存储全空）⇒ 空 endpoint + hasKey:false，**且不是错误**', () async {
      final svc = SearchConfigService(store: _MemoryStore());
      final cfg = await svc.read();
      expect(cfg.endpoint, '');
      expect(cfg.hasKey, isFalse);
    });
  });

  group('② 掩码规则', () {
    test('★★★ 长 Key：保留 sk- 前缀与尾部 4 位', () {
      expect(SearchConfigService.maskKey(useKey), 'sk-***abcd');
    });

    test('无连字符的长 Key：只留尾部 4 位', () {
      expect(SearchConfigService.maskKey('abcdefghijklmnop'), '***mnop');
    });

    test('★★★ 长度 ≤ 8 全掩（留尾巴就等于把短 Key 泄完）', () {
      expect(SearchConfigService.maskKey('sk-1234'), '***', // 7 位
          reason: '7 位 Key 若留 4 位尾，只剩 3 位需要猜');
      expect(SearchConfigService.maskKey('abcdefgh'), '***', // 恰好 8 位
          reason: '边界取"≤"：8 位留 4 位尾就暴露一半');
    });

    test('长度 9 才开始露尾（差一位的另一侧边界）', () {
      expect(SearchConfigService.maskKey('abcdefghi'), '***fghi');
    });

    test('空 Key ⇒ 空串（"没有"必须和"有但看不见"区分开）', () {
      expect(SearchConfigService.maskKey(''), '');
      expect(SearchConfigService.maskKey('   '), '');
    });

    test('★★★ masked() 端到端：endpoint 脱敏；遗留 Key 被迁移清掉', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      // 上一版本留下的 Key（免鉴权版本必须清掉，不能显示成"有 Key"）
      store.data[ContractSearch.apiKeyKey] = useKey;
      await svc.save('https://api.example.com/search?token=SHOULD_NOT_SHOW');

      final m = await svc.masked();
      expect(m.endpoint, 'https://api.example.com/search',
          reason: 'query 里可能有 token，回显时必须丢掉');
      expect(m.keyMasked, '', reason: '免鉴权版本永远显示"没有 Key"');
      expect(store.data.containsKey(ContractSearch.apiKeyKey), isFalse);
    });

    test('masked() 在没配 Key 时 keyMasked 为空串', () async {
      final svc = SearchConfigService(store: _MemoryStore());
      await svc.save('https://api.example.com/search');
      final m = await svc.masked();
      expect(m.keyMasked, '');
      expect(m.endpoint, 'https://api.example.com/search');
    });

    test('masked() 在完全没配时 endpoint 也是空串', () async {
      final m = await SearchConfigService(store: _MemoryStore()).masked();
      expect(m.endpoint, '');
      expect(m.keyMasked, '');
    });
  });

  group('③ 非法 endpoint 必须拒绝（并给一句人话）', () {
    // key = 用例输入，value = 这条用例在测什么（写进 test 名，红的时候好定位）
    const bad = <String, String>{
      'ftp://example.com/s': '非 http(s) scheme',
      'file:///etc/passwd': 'file 协议（本地文件读取口子）',
      'javascript:alert(1)': 'javascript 伪协议',
      '': '空串',
      '   ': '全空白',
      'http://': '有 scheme 没主机',
      'http:/only-path': '只有 scheme 与路径',
      'example.com/search': '没有 scheme',
      'http://exa mple.com/s': '主机名里有空格',
      'https://user:pass@api.example.com/s': '把凭据写进 URL',
    };

    for (final entry in bad.entries) {
      test('★★★ 拒绝：${entry.value}（`${entry.key}`）', () async {
        final store = _MemoryStore();
        final svc = SearchConfigService(store: store);

        final r = await svc.save(entry.key, key: useKey);

        expect(r.ok, isFalse);
        expect(r.code, ContractSearch.errInvalidEndpoint);
        expect(r.message.trim(), isNotEmpty, reason: '拒绝必须说人话，不能只给错误码');
        expect(r.message.contains(useKey), isFalse, reason: '提示里不能带 Key');
        // 拒绝 = 一个字节都没写进去（不能"报了错但已经存了一半"）
        expect(store.data, isEmpty);
        expect(store.writes, isEmpty);
      });
    }

    test('static 校验函数：合法地址回 null，非法回原因', () {
      expect(SearchConfigService.endpointRejection('https://a.example.com/s'),
          isNull);
      expect(SearchConfigService.endpointRejection('http://127.0.0.1:8080/s'),
          isNull);
      expect(SearchConfigService.endpointRejection('ftp://a.example.com/s'),
          isNotNull);
      expect(SearchConfigService.endpointRejection('http://'), isNotNull);
    });
  });

  group('④ clear()', () {
    test('★★★ clear 之后 read 为空且 hasKey:false（且不是错误）', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      await svc.save('https://api.example.com/search', key: useKey);

      await svc.clear();

      final cfg = await svc.read();
      expect(cfg.endpoint, '');
      expect(cfg.hasKey, isFalse);
      expect(store.data, isEmpty, reason: 'Key 必须一起清掉，不能只清 endpoint');
    });

    test('clear 幂等：本来就空也不炸', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      await svc.clear();
      await svc.clear();
      expect(store.data, isEmpty);
    });

    test('clear 之后 masked() 也回到空', () async {
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      await svc.save('https://api.example.com/search', key: useKey);
      await svc.clear();
      final m = await svc.masked();
      expect(m.endpoint, '');
      expect(m.keyMasked, '');
    });
  });

  group('⑤ 存储异常 ≠ 未配置', () {
    test('★★★ read 时存储抛异常 ⇒ 抛 SearchConfigException，不许回"未配置"', () async {
      final store = _MemoryStore()..throwOnRead = StateError('keystore boom');
      final svc = SearchConfigService(store: store);

      Object? caught;
      ({String endpoint, bool hasKey})? value;
      try {
        value = await svc.read();
      } catch (e) {
        caught = e;
      }

      expect(value, isNull,
          reason: '读失败若返回 (endpoint:"", hasKey:false)，设置页会显示"未配置"——掩盖真问题');
      expect(caught, isA<SearchConfigException>());
      expect((caught! as SearchConfigException).message,
          contains('读取搜索服务配置失败'));
      expect((caught as SearchConfigException).message, contains('不是"未配置"'));
    });

    test('masked() 读异常同样抛（不能静默显示成"没配"）', () async {
      final store = _MemoryStore()..throwOnRead = StateError('boom');
      final svc = SearchConfigService(store: store);
      expect(svc.masked, throwsA(isA<SearchConfigException>()));
    });

    test('★ save 写异常 ⇒ 失败结果 + 人话（不抛，设置页要就地提示）', () async {
      final store = _MemoryStore()..throwOnWrite = StateError('disk full');
      final svc = SearchConfigService(store: store);

      final r = await svc.save('https://api.example.com/search');
      expect(r.ok, isFalse);
      expect(r.message, contains('保存搜索服务配置失败'));
      expect(r.message, contains('未生效'));
      // 写失败 ⇒ 存储里不该留下半套配置
      expect(store.data, isEmpty);
    });

    test('★ clear 删异常 ⇒ 抛（凭据没删掉不能被当成成功）', () async {
      final store = _MemoryStore()..throwOnDelete = StateError('boom');
      final svc = SearchConfigService(store: store);
      expect(svc.clear, throwsA(isA<SearchConfigException>()));
    });

    test('异常里带不上 Key 明文（存储实现若把值塞进 message 也不行）', () async {
      const secret = 'sk-DO-NOT-LEAK-9f2a';
      final store = _MemoryStore();
      final svc = SearchConfigService(store: store);
      await svc.save('https://api.example.com/search', key: secret);

      // 故意造一个"把值也吐进 message"的病态异常
      store.throwOnRead = StateError('failed to read value $secret');
      Object? caught;
      try {
        await svc.read();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<SearchConfigException>());
      expect(caught.toString().contains(secret), isFalse,
          reason: '异常消息是唯一可能被日志打出去的地方');
    });
  });

  group('⑥ 脱敏：toString / 错误消息 / 回显', () {
    test('★★★ toString 不含 Key 明文，也不含 endpoint 的 query', () async {
      const secret = 'sk-1234567890abcd';
      final store = _MemoryStore();
      // 模拟上一版本遗留的 Key：免鉴权版本必须保证它进不了任何输出
      store.data[ContractSearch.apiKeyKey] = secret;
      final svc = SearchConfigService(store: store);
      await svc.save('https://api.example.com/search?token=URL_SECRET_42');

      final s = svc.toString();
      expect(s.contains(secret), isFalse, reason: 'Key 绝不能进日志');
      expect(s.contains('URL_SECRET_42'), isFalse, reason: 'endpoint 的 query 里可能有 token');
      expect(s.contains('api.example.com'), isTrue, reason: '仍要能看出用的是哪家服务');
      expect(s.contains('https://'), isTrue);
    });

    test('未配置时 toString 也不炸、不明说成"空地址"', () {
      final svc = SearchConfigService(store: _MemoryStore());
      expect(svc.toString(), contains('未配置'));
    });

    test('redactEndpoint：保留 scheme+host+port+path，丢掉 query/fragment', () {
      expect(
        SearchConfigService.redactEndpoint(
            'https://api.example.com:8443/search?api_key=SECRET#frag'),
        'https://api.example.com:8443/search',
      );
      expect(SearchConfigService.redactEndpoint('http://127.0.0.1:9/s'),
          'http://127.0.0.1:9/s');
      expect(SearchConfigService.redactEndpoint(''), '');
      // 解析不了的整段打掉（宁可少显示，别把来路不明的串写进日志）
      expect(SearchConfigService.redactEndpoint('not a url'), '***');
      expect(SearchConfigService.redactEndpoint('ftp://a.example.com/x'), '***');
    });
  });

  group('⑦ 装配层：buildDeviceCapabilities(searchEndpoint:)', () {
    test('★★★ 不传 searchEndpoint ⇒ 与旧行为字节等价（明确失败"未配置搜索服务"）',
        () async {
      const legacy = DeviceWebCapability();

      final a = await buildDeviceCapabilities(workspaceRoot: '/tmp/ws')
          .web!
          .search('heracles');
      final b = await buildDeviceCapabilities(
        workspaceRoot: '/tmp/ws',
        searchEndpoint: '',
      ).web!.search('heracles');
      final c = await legacy.search('heracles');

      expect(a, isA<CapabilityFailure>());
      expect(b, isA<CapabilityFailure>());
      expect(c, isA<CapabilityFailure>());
      expect((a as CapabilityFailure).reason, (c as CapabilityFailure).reason);
      expect((b as CapabilityFailure).reason, c.reason);
      expect(a.isRetryable, c.isRetryable);
      expect(b.isRetryable, c.isRetryable);
      expect(a.reason, contains('未配置搜索服务'));
    });

    test('★ 传了 endpoint ⇒ 真的注入到底层能力（不再报"未配置"）', () async {
      // 用回环地址：它在发请求前就会被 SSRF 闸拒掉 ⇒ 测试不出网、可重复。
      final caps = buildDeviceCapabilities(
        workspaceRoot: '/tmp/ws',
        searchEndpoint: 'http://127.0.0.1:9/search',
      );
      final r = await caps.web!.search('heracles');

      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason.contains('未配置搜索服务'), isFalse,
          reason: 'endpoint 没被传下去 ⇒ 说明装配漏接（这正是本次要修的洞）');
    });

    test('includeWeb:false 时 web 仍为 null（旧语义不变）', () {
      final caps = buildDeviceCapabilities(
        workspaceRoot: '/tmp/ws',
        includeWeb: false,
        searchEndpoint: 'https://api.example.com/search',
      );
      expect(caps.web, isNull);
    });
  });

  group('⑧ 免鉴权收敛（本轮裁定：明确不支持，不留半截）', () {
    test('★★★ 拒绝文案直接可上屏（说明为什么 + 用户该怎么做）', () async {
      final svc = SearchConfigService(store: _MemoryStore());
      final saved = await svc.save('https://api.example.com/s', key: 'sk-abc');

      expect(saved.ok, isFalse);
      expect(saved.message, contains('免鉴权'));
      expect(saved.message, contains('不会被保存'),
          reason: '必须说清"Key 没存"，否则用户以为鉴权已生效');
    });

    test('★★★ 遗留 Key 在 masked() 里同样被清（两条读路径口径一致）', () async {
      final store = _MemoryStore();
      store.data[ContractSearch.apiKeyKey] = useKey;
      final svc = SearchConfigService(store: store);

      final m = await svc.masked();
      expect(m.keyMasked, '');
      expect(store.data.containsKey(ContractSearch.apiKeyKey), isFalse);
    });

    test('★ userInfo 拒绝文案不再指向"Key 一栏"（那一栏已经不存在）', () {
      final r = SearchConfigService.endpointRejection(
          'https://user:pass@api.example.com/s');
      expect(r, isNotNull);
      expect(r!, contains('免鉴权'));
      expect(r.contains('请填到 Key 一栏'), isFalse,
          reason: '旧文案会引导用户去找一个已经移除的输入框');
    });

    test('★ 契约常量钉死：keyHeaderSupported=false（下一轮要改的就是它）', () {
      expect(ContractSearch.keyHeaderSupported, isFalse);
      expect(ContractSearch.errKeyUnsupported, 'E_SEARCH_KEY_UNSUPPORTED');
      expect(ContractSearch.keyUnsupportedMessage, contains('免鉴权'));
    });
  });
}
