/// **GitHub OAuth Device Flow**（2026-10-27，Step 3）—— 纯 Dart 的协议实现。
///
/// ## 为什么用 Device Flow，而不是"一次性授权跳转"
///
/// 用户要的体验是「点一下 → 授权 → 连上」，不碰 token。两条路都能做到，
/// 但**只有 Device Flow 不需要 `client_secret`**（官方文档原文：
/// "`client_secret` is not needed for the device flow"）。
///
/// 另一条路（web application flow）换 token 那一步要求 `client_secret`，
/// 而本 App 是**开源 + 纯客户端**、没有服务器 ⇒ 只能把它打进 APK ⇒
/// 等于公开泄露（APK 是 zip，`strings libapp.so` 就能翻出来）。
///
/// ⇒ 选 Device Flow。代价是用户要输一次 8 位码（`WDJB-MJHT` 那种），
/// 但可以自动打开浏览器 + 自动复制，实际体验是"点一下 → 粘贴 → 授权"。
///
/// ## 协议（官方文档原文对齐，`docs.github.com/.../authorizing-oauth-apps`）
///
/// ```
/// 1) POST https://github.com/login/device/code
///      client_id=<CLIENT_ID>  scope=<scopes>
///      Accept: application/json
///    → { device_code, user_code: "WDJB-MJHT",
///        verification_uri: "https://github.com/login/device",
///        expires_in: 900, interval: 5 }
///
/// 2) 用户打开 verification_uri 输入 user_code，点 Authorize
///
/// 3) 每 interval 秒 POST https://github.com/login/oauth/access_token
///      client_id=<CLIENT_ID>  device_code=<device_code>
///      grant_type=urn:ietf:params:oauth:grant-type:device_code
///    → 未授权：{ error: "authorization_pending" }
///      太快了：{ error: "slow_down" }   ← interval 要 +5 秒
///      授权了：{ access_token: "gho_...", token_type: "bearer", scope: "..." }
///      被拒了：{ error: "access_denied" }
///      过期了：{ error: "expired_token" }
/// ```
///
/// ## ⚠️ 两个必须知道的上限
///
/// · `expires_in` 默认 **900 秒**（15 分钟）—— 超时就得重新发起；
/// · **全应用共享**每小时 50 次 user_code 提交 —— 不是每用户。个人项目够用，
///   用户量大了会撞墙。
///
/// ## 为什么本文件在 backend 而不是 app
///
/// 这里全是**协议逻辑**（拼请求、解析响应、轮询状态机），不含 UI、不碰存储。
/// 放 backend 就能用 `dart test` 毫秒级验证"slow_down 会不会真的加间隔"、
/// "expired_token 会不会正确终止"—— 这些在真机上很难复现。
///
/// HTTP 用**注入的函数**而不是 dio：测试时塞一个假的，
/// 生产时由 app 侧传真实实现（见 `app/lib/services/github_auth.dart`）。
library;

import 'dart:async';
import 'dart:convert';

/// Device Flow 的一次性凭据（拿到后要显示给用户）。
class DeviceCodeInfo {
  const DeviceCodeInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  /// 40 字符，**只在本进程内用来轮询**，不要给用户看。
  final String deviceCode;

  /// 8 位带连字符（如 `WDJB-MJHT`）—— **这个才是给用户输入的**。
  final String userCode;

  /// `https://github.com/login/device`
  final String verificationUri;

  /// device_code / user_code 的有效期（秒），GitHub 默认 900。
  final int expiresIn;

  /// 两次轮询之间的最小间隔（秒），GitHub 默认 5。
  final int interval;

  /// 有效期截止时间（本地时钟）。用于"还没到点就别再轮询了"。
  DateTime get expiresAt => DateTime.now().add(Duration(seconds: expiresIn));
}

/// 认证结果。
sealed class GitHubAuthResult {
  const GitHubAuthResult();
}

/// 成功拿到 token。
final class GitHubAuthSuccess extends GitHubAuthResult {
  const GitHubAuthSuccess({
    required this.accessToken,
    required this.scopes,
    this.tokenType = 'bearer',
  });

  /// `gho_xxx` 形式。**这是凭据** —— 绝不进日志、绝不进模型上下文。
  final String accessToken;

  /// 空格分隔的授权范围（如 `repo read:user`）。
  final String scopes;

