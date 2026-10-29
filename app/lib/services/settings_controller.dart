import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';

/// **API Key 的安全存储**（2026-10-14，FR-11.7 落地）。
///
/// ## 修的是什么
///
/// 用户原话：「下面的APIkey还是明文存储，修复，这个测试也不能这样明文吧？」
/// —— Key 之前随 provider JSON 明文写进 SharedPreferences
///（`/data/data/…/shared_prefs/FlutterSharedPreferences.xml`，
/// root 或 adb backup 可直接读出）。
///
/// ## 方案：Key 与配置**分离存储**
///
/// | 内容 | 存储 | 为什么 |
/// |---|---|---|
/// | provider 配置（URL/模型/目录…） | SharedPreferences | 非敏感，调试友好 |
/// | **apiKey** | **flutter_secure_storage** | 底层 Android Keystore，硬件级加密 |
///
/// SharedPreferences 里只留一个**哨兵** `"__secure__"`：
/// 既标记"Key 在安全存储里"，又不泄漏任何内容。
///
/// ## 为什么不用手写 Keystore 代码
///
/// `flutter_secure_storage` 是社区标准封装（Android 用
/// EncryptedSharedPreferences/Keystore，iOS 用 Keychain），
/// 自写要处理密钥生成/轮换/多机型兼容 —— 引依赖 > 重造轮子。
class SecureKeyStore {
  /// const 构造 —— 调用方可以 `static const _secureKeys = SecureKeyStore();`
  const SecureKeyStore();

  /// SharedPreferences 里代替真 Key 的哨兵 —— 定义在 models（见 [kSecureSentinel]）
  static const sentinel = kSecureSentinel;

  static final _storage = FlutterSecureStorage(
    // v11 默认即强加密（AES-GCM 数据 + RSA OAEP 包裹密钥，API 23+）——
    // 用显式 defaultOptions 而不是依赖隐式默认（可读性 + 未来默认变更时不被动）
    aOptions: AndroidOptions.defaultOptions,
  );

  static String _keyOf(String providerId) => 'api_key/$providerId';

  Future<void> write(String providerId, String apiKey) {
    // ★ 绝不把哨兵写进 Keystore（2026-10-14 真机 bug）★
    //
    // 场景：`updateProvider` 收到的 provider 是从 SharedPreferences
    // 反序列化来的，它的 `apiKey` 字段是哨兵 `"__secure__"`（不是真 Key）。
    // 若无脑写入，Keystore 里就存了哨兵字符串 —— 之后读回来
    // 会把它当 Key 发出去（必然 401），而且"看起来已配置"。
    //
    // 正确语义：**空 或 哨兵 = 没有真 Key = 删除条目**（而不是写垃圾）
    if (apiKey.isEmpty || apiKey == sentinel) {
      return _storage.delete(key: _keyOf(providerId));
    }
    return _storage.write(key: _keyOf(providerId), value: apiKey);
  }

  Future<String> read(String providerId) =>
      _storage.read(key: _keyOf(providerId)).then((v) {
        // ★ 读到哨兵等于没读到（历史 bug 可能写进过）——
        //   绝不能返回哨兵，它会被当 Key 发出去
        if (v == null || v == sentinel) return '';
        return v;
      });

  Future<void> delete(String providerId) =>
      _storage.delete(key: _keyOf(providerId));
}

/// 设置的状态容器 + 持久化。
///
/// ## 为什么不用 Riverpod / Provider
///
/// 设置项少（10 个标量 + 一个列表），且只有一条数据流：
/// `SettingsScreen 改 → 全 App 重建`。
/// **为一个 ValueNotifier 引入状态管理框架不划算**（YAGNI）。
///
/// ## 为什么必须持久化
///
/// 用户改了"完全访问"权限、填了 API Key，重启后回到默认值 ——
/// 那是**功能没做成**，不是界面问题。
class SettingsController extends ValueNotifier<AppSettings> {
  SettingsController._(super.initial);

