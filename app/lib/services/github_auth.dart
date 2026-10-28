/// **GitHub 认证的宿主实现**（2026-10-27，Step 3）。
///
/// ## 这个文件只做两件事
///
/// 1. **把真实的 HTTP 喂给 [GitHubDeviceFlow]**（协议逻辑在 backend，已单测）；
/// 2. **把 token 存进 `flutter_secure_storage`**（绝不进明文、不进日志、
///    不进模型上下文）。
///
/// ## 为什么拆成这样
///
/// 协议逻辑（拼请求 / 解析 / 轮询状态机 / slow_down 加间隔）放在 backend：
/// 那里能 `dart test`，而这些分支在真机上**极难复现**
/// （slow_down 要故意打快、expired 要等 15 分钟）。
///
/// 本文件只保留"必须依赖 Flutter/平台"的部分：HTTP 与安全存储。
///
/// ## 安全边界（硬约束，改代码前先读）
///
/// · token **只**出现在：请求头 `Authorization: Bearer <token>`、
///   `flutter_secure_storage` 的键值。
/// · token **绝不**出现在：日志（`debugPrint`/`print`）、异常消息、
///   工具返回值、模型上下文、会话 `.jsonl`。
/// · 本文件的 [_mask] 是唯一允许"提到 token"的场合（打码后用于排障）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:heracles_backend/heracles_backend.dart';

/// GitHub 认证状态的持久化键。
abstract final class GitHubAuthKeys {
  /// access token（`gho_...`）。
  static const token = 'heracles.github.token';

  /// 授权范围（空格分隔），用于 UI 显示"你给了什么权限"。
  static const scopes = 'heracles.github.scopes';

  /// 登录用户名（用于头像/昵称显示；空 = 还没拉过）。
  static const login = 'heracles.github.login';
}

/// **GitHub 认证门面**（宿主侧）。
///
/// 用法：
/// ```dart
/// final auth = GitHubAuth(clientId: 'Ov23li...');
/// final start = await auth.start();          // 拿 8 位码给用户
/// if (start is DeviceCodeInfo) {
///   showCode(start.userCode, start.verificationUri);   // 自动开浏览器+复制
///   final r = await auth.finish(start);                // 轮询
/// }
/// ```
class GitHubAuth {
  GitHubAuth({
    required this.clientId,
    Dio? dio,
    FlutterSecureStorage? storage,
    this.openBrowser,
  })  : _dio = dio ?? Dio(),
        _storage = storage ?? const FlutterSecureStorage();

  /// OAuth App 的 Client ID（`Ov23li...`）。
  ///
  /// **可以公开** —— 它是应用的名字，不是秘密。Device Flow 不需要
  /// `client_secret`，所以这个值写死在代码里是安全的（这是选 Device Flow
  /// 的核心理由：另一条路必须把 secret 打进 APK = 公开泄露）。
  final String clientId;

  final Dio _dio;
  final FlutterSecureStorage _storage;

  /// 打开浏览器的回调（宿主注入：`launchUrl` 或 Custom Tabs）。
  ///
  /// 传 null = 不自动打开，由 UI 显示"请手动访问 xxx"。
  final Future<bool> Function(String url)? openBrowser;

  /// 单次 HTTP 超时。GitHub 的 device 端点在毫秒级返回，15 秒足够。
  static const _timeout = Duration(seconds: 15);

  // ==========================================================================
  // 协议 → 真实 HTTP
  // ==========================================================================

  GitHubDeviceFlow _flow() => GitHubDeviceFlow(
        clientId: clientId,
        post: _post,
      );

