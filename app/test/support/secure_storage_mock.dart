import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// **`flutter_secure_storage` 的测试替身**（2026-10-18，F1c）。
///
/// ## 为什么需要它 —— 症状是"永久挂起"，不是报错
///
/// `SettingsController.load()` 会 `await _secureKeys.read(...)`
/// （见 `app/lib/services/settings_controller.dart` 里 `Future.wait([...])` 那处）。
/// 真机上那是 Android Keystore 的 MethodChannel；**测试里没有平台侧**。
///
/// ⚠️ 关键机制（这一步最容易判断错）：
/// **未装 handler 时，`MethodChannel.invokeMethod` 的 Future 永不完成** ——
/// 它**不是**抛 `MissingPluginException`。如果它抛异常，
/// `load()` 的 `catch (_)` 会接住并正常返回，测试也就不会挂。
/// 正因为 Future 永不完成，**任何**走 `load()` 的用例都会
/// **永久卡死**（`flutter test` 既不报错也不结束）——
/// 加 try/catch **永远救不了**这类测试。
///
/// 实测（本机，`docs/实测-03` 坑 36）：
/// · 装 mock 前：`reasoning_switch_test.dart` 整份文件在**第 4 个用例**卡死；
///   单跑 `--plain-name "改了推理等级会落盘"` 也卡死。
/// · 装 mock 后：**整份文件 39/39 通过（约 7 秒）**。
/// · `widget_test.dart`：装 mock 前卡在**第 1 个**用例；
///   装后 **15/15 全绿**（约 2 秒）—— **含**"打开 ChatScreen"那几条。
///
/// ## ⚠️ 与坑 35 的关系（这里有个**实测澄清**，别照抄老结论）
///
/// 本机过去把"打开 `ChatScreen` 的 widget 测试卡死"记为**坑 35**，并认为
/// 与 storage 无关。**但实测推翻了这个归因**：
/// `widget_test.dart` 里那条 `首屏在无工作区时引导用户选择文件夹`，
/// 装上本 mock 后**通过**；把 `setUp(installSecureStorageMock)` 注释掉再单跑，
/// **立刻卡死**。原因是 `ChatScreen` 自己也会 `await SettingsController.load()`
/// ⇒ **同一条 storage 通道**。
///
/// 所以：坑 35 与本模块**至少在本文件里是同一个根因**。
/// ⚠️ 但这**不能**推广成"所有 ChatScreen 卡首帧都归因于 storage" ——
/// 是否还存在**其它**触发路径（例如 `chat_screen_app_workspace_test.dart`
/// 那类更重的 ChatScreen 驱动）**尚未验证**。
///
/// ## 通道名与 method 形状：查依赖源码得来，不是猜的
///
/// `app/pubspec.lock` → `flutter_secure_storage: 11.2.0`；源码
/// `flutter_secure_storage_platform_interface-2.1.1/lib/src/method_channel_flutter_secure_storage.dart`：
///
/// | method | arguments | 返回 |
/// |---|---|---|
/// | `read` | `{key, options}` | `String?` |
/// | `write` | `{key, value, options}` | `void` |
/// | `delete` | `{key, options}` | `void` |
/// | `containsKey` | `{key, options}` | `bool` |
/// | `readAll` | `{options}` | `Map` |
///
/// channel 名 `plugins.it_nomads.com/flutter_secure_storage` 与 Android 插件
/// 注册的**完全一致**（`flutter_secure_storage-11.2.0/android/src/main/java/
/// com/it_nomads/fluttersecurestorage/FlutterSecureStoragePlugin.java`），
/// 所以这里 mock 的是**真实通道**，不是自造替身。
///
/// ## 用法
///
/// ```dart
/// import 'support/secure_storage_mock.dart';
///
/// void main() {
///   setUp(installSecureStorageMock);
///   tearDown(removeSecureStorageMock);
///
///   test('...', () async {
///     setSecureStorageMode(SecureStorageMockMode.withValues);
///     setSecureStorageValue('api_key/p1', 'sk-real-key');
///     final c = await SettingsController.load();  // 不再卡死
///   });
/// }
/// ```
///
/// ⚠️ 必须在 `TestWidgetsFlutterBinding.ensureInitialized()` **之后**调用
/// （它内部要访问 `TestDefaultBinaryMessengerBinding.instance`）。