  final String tokenType;
}

/// 失败（含用户拒绝、过期、网络错）。
final class GitHubAuthFailure extends GitHubAuthResult {
  const GitHubAuthFailure(this.reason, {this.isRetryable = true});

  /// 给用户看的人话（不是 GitHub 的 error code）。
  final String reason;

  /// 能否重来（`access_denied` 也算可重来 —— 用户可能点错了）。
  final bool isRetryable;
}

/// **Device Flow 客户端**。
///
/// ## 用法
///
/// ```dart
/// final flow = GitHubDeviceFlow(
///   clientId: 'Ov23li...',
///   post: (url, body) async => /* 真实 HTTP，返回解码后的 JSON Map */,
/// );
/// final start = await flow.requestCode(scopes: 'repo read:user');
/// if (start is GitHubAuthFailure) return;           // 网络错等
/// final info = (start as DeviceCodeInfo);
/// showUserTheCode(info.userCode, info.verificationUri);
/// final result = await flow.poll(info);              // 等用户授权
/// ```
class GitHubDeviceFlow {
  GitHubDeviceFlow({
    required this.clientId,
    required this.post,
    this.sleep,
    this.clock,
  });

  /// OAuth App 的 Client ID（`Ov23li...`）。**可以公开** —— 它是应用的名字，
  /// 不是秘密（秘密是 client_secret，Device Flow 不需要它）。
  final String clientId;

  /// 发一个 POST 请求并返回**解码后的 JSON**。
  ///
  /// 签名刻意做成"URL + form body → Map"：这样测试可以塞纯函数，
  /// 生产时可以塞 dio/http 的任意实现，本类不依赖具体 HTTP 库。
  ///
  /// ⚠️ 实现必须：
  /// · 带 `Accept: application/json`（否则 GitHub 回 form-urlencoded）；
  /// · **不要把 access_token 打进日志**。
  final Future<Map<String, dynamic>> Function(
    String url,
    Map<String, String> body,
  ) post;

  /// 等待函数（测试可注入以跳过真实等待）。
  final Future<void> Function(Duration)? sleep;

  /// 时钟（测试可注入固定时间，验证过期判定）。
  final DateTime Function()? clock;

  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';
  static const _grantType = 'urn:ietf:params:oauth:grant-type:device_code';

  Future<void> _wait(Duration d) =>
      sleep != null ? sleep!(d) : Future<void>.delayed(d);

  DateTime _now() => clock != null ? clock!() : DateTime.now();

  /// **第 1 步**：请求 device_code + user_code。
  ///
  /// 返回 [DeviceCodeInfo]（成功）或 [GitHubAuthFailure]（失败）。
  Future<Object> requestCode({String scopes = 'repo read:user'}) async {
    try {
      final json = await post(_deviceCodeUrl, {
        'client_id': clientId,
        'scope': scopes,
      });
      // GitHub 出错时也回 200 + { error, error_description }
      final err = json['error'];
      if (err != null) {
        return GitHubAuthFailure(
          'GitHub 拒绝了设备码请求：${json['error_description'] ?? err}',
          isRetryable: false,
        );
      }
      final deviceCode = json['device_code'] as String?;
      final userCode = json['user_code'] as String?;
      final uri = json['verification_uri'] as String?;
      if (deviceCode == null || userCode == null || uri == null) {
        return const GitHubAuthFailure(
          'GitHub 返回的设备码信息不完整（缺少 device_code / user_code / verification_uri）',
        );
      }
      return DeviceCodeInfo(
        deviceCode: deviceCode,
        userCode: userCode,
        verificationUri: uri,
        expiresIn: (json['expires_in'] as num?)?.toInt() ?? 900,
        interval: (json['interval'] as num?)?.toInt() ?? 5,
      );
    } catch (e) {
      return GitHubAuthFailure('请求设备码失败：${_humanize(e)}');
    }
  }