  /// 真实 POST：form-urlencoded + `Accept: application/json`。
  ///
  /// ⚠️ 两个细节都不能省：
  /// · **`Accept: application/json`** —— 不带的话 GitHub 回
  ///   `application/x-www-form-urlencoded`（虽然 `decodeGitHubResponse`
  ///   能兜底，但别依赖兜底）；
  /// · **不打印响应体** —— `access_token` 就在里面。
  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, String> body,
  ) async {
    final res = await _dio.post<String>(
      url,
      data: encodeFormBody(body),
      options: Options(
        contentType: 'application/x-www-form-urlencoded',
        headers: const {'Accept': 'application/json'},
        responseType: ResponseType.plain,
        // 自己判状态码：GitHub 出错时也常回 200，靠 error 字段区分
        validateStatus: (_) => true,
      ),
    ).timeout(_timeout);
    final raw = res.data ?? '';
    return decodeGitHubResponse(raw);
  }

  // ==========================================================================
  // 对外 API
  // ==========================================================================

  /// **第 1 步**：请求设备码。返回 [DeviceCodeInfo] 或 [GitHubAuthFailure]。
  ///
  /// 拿到后 UI 应该：
  /// 1. 显示 [DeviceCodeInfo.userCode]（大字号、可点复制）；
  /// 2. 自动打开 [DeviceCodeInfo.verificationUri]（有 `openBrowser` 时）；
  /// 3. 调 [finish] 开始轮询。
  Future<Object> start({String scopes = 'repo read:user'}) =>
      _flow().requestCode(scopes: scopes);

  /// **第 3 步**：轮询直到用户授权。
  ///
  /// 成功时**自动把 token 存进 secure storage**，调用方拿到的
  /// [GitHubAuthSuccess] 里也有 token —— 但**不要**把它显示给用户或
  /// 放进任何日志。
  Future<GitHubAuthResult> finish(DeviceCodeInfo info) async {
    final r = await _flow().poll(info);
    if (r is GitHubAuthSuccess) {
      await saveToken(r.accessToken, scopes: r.scopes);
    }
    return r;
  }

  /// 用 UI 已打开浏览器的方式启动（省一步手动跳转）。
  ///
  /// 返回 `true` = 浏览器已拉起。
  Future<bool> openVerificationPage(DeviceCodeInfo info) async {
    final open = openBrowser;
    if (open == null) return false;
    return open(info.verificationUri);
  }

  // ==========================================================================
  // token 存储
  // ==========================================================================

  /// 保存 token。**这是唯一的写入点。**
  Future<void> saveToken(String token, {String scopes = ''}) async {
    await _storage.write(key: GitHubAuthKeys.token, value: token);
    if (scopes.isNotEmpty) {
      await _storage.write(key: GitHubAuthKeys.scopes, value: scopes);
    }
  }

  /// 读 token（`null` = 没登录）。
  Future<String?> readToken() => _storage.read(key: GitHubAuthKeys.token);

  /// 是否已登录。
  Future<bool> isConnected() async {
    final t = await readToken();
    return t != null && t.isNotEmpty;
  }

  /// 读授权范围（给 UI 显示"你给了什么权限"）。
  Future<String> readScopes() async =>
      (await _storage.read(key: GitHubAuthKeys.scopes)) ?? '';

  /// 已登录的用户名（缓存；空 = 还没拉过）。
  Future<String> readLogin() async =>
      (await _storage.read(key: GitHubAuthKeys.login)) ?? '';

  /// 退出登录：清掉本地的所有 GitHub 凭据。
  ///
  /// ⚠️ 只清本地 —— GitHub 那边的授权记录还在，用户想彻底撤销要去
  /// `github.com/settings/applications`。UI 的"断开连接"文案应该说清这点。
  Future<void> signOut() async {
    await _storage.delete(key: GitHubAuthKeys.token);
    await _storage.delete(key: GitHubAuthKeys.scopes);
    await _storage.delete(key: GitHubAuthKeys.login);
  }

  // ==========================================================================
  // 拉用户信息（拿头像/昵称）
  // ==========================================================================

  /// 用 token 拉 `GET /user`，返回 `login` + `avatar_url` 等。
  ///
  /// 失败返回 `null`（连通性展示是锦上添花，不该阻断主流程）。
  Future<GitHubUser?> fetchUser() async {
    final token = await readToken();
    if (token == null || token.isEmpty) return null;
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/user',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
          },
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200 || res.data == null) return null;
      final login = (res.data!['login'] as String?) ?? '';
      if (login.isEmpty) return null;
      // 顺手缓存用户名，下次开 App 不用再请求
      await _storage.write(key: GitHubAuthKeys.login, value: login);
      return GitHubUser(
        login: login,
        name: (res.data!['name'] as String?) ?? '',
        avatarUrl: (res.data!['avatar_url'] as String?) ?? '',
      );
    } catch (_) {
      return null; // 网络/限流：静默降级，UI 显示"已连接"但没头像
    }
  }

  // ==========================================================================
  // 拉仓库列表（已连接后点 GitHub = 选仓库，2026-10-28）
  // ==========================================================================

  /// 拉**自己的**仓库列表（按最近更新排序）。
  ///
  /// ## 为什么用 `/user/repos` 而不是 `/search/repositories`
  ///
  /// `/search` 的限流是 30 次/分钟（认证），且用户每敲一个字就要打一次网络。
  /// 用户的仓库通常是几十到几百个 ⇒ **一次拉全 + 本地过滤**更快、更省配额
  /// （`/user/repos` 是 5000 次/小时）。
  ///
  /// ## 参数说明
  ///
  /// · `affiliation=owner` —— **只要自己拥有的**。不加会把"别人邀请你协作"
  ///   的仓库也列出来，而你的 token 对它们不一定有写权限（推送会失败）。
  /// · `sort=updated` —— 最近动过的排前面（比按名字排更贴近"我现在想做哪个"）。
  /// · `per_page=100` —— GitHub 单页上限。
  ///
  /// @return 空列表 = 没仓库或请求失败；`null` = **没连接**（两种语义必须分清）
  Future<List<GitHubRepo>?> listRepos({int page = 1}) async {
    final token = await readToken();
    if (token == null || token.isEmpty) return null;
    try {
      final res = await _dio.get<List<dynamic>>(
        'https://api.github.com/user/repos',
        queryParameters: {
          'affiliation': 'owner',
          'sort': 'updated',
          'per_page': 100,
          'page': page,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
          },
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200 || res.data == null) return const [];
      final out = <GitHubRepo>[];
      for (final raw in res.data!) {
        if (raw is! Map) continue;
        final name = (raw['name'] as String?) ?? '';
        final full = (raw['full_name'] as String?) ?? '';
        final clone = (raw['clone_url'] as String?) ?? '';
        if (name.isEmpty || full.isEmpty || clone.isEmpty) continue;
        out.add(GitHubRepo(
          name: name,
          fullName: full,
          cloneUrl: clone,
          defaultBranch: (raw['default_branch'] as String?) ?? 'main',
          isPrivate: raw['private'] == true,
          description: (raw['description'] as String?) ?? '',
          updatedAt: (raw['updated_at'] as String?) ?? '',
          sizeKb: (raw['size'] as num?)?.toInt() ?? 0,
        ));
      }
      return out;
    } catch (_) {
      // 网络/限流 ⇒ 空列表（UI 显示"没拉到，重试"）。
      // ⚠️ 不能返回 null —— null 的语义是"没连接"，那是完全另一件事。
      return const [];
    }
  }
}