/// `flutter_secure_storage` 的真实 MethodChannel 名。
const MethodChannel secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// 安全存储 mock 的三种状态 —— 对应真实世界会遇到的三类情况。
///
/// ⚠️ **默认（[empty]）下 `write` 依然生效**：`read` 始终反映内存表。
/// 只有 [empty] 会在安装时把表清空（= 首次安装）。
/// 这样"改完落盘 → 重载后仍在"的断言才是真的往返，不会假绿。
enum SecureStorageMockMode {
  /// **首次安装**：安装时清空内存表（之后写入的值照样读得到）
  empty,

  /// **保留已预置的值**：安装时**不**清表
  /// （配合 [setSecureStorageValue] 模拟"用户早就配好了"）
  withValues,

  /// **Keystore 不可用**：`read` 抛 `PlatformException`
  throwsOnRead,
}

/// 安全存储的**内存表**（读写共用）。
///
/// ## 为什么读写必须共用一张表（而且 `read` 必须始终查表）
///
/// 若 `write` 被丢弃、`read` 恒返回 null，那么 `setXxx(v)` 之后
/// 再 `load()` 读回的仍是默认值 —— "落盘"这件事**根本没被验证**，
/// 测试会**假绿**，而且假得很难看出来。
///
/// 本仓库真实踩到过一次：最初默认模式下 `read` 只查表却**不写入**表，
/// 于是 `widget_test.dart` 的「提供商配置会被保存并可读回」红了
/// （`apiKey` 读回空串）—— 红得**是对的**：
/// `updateProvider()` 确实把 Key 写进了安全存储，而替身把它吞了。
/// 修法是让 `read` **永远**反映表（见 [SecureStorageMockMode] 的说明），
/// 而不是去改那条测试。
Map<String, String> secureStore = <String, String>{};

SecureStorageMockMode _mode = SecureStorageMockMode.empty;

/// 当前 mock 状态（默认 [SecureStorageMockMode.empty]，与"首次安装"一致）。
SecureStorageMockMode get secureStorageMode => _mode;

/// 切换 mock 状态。进程内**直接赋值**即可（无需 await）。
void setSecureStorageMode(SecureStorageMockMode mode) => _mode = mode;

/// 往内存表里预置一个值（模拟"用户早就配好了"）。
void setSecureStorageValue(String key, String value) =>
    secureStore[key] = value;

/// 装上 mock handler，并把状态重置为"首次安装 + 空表"。
///
/// ★ 建议 `setUp(installSecureStorageMock)` 每个用例前都装一次 ——
/// 否则状态会从上一个用例泄漏过来。
void installSecureStorageMock() {
  // 默认 = 首次安装：清空表（模拟 App 第一次跑）
  if (_mode != SecureStorageMockMode.withValues) {
    secureStore = <String, String>{};
  }
  _mode = SecureStorageMockMode.empty;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async {
    final args = (call.arguments as Map?) ?? const {};
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        if (_mode == SecureStorageMockMode.throwsOnRead) {
          // Keystore 不可用（系统级异常）——
          // `load()` 的 catch 必须接住它，并清掉哨兵
          throw PlatformException(
            code: 'KeystoreUnavailable',
            message: 'mock: 安全存储不可用',
          );
        }
        // ★ 始终查表（不按 mode 短路）—— 见 [secureStore] 的说明：
        //   若这里恒返回 null，`write` 就等于被吞掉，"落盘"没有被验证。
        return key == null ? null : secureStore[key];
      case 'write':
        if (key != null) secureStore[key] = (args['value'] as String?) ?? '';
        return null;
      case 'delete':
        if (key != null) secureStore.remove(key);
        return null;
      case 'containsKey':
        return secureStore.containsKey(key);
      case 'readAll':
        return Map<String, String>.from(secureStore);
      default:
        return null;
    }
  });
}

/// 卸掉 mock handler（`tearDown` 里调用，避免污染别的用例）。
void removeSecureStorageMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, null);
}