  static const _kPermission = 'permission';
  static const _kLanguage = 'language';
  static const _kAppearance = 'appearance';
  static const _kThemeStyle = 'themeStyle';
  static const _kFontSize = 'fontSize';
  static const _kStepDetail = 'stepDetail';
  /// 推理等级（2026-10-12，S4/S5）—— 未写过时默认 `auto`
  static const _kReasoningLevel = 'reasoningLevel';
  /// 用户选定的后端 id（2026-10-12）—— 未写过时走自动选择
  static const _kActiveProvider = 'activeProviderId';
  static const _kBusySend = 'busySend';
  static const _kAccentHex = 'accentHex';
  static const _kGlassEffect = 'glassEffect';
  /// **单次任务最大轮次**（2026-10-18，`docs/27` P0-1 / ADR-033）
  static const _kMaxTurns = 'maxTurns';
  static const _kProviders = 'providers';

  /// **全局记忆开关**（2026-10-29，INTERFACE §N12.9；默认 true）。
  static const _kMemoryGlobalEnabled = 'memoryGlobalEnabled';

  /// **记忆解析池化**（2026-10-29，§N12.9；默认 false）。
  static const _kMemoryPooling = 'memoryPooling';

  static late SharedPreferences _prefs;

  /// **API Key 的安全存储**（FR-11.7）—— 实例在 [load] 前即可用
  static const _secureKeys = SecureKeyStore();

  // ⚠️ 上面这行要求 SecureKeyStore 的构造是 const —— 见其类定义。
  //    若将来给它加实例字段，这里要改成 `static final`。

  /// **决定这个 provider 的 apiKey 该是什么**（2026-10-14，FR-11.7）。
  ///
  /// 优先级：安全存储 > JSON 明文（并顺手迁移）> 空。
  ///
  /// ## 为什么单独抽出来
  ///
  /// 这段判断有**三个分支 + 一个副作用（写 Keystore）**，
  /// 内联在列表推导里既难读又容易改错 —— 而它恰恰是
  /// "Key 到底能不能用"的唯一决策点。
  ///
  /// @param migrated 收集"刚迁移进 Keystore 的 provider id"，
  ///   调用方据此决定要不要回写 SharedPreferences
  static String _resolveKey(
    ModelProviderConfig p,
    String fromSecure,
    List<String> migrated,
  ) {
    // ① 安全存储里有 → 用它（正常路径）
    if (fromSecure.isNotEmpty) return fromSecure;

    // ② JSON 里是**明文**（老版本遗留）→ 迁移进 Keystore
    //    ⚠️ 必须是"非空且不是哨兵"才是真明文
    final raw = p.apiKey;
    if (raw.isNotEmpty && raw != kSecureSentinel) {
      // 不 await：迁移是**尽力而为**的后台动作。
      // 失败也不影响本次使用（内存里已经有真 Key），
      // 而 await 会让启动路径多一次 Keystore 写入的延迟。
      unawaited(_secureKeys.write(p.id, raw));
      migrated.add(p.id);
      return raw;
    }

    // ③ 哨兵（说明"本该在安全存储里但没有"）或空 → 空
    //    **绝不能返回哨兵**，它会被当 Key 发出去（必然 401）
    return '';
  }