  /// **第 3 步**：轮询直到用户授权 / 拒绝 / 超时。
  ///
  /// ## 状态机（照文档实现，别自己发明）
  ///
  /// | GitHub 回 | 含义 | 本类怎么做 |
  /// |---|---|---|
  /// | `authorization_pending` | 用户还没点 | 继续等（按 interval）|
  /// | `slow_down` | 轮询太快 | **interval +5 秒**后继续 |
  /// | `access_denied` | 用户点了拒绝 | 终止，返回可重试失败 |
  /// | `expired_token` | 15 分钟到了 | 终止，返回可重试失败 |
  /// | 其它 error | 未知 | 终止，`isRetryable: false`（别瞎重试）|
  /// | 有 `access_token` | 成功 | 终止，返回 token |
  ///
  /// ## 为什么 `slow_down` 要 +5 秒而不是"重试一次"
  ///
  /// 文档明写："The `slow_down` error response **adds 5 seconds** to the
  /// last interval"。不照做会进入恶性循环：越被限流越急着重试，
  /// 最终把**全应用共享的 50 次/小时**配额烧光 —— 那样所有用户都连不上。
  Future<GitHubAuthResult> poll(DeviceCodeInfo info) async {
    var interval = info.interval;
    final deadline = _now().add(Duration(seconds: info.expiresIn));

    while (true) {
      // 超过总时长就停（不要在客户端无脑轮询）
      if (!_now().isBefore(deadline)) {
        return const GitHubAuthFailure(
          '授权已超时（15 分钟）。请重新点击「连接 Github」获取新的验证码。',
        );
      }
      await _wait(Duration(seconds: interval));

      Map<String, dynamic> json;
      try {
        json = await post(_tokenUrl, {
          'client_id': clientId,
          'device_code': info.deviceCode,
          'grant_type': _grantType,
        });
      } catch (e) {
        // 网络抖动：不算失败，继续轮（但要受 deadline 约束）
        continue;
      }

      final token = json['access_token'] as String?;
      if (token != null && token.isNotEmpty) {
        return GitHubAuthSuccess(
          accessToken: token,
          scopes: (json['scope'] as String?) ?? '',
          tokenType: (json['token_type'] as String?) ?? 'bearer',
        );
      }

      final err = (json['error'] as String?) ?? '';
      switch (err) {
        case 'authorization_pending':
          continue; // 用户还没操作，正常情况
        case 'slow_down':
          // 文档：+5 秒。不照做会烧光全应用配额。
          interval += 5;
          continue;
        case 'access_denied':
          return const GitHubAuthFailure(
            '你在浏览器里拒绝了授权。需要的话可以重新连接。',
          );
        case 'expired_token':
          return const GitHubAuthFailure(
            '验证码已过期（15 分钟）。请重新点击「连接 Github」。',
          );
        default:
          return GitHubAuthFailure(
            'GitHub 返回了未预期的结果：${err.isEmpty ? '（空 error 且没有 access_token）' : err}'
            '${json['error_description'] == null ? '' : ' —— ${json['error_description']}'}',
            isRetryable: false,
          );
      }
    }
  }

  /// 把异常变成一句人话（不暴露栈、**不暴露 token**）。
  String _humanize(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}

/// 把 form body 编码成 `application/x-www-form-urlencoded`。
///
/// 单独导出：宿主实现 `post` 时要拼 body，别各自手写一遍
/// （手写最容易漏 `Uri.encodeQueryComponent`，中文/特殊字符就崩）。
String encodeFormBody(Map<String, String> body) => body.entries
    .map((e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
    .join('&');

/// 从 GitHub 的响应体里解出 JSON。
///
/// ## 为什么需要这个
///
/// GitHub 的 token 端点**默认回 `application/x-www-form-urlencoded`**，
/// 只有请求头带 `Accept: application/json` 才回 JSON。如果宿主的 HTTP
/// 客户端忘了那个 header，这里兜一层：把 form 体也解析成 Map，
/// 让上层逻辑不用关心两种格式。
///
/// 这不是"宽容"，是**照 API 的两种合法形态都处理** —— 但注释要说清楚：
/// 正确做法仍然是带 `Accept: application/json`。
Map<String, dynamic> decodeGitHubResponse(String body) {
  final trimmed = body.trim();
  if (trimmed.startsWith('{')) {
    final v = jsonDecode(trimmed);
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  }
  // form-urlencoded 兜底
  final out = <String, dynamic>{};
  for (final pair in trimmed.split('&')) {
    if (pair.isEmpty) continue;
    final i = pair.indexOf('=');
    if (i < 0) continue;
    out[Uri.decodeQueryComponent(pair.substring(0, i))] =
        Uri.decodeQueryComponent(pair.substring(i + 1));
  }
  return out;
}
