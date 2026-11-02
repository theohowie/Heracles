/// **搜索服务配置的安全存储**（V0.4 F4，2026-11-02；契约见
/// `docs/INTERFACE.md` §N16.4）。
///
/// ## 这个文件解决什么问题
///
/// `DeviceWebCapability.searchEndpoint` 从 2026-11-02 起就存在，但**没有任何
/// 地方能设置它**：装配函数里写死的是 `const DeviceWebCapability()`，于是
/// `web_search` 永远回「未配置搜索服务」。本文件补上"配置从哪来"这一环，
/// 并且保证配置（尤其是 API Key）**不落明文、不进日志**。
///
/// ## 三条硬约束（为什么这么设计）
///
/// 1. **免鉴权收敛（2026-11-02 裁定）**：本版本**不支持鉴权** ——
///    `DeviceWebCapability` 没有自定义请求头的位置，存了 Key 也发不出去。
///    所以：带 Key 保存**整笔拒绝**（[ContractSearch.errKeyUnsupported]）、
///    上一版本遗留的 Key 在读取时**迁移清掉**。宁可明确说"不支持"，
///    也不留一个"已保存却不生效"的半截功能。
///    下一轮给能力层加 `headers` 缝后，翻 [ContractSearch.keyHeaderSupported]
///    并恢复 Key 的保存路径。
/// 2. **存储访问是可注入的**（[SearchCredStore]）：`FlutterSecureStorage`
///    在单测里没有平台通道，真读真写会直接抛 `MissingPluginException`。
///    把存储抽象出来，测试就能塞内存实现，验证的是**本文件的分支与脱敏
///    逻辑**，而不是"Android KeyStore 能不能用"（那是平台的事）。
/// 3. **读失败 ≠ 没配置**：secure storage 抛异常（KeyStore 损坏、无权限…）
///    与"用户还没配过"是两件事。前者会抛 [SearchConfigException]，
///    后者回 `endpoint: '' / hasKey: false`。混成一种，设置页会把
///    "读不出来"显示成"未配置"，用户重填一遍还是坏 —— 掩盖了真问题。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:heracles_backend/heracles_backend.dart';

/// **凭据存储抽象**（三个动作：读、写、删）。
///
/// 只暴露本文件用得到的最小面：没有"列全部键"、没有"读全部" ——
/// 那些接口会把别的凭据（GitHub token 等）带进来，扩大泄露面。
abstract interface class SearchCredStore {
  /// 读一个值。**不存在** 回 `null`（不是空串）。
  ///
  /// 抛异常 = 存储本身坏了（无权限 / KeyStore 损坏 / 无平台通道），
  /// 调用方**必须**把它和"没配过"区分开。
  Future<String?> read(String key);

  /// 写一个值（覆盖）。
  Future<void> write(String key, String value);

  /// 删一个键（不存在时静默成功）。
  Future<void> delete(String key);
}

/// [SearchCredStore] 的真实实现：`flutter_secure_storage`。
///
/// 为什么不用 `SharedPreferences`：Android 上它是**明文 XML**，
/// 任何拿到 `/data/data/<pkg>/shared_prefs` 的途径（root、备份、
/// 错误导出）都能读；search endpoint 里常常带 token。
class SecureSearchCredStore implements SearchCredStore {
  const SecureSearchCredStore({
    this.storage = const FlutterSecureStorage(),
  });

  /// 底层实现（留成字段是为了让平台侧选项可替换：Android 加密选项、
  /// 测试替身…）。**不要**把它暴露给 UI 层当作"读全部凭据"的入口。
  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// **保存结果**：成功，或"拒了/写不进去 + 一句人话"。
///
/// 为什么不用异常：非法 endpoint 是**用户输入错**（设置页要就地提示，
/// 不该冒泡成崩溃）；而 [SearchConfigService.read] 的失败是**环境坏**，
/// 那是异常。两类错误分开表达，调用方不用猜。
class SearchSaveResult {
  const SearchSaveResult._(this.ok, this.message, this.code);

  /// 成功。
  const SearchSaveResult.ok() : this._(true, '', null);

  /// 失败。[message] 是直接能给用户看的中文；[code] 是机器可判的码
  /// （非法 endpoint 用 [ContractSearch.errInvalidEndpoint]）。
  const SearchSaveResult.failed(String message, {String? code})
      : this._(false, message, code);