  /// 启动时调用一次。
  static Future<SettingsController> load() async {
    _prefs = await SharedPreferences.getInstance();

    final providersRaw = _prefs.getString(_kProviders);
    List<ModelProviderConfig> providers = AppSettings.defaultProviders;
    if (providersRaw != null && providersRaw.isNotEmpty) {
      try {
        final list = (jsonDecode(providersRaw) as List)
            .map((e) => ModelProviderConfig.fromJson(e as Map<String, dynamic>))
            .toList();
        if (list.isNotEmpty) providers = list;
      } catch (_) {
        // 解析失败就用默认值 —— 设置损坏不该让 App 起不来
      }
    }

    // ★ 从安全存储回填 API Key（2026-10-14，FR-11.7）——
    //   SharedPreferences 里只有哨兵 `"__secure__"`，真 Key 在 Keystore。
    //   并发读多个 Key：Future.wait 比串行快（Keystore 解密有开销）。
    try {
      final keys = await Future.wait(
        [for (final p in providers) _secureKeys.read(p.id)],
      );
      final migrated = <String>[];
      providers = [
        for (var i = 0; i < providers.length; i++)
          providers[i].copyWith(
            // ⚠️ 三种来源，优先级从高到低：
            //   1. 安全存储里的真 Key（正常路径）
            //   2. JSON 里的**明文**（老版本迁移场景 —— 真 Key，可用）
            //      → 顺手搬进 Keystore，之后 JSON 里只剩哨兵
            //   3. 其余情况 = 空（**绝不能把哨兵当 Key 用**：
            //      "__secure__" 发出去就是 401，而且会误导用户）
            apiKey: _resolveKey(providers[i], keys[i], migrated),
          ),
      ];
      // 迁移落盘：把老明文换成哨兵（只做一次）
      if (migrated.isNotEmpty) {
        await _prefs.setString(
          _kProviders,
          jsonEncode(providers.map((e) => e.toJson()).toList()),
        );
      }
    } catch (_) {
      // 安全存储读失败（极少见：系统级 Keystore 异常）——
      // 设置还能用，只是 Key 可能要重填。不让 App 崩。
      // ⚠️ 同样要把哨兵清掉，否则会被当 Key 用
      providers = [
        for (final p in providers)
          p.apiKey == kSecureSentinel ? p.copyWith(apiKey: '') : p,
      ];
    }

    // ★★★ 2026-10-19：清掉已废弃的「本地模型」provider（ADR-035 + 用户要求）★★★
    //
    // 本地后端（llama.cpp）早已删除，但老数据里还留着那条
    // `id=local / 本地模型 (llama.cpp) / qwen3.5-4b / 127.0.0.1:8080`，
    // 而且带着 `enabled:true` —— 模型选择器照样会列出来，选中即撞
    // Kotlin 侧「本地后端已删除」的装配期异常。这里**一次性**清掉，
    // 并清掉指向它的 `activeProviderId`（否则 UI 会显示一个悬空的选择）。
    //
    // 只删"手机上本机 llama.cpp"这一类（回环地址 + qwen3.5/llama 模型名）：
    // 用户自己的**局域网/自建端点**（192.168.x / 域名）不在此列，不能误删。
    final legacy = providers.where(_isLegacyLocalProvider).toList();
    if (legacy.isNotEmpty) {
      final legacyIds = legacy.map((p) => p.id).toSet();
      providers = providers.where((p) => !legacyIds.contains(p.id)).toList();
      if (providers.isEmpty) providers = AppSettings.defaultProviders;
      final active = _prefs.getString(_kActiveProvider);
      if (active != null && legacyIds.contains(active)) {
        await _prefs.remove(_kActiveProvider);
      }
      await _prefs.setString(
        _kProviders,
        jsonEncode(providers.map((e) => e.toJson()).toList()),
      );
    }

    final s = AppSettings(
      permission: _enumOf(PermissionMode.values, _prefs.getString(_kPermission),
          PermissionMode.workspaceAuto),
      language: _enumOf(
          AppLanguage.values, _prefs.getString(_kLanguage), AppLanguage.zh),
      appearance: _enumOf(AppAppearance.values,
          _prefs.getString(_kAppearance), AppAppearance.system),
      themeStyle: _enumOf(AppThemeStyle.values,
          _prefs.getString(_kThemeStyle), AppThemeStyle.bw),
      fontSize: _prefs.getDouble(_kFontSize) ?? 15,
      stepDetail: _enumOf(StepDetail.values, _prefs.getString(_kStepDetail),
          StepDetail.standard),
      // 认不出的名字 → auto（**与改造前行为一致**，不会让旧数据解析失败）
      reasoningLevel: _enumOf(ReasoningLevel.values,
          _prefs.getString(_kReasoningLevel), ReasoningLevel.auto),
      busySend: _enumOf(BusySendBehavior.values, _prefs.getString(_kBusySend),
          BusySendBehavior.queue),
      accentHex: _prefs.getInt(_kAccentHex) ?? 0xFFFF7A45,
      glassEffect: _prefs.getBool(_kGlassEffect) ?? true,
      // 最大轮次（2026-10-18，ADR-033）—— 脏值一律回落 `0`（自动）。
      //
      // ★ 为什么必须容错而不是直接 getInt：
      //   `0` = "跟随后端"（本地 8 / 云端 40）。一个超大或负数的脏值
      //   传下去就是"无限轮次"——云端会一直花钱、本地会一直烧设备，
      //   而用户看到的只是"怎么停不下来"。所以认不出的值必须**收窄**
      //   到合法档位，而不是原样透传。
      maxTurns: _maxTurnsOf(_prefs.getInt(_kMaxTurns)),
      // 记忆两组开关（2026-10-29，INTERFACE §N12.9）。
      // 未写过 ⇒ global 开（保住旧行为：换会话不失忆）、池化关（默认安全）。
      memoryGlobalEnabled: _prefs.getBool(_kMemoryGlobalEnabled) ?? true,
      memoryPooling: _prefs.getBool(_kMemoryPooling) ?? false,
      providers: providers,
      // 用户选定的后端 id（null = 没选过 → effectiveProvider 走自动顺序）。
      // 空串 = 曾选后清除 → 同样当 null 处理。
      activeProviderId: () {
        final v = _prefs.getString(_kActiveProvider);
        return (v == null || v.isEmpty) ? null : v;
      }(),
    );

    return SettingsController._(s);
  }

