/// **API 路径拼接**（2026-11-10，修 404：`…/v1/v1/messages`）。
///
/// ## 为什么需要这个文件
///
/// 各 provider 的 baseUrl 由**用户填**，而用户填的地址是否已带版本前缀并不统一：
///
/// - App 的设置默认值就**自带 `/v1`**：`https://api.deepseek.com/v1`、
///   `https://dashscope.aliyuncs.com/compatible-mode/v1`；
/// - Anthropic / OpenAI Responses 的官方地址**不带**：`https://api.anthropic.com`、
///   `https://api.openai.com`；
/// - Anthropic 兼容中转站两种都有人填：`https://relay.example.com/anthropic`、
///   `https://relay.example.com/v1`。
///
/// 以前两条轨各写各的：Anthropic 轨**无条件**拼 `/v1/messages`（用户填了带 `/v1`
/// 的地址 ⇒ `…/v1/v1/messages` ⇒ **404**，用户实测原话「a畜的协议应该是可以去掉
/// v1 就好了」）；Responses 轨**完全不补** `/v1`（官方地址 ⇒ `/responses` ⇒ 也 404）。
///
/// 这里收成**一条规则**，两条轨共用，避免再次分叉。
///
/// ## 规则（只有这两条）
///
/// 1. baseUrl 已以版本段结尾（`/v1`、`/v1/`、`/v1beta`、`/v1alpha`）⇒ 原样接续，
///    不再补 `/v1`；
/// 2. 否则 ⇒ 补 `/v1` 再接。
///
/// 尾斜杠无论有没有都先吃掉，避免 `…/v1//messages`。
///
/// ## 不改 openai_client
///
/// `openai_client.dart`（Chat Completions 轨）**仍用 `'$baseUrl/chat/completions'`**，
/// 即"完全信任用户填的 baseUrl 自带版本前缀"。那条轨已在真机跑通，行为不动；
/// 本文件只服务 Anthropic / Responses 两轨。
library;

/// 版本段白名单：命中即视为"baseUrl 已带版本"，不再补 `/v1`。
///
/// `v1beta` / `v1alpha` 是 Google 系（Gemini）的版本段；接兼容端点时用户可能填
/// `…/v1beta`，此时补 `/v1` 反而会拼出 `…/v1beta/v1/...`。
const List<String> _versionSegments = ['/v1', '/v1beta', '/v1alpha'];

/// 把 [baseUrl] 与 API 路径 [path] 拼成最终 URL，并**避免 `/v1` 重复**。
///
/// - `joinApiPath('https://api.anthropic.com', 'messages')`
///   ⇒ `https://api.anthropic.com/v1/messages`
/// - `joinApiPath('https://relay.example.com/v1', 'messages')`
///   ⇒ `https://relay.example.com/v1/messages`（**不会** `v1/v1`）
/// - `joinApiPath('https://relay.example.com/anthropic', 'messages')`
///   ⇒ `https://relay.example.com/anthropic/v1/messages`
/// - `joinApiPath('https://relay.example.com/v1', 'responses/resp_1')`
///   ⇒ `https://relay.example.com/v1/responses/resp_1`
///
/// [path] 前后的多余 `/` 会被规整掉；[baseUrl] 的尾斜杠同理。
String joinApiPath(String baseUrl, String path) {
  var base = baseUrl.trim();

  // 吃掉尾斜杠（可能不止一个：用户手填 `…/v1//` 也见过）
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }

  // 吃掉路径前的斜杠，统一由下面拼一个
  var tail = path.trim();
  while (tail.startsWith('/')) {
    tail = tail.substring(1);
  }

  final hasVersion = _versionSegments.any(base.endsWith);

  return hasVersion ? '$base/$tail' : '$base/v1/$tail';
}
