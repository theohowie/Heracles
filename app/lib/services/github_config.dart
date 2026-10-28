/// **GitHub OAuth 配置**（2026-10-27，Step 3）。
///
/// ## 为什么 Client ID 可以写死在源码里
///
/// OAuth 有两个凭据：
///
/// | 名字 | 长相 | 是不是秘密 |
/// |---|---|---|
/// | `client_id` | `Ov23linhwuqRGaF0QYT6` | ❌ **公开** —— 它就是"应用的名字" |
/// | `client_secret` | 40 位十六进制 | ✅ 是秘密，**但 Device Flow 不需要它** |
///
/// GitHub 官方文档在 device flow 的错误码一节写得很直白：
/// **"`client_secret` is not needed for the device flow"**。
///
/// ⇒ 本文件只有公开的 Client ID，**没有、也不需要**任何秘密。
/// 这也是我们选 Device Flow 而不是 web application flow 的核心理由
/// （后者换 token 必须带 secret，而客户端藏不住 —— APK 是 zip，
/// `strings libapp.so` 就能翻出来）。
///
/// ## 这个 App 在 GitHub 上是怎么注册的
///
/// ```
/// Application name:  Heracles
/// Homepage URL:      https://theohowie.github.io/Heracles/
/// Redirect URI:      https://theohowie.github.io/Heracles/   ← Device Flow 用不到
///                    （但 GitHub 的表单**要求非空**，这是它的怪癖）
/// ✅ Enable Device Flow      ← 必须勾，否则 /login/device/code 返回 404
/// ☐ Expire user access tokens
/// ```
///
/// ## ⚠️ 如果将来改成 expiring token
///
/// 勾上 "Expire user access tokens" 之后，token **8 小时过期**、响应里多一个
/// `refresh_token`。那时必须在这里加 refresh 逻辑（用 `offline_access` scope
/// 或应用级开关），否则 8 小时后推送会 401 —— 而 UI 只会显示"推送被拒绝"，
/// **是误导人的**。
///
/// `GitHubDeviceFlow` 目前**刻意不处理 refresh**：不勾那个开关就没有这个问题。
/// 这条写在这里，避免将来有人勾了却不知道要改代码。
library;

/// GitHub OAuth 应用配置。
abstract final class GitHubConfig {
  /// OAuth App 的 Client ID（**公开值**，见文件头）。
  static const clientId = 'Ov23linhwuqRGaF0QYT6';

  /// 申请的最小权限集。
  ///
  /// ## 为什么是这两个
  ///
  /// | scope | 能做什么 | 为什么需要 |
  /// |---|---|---|
  /// | `read:user` | 读用户名/头像 | 「已连接」状态要显示头像和昵称 |
  /// | `repo` | 读写**所有**仓库（含私有） | 要 clone/pull/push 私有仓库 |
  ///
  /// ## 为什么不更小
  ///
  /// `public_repo` 只能碰公开仓库 —— 但用户最想推的往往是自己刚建的私有项目。
  /// 一次授权只给 `public_repo`，用户推私有仓库时会失败，还得重新授权一次，
  /// 体验更差。
  ///
  /// ## 为什么不更大
  ///
  /// 绝不要 `admin:repo_hook` / `delete_repo` / `workflow` 之类 —— 我们用不到。
  ///
  /// ## 诚实的取舍
  ///
  /// `repo` 是**全账号所有仓库**的读写权。这是 OAuth App 的粒度限制：
  /// 想要"只授权某个仓库"，必须改造成 GitHub App（授权时选择仓库，
  /// token 1 小时过期）。那需要处理 installation 流程，复杂度高一档。
  /// 当前选 OAuth App 是"先跑通"，将来可以升级。
  static const scopes = 'repo read:user';

  /// GitHub 的验证页（用户在这里输 8 位码）。
  static const verificationUri = 'https://github.com/login/device';

  /// 用户撤销授权的页面 —— 「断开连接」时要提示用户去这里彻底撤销。
  ///
  /// ## 为什么必须告诉用户这件事
  ///
  /// 我们在本地删 token，只代表"这台设备不再用它"；
  /// **GitHub 那边的授权记录还在**，那意味着理论上还能签发新 token。
  /// 不告诉用户就是掩盖事实。
  static const revokeUri = 'https://github.com/settings/applications';
}