/// 一个 GitHub 仓库（选择列表用）。
class GitHubRepo {
  const GitHubRepo({
    required this.name,
    required this.fullName,
    required this.cloneUrl,
    required this.defaultBranch,
    this.isPrivate = false,
    this.description = '',
    this.updatedAt = '',
    this.sizeKb = 0,
  });

  final String name;

  /// `owner/name`。
  final String fullName;

  /// `https://github.com/owner/name.git` —— **必须 HTTPS**，
  /// 因为设备上没有 ssh（`git_dart` 的 SSH 走外部命令）。
  final String cloneUrl;

  final String defaultBranch;
  final bool isPrivate;
  final String description;

  /// ISO 时间串（原样保留，展示层再格式化）。
  final String updatedAt;

  /// 仓库大小（KB，GitHub 口径）。
  ///
  /// 用途：**克隆前让用户知道体积**。手机上几百 MB 的仓库会占满存储，
  /// 点之前该有心理准备。
  final int sizeKb;

  String get sizeLabel {
    if (sizeKb >= 1024 * 1024) {
      return '${(sizeKb / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (sizeKb >= 1024) return '${(sizeKb / 1024).toStringAsFixed(1)} MB';
    return '$sizeKb KB';
  }

  /// 搜索匹配：名字 / 全名 / 描述，不区分大小写。
  bool matches(String q) {
    if (q.isEmpty) return true;
    final k = q.toLowerCase();
    return name.toLowerCase().contains(k) ||
        fullName.toLowerCase().contains(k) ||
        description.toLowerCase().contains(k);
  }
}

/// GitHub 用户信息（用于"已连接"状态的展示）。
class GitHubUser {
  const GitHubUser({
    required this.login,
    this.name = '',
    this.avatarUrl = '',
  });

  final String login;
  final String name;
  final String avatarUrl;

  /// 展示名：优先真名，退回用户名。
  String get display => name.isNotEmpty ? name : login;
}

/// **打码** —— 唯一允许"提到 token"的地方（用于排障日志）。
///
/// 规则：只留前 4 位 + 长度，其余全部替换。
/// 例如 `gho_16C7e42F...` → `gho_…(40字符)`。
///
/// ⚠️ 即使打码，也**不要**把它放进面向用户的界面或模型上下文。
String maskToken(String token) {
  if (token.isEmpty) return '（空）';
  final head = token.length <= 4 ? token : token.substring(0, 4);
  return '$head…(${token.length}字符)';
}