  final bool ok;

  /// 失败原因（人话）；成功时为空串。
  final String message;

  /// 机器码；成功或"非契约内错误"时为 `null`。
  final String? code;

  @override
  String toString() =>
      ok ? 'SearchSaveResult.ok()' : 'SearchSaveResult.failed($code): $message';
}

/// **配置读写失败的异常**（存储层坏 / 读不出来）。
///
/// [message] 已脱敏：只有 scheme+host+path 与错误类型，**永远不含 Key**。
class SearchConfigException implements Exception {
  const SearchConfigException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'SearchConfigException(${code ?? '-'}): $message';
}

/// **搜索服务配置服务**（纯 Dart，无通道方法）。
///
/// 用法：
/// ```dart
/// final svc = SearchConfigService();          // 构造零副作用
/// final saved = await svc.save('https://api.example.com/search', key: 'sk-...');
/// if (!saved.ok) showError(saved.message);
/// final cfg = await svc.read();               // (endpoint, hasKey)
/// final shown = await svc.masked();           // 设置页回显：sk-***abcd
/// ```
class SearchConfigService {
  SearchConfigService({SearchCredStore? store})
      : _store = store ?? const SecureSearchCredStore();

  final SearchCredStore _store;

  /// 最近一次读/写到的 endpoint（**未脱敏**，仅用于 [toString] 的脱敏输出）。
  ///
  /// 为什么要缓存：`toString` 是同步的，不能去 await 存储；而日志里有
  /// "当前指向哪个搜索服务"对排障很关键（脱敏后显示）。
  /// 它是**可过期**的展示缓存，不是配置的真相来源 —— 读真相一律走 [read]。
  String _lastEndpoint = '';

  /// 读当前配置。
  ///
  /// 返回 `(endpoint: '', hasKey: false)` = **还没配**（不是错误）。
  /// 存储读不出来 ⇒ 抛 [SearchConfigException]（**不要**当成未配置）。
  ///
  /// **免鉴权收敛（2026-11-02 裁定）**：本版本不支持把 Key 注入请求头
  /// （[ContractSearch.keyHeaderSupported] = false）⇒ 读到遗留 Key 会**顺手删掉**
  /// 并如实回 `hasKey:false`。理由：发不出去的凭据留在存储里，只会让人以为
  /// "鉴权已生效"，然后对着 401 排查半天 —— 那是半截功能，不是兼容。
  Future<({String endpoint, bool hasKey})> read() async =>
      _readMigrateKey();

  /// [read] / [masked] 共用的读取 + 遗留 Key 迁移。
  Future<({String? endpoint, String? key})> _readRawMigrating() async {
    final String? ep;
    final String? key;
    try {
      ep = await _store.read(ContractSearch.endpointKey);
      key = await _store.read(ContractSearch.apiKeyKey);
    } catch (e) {
      throw SearchConfigException(
        '读取搜索服务配置失败（存储不可用）：${_reasonOf(e)}。'
        '这不是"未配置"——请检查系统安全存储/权限，或重装应用。',
      );
    }
    if ((key ?? '').trim().isNotEmpty) {
      // 迁移：删除发不出去的遗留凭据（失败不阻断 —— 下次读还会再试）
      try {
        await _store.delete(ContractSearch.apiKeyKey);
      } catch (_) {}
      return (endpoint: ep, key: null);
    }
    return (endpoint: ep, key: key);
  }

  Future<({String endpoint, bool hasKey})> _readMigrateKey() async {
    final r = await _readRawMigrating();
    _lastEndpoint = (r.endpoint ?? '').trim();
    return (endpoint: _lastEndpoint, hasKey: false);
  }