  static T _enumOf<T extends Enum>(List<T> values, String? name, T fallback) {
    if (name == null) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  /// **已废弃的「本地模型」配置**（2026-10-19，ADR-035 收尾）。
  ///
  /// 判据只认"跑在**这台手机上**的 llama.cpp"：
  /// 1. 内置那条的 id 就是 `local`；或者
  /// 2. 地址是回环（127.0.0.1 / localhost / 0.0.0.0）**且**模型名是 qwen3.5 / llama 一系。
  ///
  /// ⚠️ 局域网/自建端点（`192.168.x.x`、域名）**不算** —— 用户可能真的在用
  /// 电脑上的 llama.cpp 或中转服务，那不是"本地模型"，删了就是误伤。
  static bool _isLegacyLocalProvider(ModelProviderConfig p) {
    if (p.id == 'local') return true;
    final url = p.baseUrl.toLowerCase();
    final loopback = url.contains('127.0.0.1') ||
        url.contains('localhost') ||
        url.contains('0.0.0.0');
    if (!loopback) return false;
    final m = p.model.toLowerCase();
    return m.contains('qwen3.5') || m.contains('qwen-3.5') || m.contains('llama');
  }

  /// 最大轮次的**读取容错**（2026-10-18，ADR-033）。
  ///
  /// ## 规则：只认 [kMaxTurnsOptions] 里的值，其余一律 `0`（自动）
  ///
  /// 三类脏值都会被收起：
  /// · **缺失**（老版本没写过这个键）→ `0`，与改造前行为一致
  /// · **负数 / 0 以外的非法数** → `0`
  /// · **超大值**（比如手改 prefs 写了 `100000`）→ `0`，不是"照单全收"
  ///
  /// ⚠️ **不 clamp 到 `80`**：`80` 是**用户可选档位的上界**，
  /// 不是"程序允许的上界"。把 `100000` 悄悄改成 `80`，用户看到的是
  /// 一个他没选过的值 —— 那是**编造设置**。回落 `0`（自动）是诚实的：
  /// 它等于"这个值我们认不出，交回给后端默认"。
  static int _maxTurnsOf(int? raw) {
    if (raw == null) return 0;
    return kMaxTurnsOptions.contains(raw) ? raw : 0;
  }

  // ------------------------------------------------------------ 变更方法

  Future<void> setPermission(PermissionMode v) =>
      _apply(value.copyWith(permission: v), _kPermission, v.name);

  Future<void> setLanguage(AppLanguage v) =>
      _apply(value.copyWith(language: v), _kLanguage, v.name);

  Future<void> setAppearance(AppAppearance v) =>
      _apply(value.copyWith(appearance: v), _kAppearance, v.name);

  Future<void> setThemeStyle(AppThemeStyle v) =>
      _apply(value.copyWith(themeStyle: v), _kThemeStyle, v.name);

  Future<void> setFontSize(double v) => _apply(
      value.copyWith(fontSize: v.clamp(12, 20)), _kFontSize, v.clamp(12, 20));

  Future<void> setStepDetail(StepDetail v) =>
      _apply(value.copyWith(stepDetail: v), _kStepDetail, v.name);

  /// 设推理等级（2026-10-12，S4/S5）。
  ///
  /// ★ 必须持久化：用户"打开思考"是一次**显式的成本选择**
  /// （本地会慢、云端会贵）。重启后回到 auto 会让他以为设置没生效。
  Future<void> setReasoningLevel(ReasoningLevel v) =>
      _apply(value.copyWith(reasoningLevel: v), _kReasoningLevel, v.name);

  /// 选定后端（2026-10-12）—— 输入框模型选择框点选后记录。
  ///
  /// ★ 必须持久化：选了"电脑上的 llama-server"之后重启，
  /// 静默回落到手机本地模型会让用户以为选择没生效。
  /// 传 null = 清除选中（回自动选择顺序）。
  Future<void> setActiveProvider(String? id) => _apply(
      value.copyWith(activeProviderId: id),
      _kActiveProvider,
      id ?? '');

  /// **更新某 provider 当前使用的模型**（2026-10-14，模型目录选用制）。
  ///
  /// 用户在模型弹层里点进中转站（如基元律动）的目录、选了具体模型 ——
  /// provider 保持选中，`model` 换成选中的那个。
  Future<void> setProviderModel(String providerId, String model) async {
    final list = value.providers
        .map((e) => e.id == providerId ? e.copyWith(model: model) : e)
        .toList();
    await _apply(
      value.copyWith(
        providers: list,
        // 顺带把该 provider 设为当前 —— 选模型即选用该 provider
        activeProviderId: providerId,
      ),
      _kProviders,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> setBusySend(BusySendBehavior v) =>
      _apply(value.copyWith(busySend: v), _kBusySend, v.name);

  Future<void> setAccentHex(int v) =>
      _apply(value.copyWith(accentHex: v), _kAccentHex, v);

  Future<void> setGlassEffect(bool v) =>
      _apply(value.copyWith(glassEffect: v), _kGlassEffect, v);

  /// 设**单次任务最大轮次**（2026-10-18，`docs/27` P0-1 / ADR-033）。
  ///
  /// ★ 必须持久化：它是一个**显式的成本选择**（云端多花钱、单任务更久）。
  /// 重启后回到"自动"会让用户以为设置没生效 —— 与推理等级同一个理由。
  ///
  /// 非法值（不在 [kMaxTurnsOptions] 里）一律存成 `0`（自动），
  /// 与 [load] 的容错同规则 —— 否则写进去的脏值下次读回又会被悄悄改掉。
  Future<void> setMaxTurns(int v) {
    final safe = _maxTurnsOf(v);
    return _apply(value.copyWith(maxTurns: safe), _kMaxTurns, safe);
  }

  /// **全局记忆开关**（2026-10-29，INTERFACE §N12.9）。
  ///
  /// 关掉 ⇒ 宿主本轮不读 global（也不注入），**数据保留**（Kotlin 侧不受影响：
  /// 存储与注入解耦）。默认 `true` = 与旧行为一致。
  Future<void> setMemoryGlobalEnabled(bool v) =>
      _apply(value.copyWith(memoryGlobalEnabled: v), _kMemoryGlobalEnabled, v);

  /// **记忆解析池化开关**（2026-10-29，§N12.9；默认 `false`）。
  ///
  /// ⚠️ 如实：P1-①c-2 只落设置项与持久化，池化本体（按 `(scope,scopeId)`
  /// 缓存 + 每次校验）尚未接线 —— **开启当前不改变行为**，不会串台。
  Future<void> setMemoryPooling(bool v) =>
      _apply(value.copyWith(memoryPooling: v), _kMemoryPooling, v);

  /// 更新某个提供商的配置（填 Key、改模型名等）
  Future<void> updateProvider(ModelProviderConfig p) async {
    // ★ Key 走安全存储（FR-11.7）—— JSON 里只留哨兵
    await _secureKeys.write(p.id, p.apiKey);

    // ★★ 内存里**必须保留真 Key**（2026-10-14 真机 401 真凶）★★
    //
    // ## 之前的 bug
    //
    // 旧代码把写回内存的 provider 换成了带哨兵的版本：
    //     final sanitized = p.copyWith(apiKey: SecureKeyStore.sentinel);
    //     ... map((e) => e.id == p.id ? sanitized : e)
    // 于是 `sendMessage` 拿到的 `provider.apiKey == "__secure__"`
    // → 把哨兵当 Key 发给服务器 → **必然 401**。
    //
    // 而"测试连接"用的是输入框里的真 Key → 通过。
    // 这个反差（同一 Key，测试成功、聊天 401）正是本 bug 的指纹。
    //
    // ## 为什么现在不需要手动 sanitize
    //
    // `ModelProviderConfig.toJson()` 已经做了**出口脱敏**
    //（`apiKey` 一律写成哨兵）—— 落盘安全由那一个唯一出口保证，
    // 内存对象保持真值才能让 agent 正常发请求。
    //
    // 换句话说：**内存真值 / 磁盘哨兵**，边界在 toJson。
    final list = value.providers
        .map((e) => e.id == p.id ? p.copyWith(enabled: p.isConfigured) : e)
        .toList();
    await _apply(
      value.copyWith(providers: list),
      _kProviders,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  /// 设为默认提供商
  Future<void> setDefaultProvider(String id) async {
    final list = value.providers
        .map((e) => e.copyWith(isDefault: e.id == id))
        .toList();
    await _apply(
      value.copyWith(providers: list),
      _kProviders,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  /// 添加提供商
  Future<void> addProvider(ModelProviderConfig p) async {
    // ★ Key 走安全存储（FR-11.7）
    await _secureKeys.write(p.id, p.apiKey);
    // ★ 内存保留真 Key（同 updateProvider 的说明）——
    //   落盘脱敏由 toJson 唯一出口负责
    final list = [...value.providers, p];
    await _apply(
      value.copyWith(providers: list),
      _kProviders,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeProvider(String id) async {
    // ★ Key 的安全存储条目一并删除（不留孤儿密文）
    await _secureKeys.delete(id);
    final list = value.providers.where((e) => e.id != id).toList();
    await _apply(
      value.copyWith(providers: list),
      _kProviders,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> _apply(AppSettings next, String key, Object v) async {
    value = next; // 先通知 UI，保证响应即时
    if (v is String) {
      await _prefs.setString(key, v);
    } else if (v is int) {
      await _prefs.setInt(key, v);
    } else if (v is double) {
      await _prefs.setDouble(key, v);
    } else if (v is bool) {
      await _prefs.setBool(key, v);
    }
  }
}
