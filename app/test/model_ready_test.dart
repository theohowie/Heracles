import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart';

/// **首启引导判据**（2026-10-19）—— `AppSettings.hasUsableProvider` 的门禁。
///
/// 这条判据同时决定 UI 是否显示"还没有配置模型"提示条。它必须与
/// `AgentBridge` 发送前的校验一致：
/// 云端没 Key = 不可用；回环/局域网端点允许不填 Key。
void main() {
  ModelProviderConfig cfg({
    String id = 'p1',
    String baseUrl = 'https://api.example.com/v1',
    String apiKey = '',
    bool official = false,
  }) =>
      ModelProviderConfig(
        id: id,
        name: id,
        baseUrl: baseUrl,
        model: 'test-model',
        apiKey: apiKey,
        isOfficialAccount: official,
      );

  test('一个 provider 都没有 ⇒ 不可用', () {
    final s = AppSettings(providers: const []);
    expect(s.hasUsableProvider, isFalse);
  });

  test('云端有 Key ⇒ 可用', () {
    final s = AppSettings(providers: [cfg(apiKey: 'sk-test')]);
    expect(s.hasUsableProvider, isTrue);
  });

  test('云端有 baseUrl 但没 Key ⇒ 不可用（不能等 401 才发现）', () {
    final s = AppSettings(providers: [cfg()]);
    expect(s.hasUsableProvider, isFalse);
  });

  test('回环/局域网端点不填 Key 也算可用', () {
    final s = AppSettings(providers: [cfg(baseUrl: 'http://192.168.1.5:8080/v1')]);
    expect(s.hasUsableProvider, isTrue);
  });

  test('baseUrl 为空 ⇒ 不可用（哪怕有 Key）', () {
    final s = AppSettings(providers: [cfg(baseUrl: '  ', apiKey: 'sk-test')]);
    expect(s.hasUsableProvider, isFalse);
  });

  test('activeProviderId 指向已配置项 ⇒ 用它判断', () {
    final s = AppSettings(
      providers: [
        cfg(id: 'unused'),
        cfg(id: 'chosen', baseUrl: 'https://chosen.example/v1', apiKey: 'sk-x'),
      ],
      activeProviderId: 'chosen',
    );
    expect(s.effectiveProvider?.id, 'chosen');
    expect(s.hasUsableProvider, isTrue);
  });
}