  /// 保存配置。
  ///
  /// - [endpoint] 必须是 `http://` / `https://` 且带主机名，否则**拒绝保存**
  ///   （回 [ContractSearch.errInvalidEndpoint] + 人话原因）。
  /// - [key] **本版本一律拒绝**（[ContractSearch.keyHeaderSupported] = false）：
  ///   能力层没有自定义请求头的位置，存了也发不出去。拒绝是**整笔**的 ——
  ///   endpoint 也不会写（绝不出现"已保存但不生效"的半截状态）。
  ///   空白 [key] 视为没传（向后兼容旧调用方）。
  Future<SearchSaveResult> save(String endpoint, {String? key}) async {
    // 先校验 endpoint（主字段），再谈 Key —— 地址本身就是错的时，
    // "不支持鉴权"是噪音，用户该先看到地址哪里不对。
    final trimmed = endpoint.trim();
    final rejection = endpointRejection(trimmed);
    if (rejection != null) {
      return SearchSaveResult.failed(
        rejection,
        code: ContractSearch.errInvalidEndpoint,
      );
    }
    final newKey = key?.trim() ?? '';
    if (newKey.isNotEmpty) {
      return SearchSaveResult.failed(
        ContractSearch.keyUnsupportedMessage,
        code: ContractSearch.errKeyUnsupported,
      );
    }
    try {
      await _store.write(ContractSearch.endpointKey, trimmed);
    } catch (e) {
      return SearchSaveResult.failed(
        '保存搜索服务配置失败（存储不可用）：${_reasonOf(e)}。'
        '配置未生效，请稍后重试。',
      );
    }
    _lastEndpoint = trimmed;
    return const SearchSaveResult.ok();
  }

  /// 清空配置（endpoint 与 Key 一起删）。
  ///
  /// 先删 Key 再删 endpoint：万一第二步失败，留下的是"有地址没凭据"，
  /// 而不是"凭据还在、用户以为已经清掉了"。
  Future<void> clear() async {
    try {
      await _store.delete(ContractSearch.apiKeyKey);
      await _store.delete(ContractSearch.endpointKey);
    } catch (e) {
      throw SearchConfigException('清除搜索服务配置失败：${_reasonOf(e)}。');
    }
    _lastEndpoint = '';
  }

  /// 设置页回显用的**脱敏**视图。
  ///
  /// - `endpoint`：只留 `scheme://host[:port]/path`，**丢掉 query / fragment /
  ///   userinfo**。为什么不回全量：endpoint 的 query 里经常塞 token
  ///   （`?api_key=...`），回显到 UI 就等于把它摊在截图里；要编辑请用 [read]
  ///   拿到原值自己填进输入框（输入框本身可以做成密码样式）。
  /// - `keyMasked`：**本版本恒为空串** —— 免鉴权收敛（2026-11-02）后没有
  ///   任何路径能存进 Key，遗留 Key 会在读取时被迁移清掉。保留这个字段是
  ///   为了下一轮加 `headers` 缝时 UI 形状不用再变。
  ///
  /// 存储读不出来 ⇒ 抛 [SearchConfigException]（同 [read]）。
  Future<({String endpoint, String keyMasked})> masked() async {
    final r = await _readRawMigrating();
    _lastEndpoint = (r.endpoint ?? '').trim();
    return (
      endpoint: redactEndpoint(_lastEndpoint),
      keyMasked: maskKey(r.key ?? ''),
    );
  }

  // ==========================================================================
  // 纯函数：校验 / 脱敏（单独暴露，测试可直接钉住规则）
  // ==========================================================================

  /// 校验 endpoint。**合法回 `null`，非法回一句人话原因。**
  ///
  /// 为什么规则这么严：
  /// - 只允许 `http` / `https` —— `ftp://`、`file://`、`javascript:` 之类
  ///   要么根本发不出请求，要么就是 SSRF/注入的口子；
  /// - 必须有主机名 —— `http://` 能 `Uri.parse` 成功但 host 为空，
  ///   存下来只会在调用时变成一个莫名其妙的失败；
  /// - 主机名里不许有 `%`（含空格等被编码进去的字符）—— Dart 的
  ///   `Uri.parse` 很宽容，`http://exa mple.com` 会变成 host
  ///   `exa%20mple.com`，那不是一台真实主机；
  /// - 不许把凭据写进 URL（`https://user:pass@host`）—— 凭据有专门的
  ///   Key 字段，塞进 URL 就会随日志/错误文案一起被打印出去。
  static String? endpointRejection(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '搜索服务地址不能为空。';
    final uri = Uri.tryParse(t);
    if (uri == null) return '搜索服务地址不是合法的 URL（无法解析）。';
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      final shown = uri.scheme.isEmpty ? '空' : uri.scheme;
      return '搜索服务地址必须以 http:// 或 https:// 开头'
          '（当前 scheme 是「$shown」）。';
    }
    if (!uri.hasAuthority || uri.host.isEmpty) {
      return '搜索服务地址缺少主机名（形如 https://api.example.com/search）。';
    }
    if (uri.host.contains('%')) {
      return '搜索服务地址的主机名不合法（不能含空格或转义字符）。';
    }
    if (uri.userInfo.isNotEmpty) {
      return '不要把账号密码写进 URL（当前版本仅支持免鉴权搜索服务）。';
    }
    return null;
  }

  /// endpoint 脱敏：只保留 `scheme://host[:port]/path`。
  ///
  /// 解析不了 / 不是 http(s) ⇒ 整段打掉（回 `***`）—— 宁可少显示，
  /// 也不要把一段来路不明的字符串原样写进日志。
  static String redactEndpoint(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    final uri = Uri.tryParse(t);
    if (uri == null) return '***';
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') || uri.host.isEmpty) {
      return '***';
    }
    // `origin` 恰好是 scheme+host(:非默认端口)，且不含 userInfo。
    return '${uri.origin}${uri.path}';
  }

  /// Key 掩码。
  ///
  /// ⚠️ **本版本生产路径到不了这里**：免鉴权收敛（2026-11-02）后没有任何
  /// 路径能存进 Key，遗留 Key 在读取时就被清掉了。保留这个纯函数是因为
  /// 下一轮给 `DeviceWebCapability` 加 `headers` 缝时要用（届时 UI 形状
  /// 与掩码规则都不用改）—— 单测继续钉住它，防止到时候规则漂移。
  ///
  /// - 空 ⇒ `''`（没有 Key，不是"有但看不见"）；
  /// - 长度 ≤ [ContractSearch.maskFullBelow] ⇒ `***`（再留尾部就等于把
  ///   短 Key 全泄了）；
  /// - 否则保留**常见前缀**（第一个 `-` 之前，且不超过 4 字符，例如 `sk-`）
  ///   与尾部 [ContractSearch.maskVisibleTail] 位 ⇒ `sk-***abcd`。
  ///
  /// 为什么保留前缀：一眼看出"这是哪家的 Key"，排障时有用；前缀本身
  /// 不承载熵（`sk-` 是公开的格式约定，不是秘密）。
  static String maskKey(String key) {
    final k = key.trim();
    if (k.isEmpty) return '';
    if (k.length <= ContractSearch.maskFullBelow) return '***';
    final tail = k.substring(k.length - ContractSearch.maskVisibleTail);
    final dash = k.indexOf('-');
    final prefix = (dash > 0 && dash <= 4) ? k.substring(0, dash + 1) : '';
    return '$prefix***$tail';
  }

  /// **日志友好**：只有脱敏后的 endpoint，**永远没有 Key**。
  ///
  /// 为什么连 `hasKey` 都不打：它需要一次异步读取，而 `toString` 是同步的；
  /// 用缓存值会让日志说谎。endpoint 已经足够定位"用的哪家搜索服务"。
  @override
  String toString() {
    final ep = _lastEndpoint;
    return 'SearchConfigService(endpoint: '
        '${ep.isEmpty ? '未配置' : redactEndpoint(ep)})';
  }

  /// 把异常压成**类型名**（就这么多，故意不带 message）。
  ///
  /// ## 为什么连异常消息都不打
  ///
  /// 存储实现把值塞进异常消息并不是天方夜谭（"failed to write
  /// heracles.search.api_key=sk-xxx" 这种手写日志很常见）。一旦这句话进了
  /// 我们的错误文案，它就会跟着 UI/日志/崩溃上报一起出去，而日志是**洗不掉**
  /// 的。丢掉 message 的代价只是排障少一句话，换来的是"任何实现都不会
  /// 通过这条路把 Key 泄出去" —— 这个交换很划算。
  ///
  /// 类型名仍然有用：`PlatformException` = 平台层拒绝（权限/通道），
  /// `StateError`/`ArgumentError` = 代码或数据问题，选择方向不同。
  static String _reasonOf(Object e) => e.runtimeType.toString();
}
