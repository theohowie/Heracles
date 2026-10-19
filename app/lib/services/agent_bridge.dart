import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/attachment.dart';
import '../models/message.dart';
import '../models/model_capabilities.dart';
import '../models/settings.dart';
import '../models/workspace.dart';

/// Flutter → Kotlin 的桥（`15-前端选型与通道协议.md` §3.1）。
///
/// ## 为什么核心逻辑不在这里
///
/// `AgentLoop` / `Session` / `PrefixBuilder` 是**已验证的资产**
/// （66 项测试 + 实测 06/07/08/09/10），且缓存纪律（铁律 1）
/// 在 Kotlin 层由**类型**保障。Dart 只做展示与输入。
///
/// ## 概念模型（2026-10-10 修正）
///
/// ```
/// 工作区 = 用户【选择的一个已有文件夹】
///    ├── 在里面直接发消息 → 自动新建会话
///    └── 会话 ⋯重命名 / 🗑删除 / ⭐收藏
/// ```
class AgentBridge {
  static const _channel = MethodChannel('heracles/command');

  /// ★ 事件流通道（2026-10-10 流式）—— 必须与 Kotlin 侧
  /// `MainActivity.EVENT_CHANNEL` **逐字符一致**，否则静默收不到任何事件。
  static const _events = EventChannel('heracles/events');

  /// **上一次 [fetchModels] 读到的模型能力映射**（2026-10-14 重做）。
  ///
  /// `模型 id → 能力`。用哪个模型就取哪条 —— **不能取全局最大值**
  ///（一个 Key 下 32K 与 1M 的模型混在一起，取最大值会让小模型
  /// 显示错误上限 → 压缩永不触发 → 请求超限）。
  Map<String, ModelCapabilities> _lastFetchedCaps = const {};
  Map<String, ModelCapabilities> get lastFetchedCaps => _lastFetchedCaps;

  /// 取某个模型的能力（没拉到过返回 null）。
  ModelCapabilities? capabilitiesOf(String modelId) =>
      _lastFetchedCaps[modelId];

  // ------------------------------------------------------------ 实时事件

  /// agent 运行过程的实时事件流。
  ///
  /// ## 为什么是流而不是回调
  ///
  /// 一轮 agent 会产出多个事件（轮开始 → 原始输出 → 工具开始 → 工具结束 →
  /// … → 最终回答），请求-响应模式无法表达"持续产出"
  /// （`15-前端选型与通道协议.md` §3.1）。
  ///
  /// ## 与 [run] 的关系
  ///
  /// 两者**并行**：这个流负责"边跑边显示"，而 [run] 仍然
  /// `await` 到完整 `AgentRunResult`。**流丢了也不影响最终结果** ——
  /// 因此 UI 必须在 `run` 返回后仍以返回值为准补齐界面，
  /// 不能假设一定收全过事件。
  ///
  /// ## 使用
  ///
  /// ```dart
  /// final sub = _bridge.events.listen((e) => setState(() => ...));
  /// // 记得在 dispose 里 sub.cancel()
  /// ```
  ///
  /// 该流是**广播流**（`receiveBroadcastStream` 本身即广播，
  /// `map` 会保留这一性质），因此多个 widget 可以同时监听 ——
  /// 会话区与将来的调试面板互不干扰。
  ///
  /// 每次访问本 getter 都会**新建一条平台订阅**，
  /// 调用方应只订阅一次并保存 `StreamSubscription`。
  Stream<AgentEvent> get events => _events
      .receiveBroadcastStream()
      .map((e) => AgentEvent.fromMap(_castMap(e)));

  static Map<String, dynamic> _castMap(dynamic e) =>
      (e as Map<dynamic, dynamic>).cast<String, dynamic>();

  // ------------------------------------------------------------ 用量与上下文

  /// 上一次运行的**冻结区**估算 token；`-1` = 还没跑过任何一次。
  ///
  /// 冻结区 = 系统提示词 + 工具定义 + 工具协议，会话内逐字节不变
  /// （`02-契约规范.md` §1）。它是**每个会话都要发一遍**的固定成本，
  /// 所以"上下文被谁占了"的第一大块就是它。
  ///
  /// ⚠️ 这是 `TextMath.estimateTokens` 的**估算**，不是真实 tokenizer
  /// （`实测-08`：曾 40% 高估）—— UI 必须标 `~`。
  Future<int> lastFrozenTokens() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('usageInfo');
      return (m?['frozenTokens'] as num?)?.toInt() ?? -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      // 面板是**只读展示**，取不到就显示"未知"，不该让界面报错
      return -1;
    }
  }

  /// 上下文上限（token）。`<= 0` = 未知（不画进度条）。
  ///
  /// 取自 Kotlin 侧 —— **不在 Dart 里另写常量**，否则两处真相迟早漂移。
  ///
  /// ## ★ isCloud 必须传对（2026-10-14 用户反馈修复）
  ///
  /// 用户实测：调基元律动的 `deepseek-v4-flash-0731`（1M 上下文），
  /// UI 却显示「已用 56% · 2.3K / 4.1K」—— 本地 4096 被用到了云端。
  /// 后果不只是显示错：压缩阈值（0.8）会按 4K 触发 → **过早压缩会话**，
  /// 丢上下文并损害缓存命中（铁律 1）。
  ///
  /// @param isCloud 当前 provider 是否走云端类后端
  ///   （云 / Anthropic / Responses / 自建中转都算；只有本机 llama.cpp 不算）
  Future<int> contextLimitTokens({required bool isCloud}) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'usageInfo',
        {'isCloud': isCloud},
      );
      return (m?['contextLimit'] as num?)?.toInt() ?? -1;
    } on MissingPluginException {
      return -1;
    } on PlatformException {
      return -1;
    }
  }

  // ------------------------------------------------------------ 工作区

  /// **选一个已有文件夹**作为工作区（不是"创建新目录"）。
  ///
  /// 返回 null 表示用户取消，或选的位置没有本地路径
  /// （例如选了网盘 —— 那时无法用普通 File IO 写入）。
  Future<Map<String, dynamic>?> pickWorkspace() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('pickWorkspace');
      return m?.cast<String, dynamic>();
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException('桥接未就绪');
    }
  }

  /// 列出已登记的工作区（只返回文件夹仍存在的）
  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('listWorkspaces');
      return _maps(list);
    } on MissingPluginException {
      return const [];
    }
  }

  /// 从列表移除 —— **不删文件夹本身**
  Future<void> removeWorkspace(String path) async {
    try {
      await _channel.invokeMethod<bool>('removeWorkspace', {'path': path});
    } on MissingPluginException {
      // 忽略
    }
  }

  /// **登记内置「应用工作区」**（2026-10-17）—— 一个"能构建"的工作区。
  ///
  /// ## 为什么需要它（而且只能由 Kotlin 建）
  ///
  /// 编码层（构建 APK / 逆向）要求工作区 **App 与 shell 都能写**：
  /// 中间产物由 shell（Shizuku/Stellar）产出，插 dex / 对齐 / 读产物由 App 自己写。
  /// 真机实测（`测试机`，2026-10-17）只有一处同时满足：
  ///
  /// | 位置 | App 写 | shell 写 |
  /// |---|---|---|
  /// | 用户自己的 `/sdcard/Download/…` | ✗ `Permission denied` | ✓ |
  /// | `Android/data/<pkg>/files/**` | ✓ | ✓ |
  ///
  /// 而 [pickWorkspace]（SAF）**选不到** `Android/data`（Android 11+ 不允许浏览）。
  /// ⇒ 用户在侧边栏点这个入口，由 App 自己把那个目录登记成工作区。
  ///
  /// ## 诚实边界
  ///
  /// 该目录对用户**不完全可见**、**卸载即丢** —— 它是"可构建的沙箱"，
  /// 不是用户的项目目录。见 `26` §6.5 末尾的遗留。
  ///
  /// @return 登记后的工作区（形状同 [listWorkspaces] 的条目）；`null` = 建不出目录
  Future<Map<String, dynamic>?> ensureAppWorkspace() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('ensureAppWorkspace');
      return m?.cast<String, dynamic>();
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException('桥接未就绪');
    }
  }

  // ------------------------------------------------------------ 会话

  Future<List<HSession>> listSessions(String workspacePath, {String treeUri = ''}) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('listSessions', {
        'workspacePath': workspacePath,
        // SAF 授权时必须有 treeUri —— 否则 Kotlin 侧会走 java.io.File 然后 EPERM
        'treeUri': treeUri,
      });
      return _maps(list).map(HSession.fromMap).toList();
    } on MissingPluginException {
      return const [];
    }
  }

  /// ★ 所有会话操作都必须带 [treeUri]。
  ///
  /// SAF 授权的工作区，Kotlin 侧用它决定走 `DocumentFile` 还是 `java.io.File`。
  /// 漏传的后果是 `EPERM (Operation not permitted)`（真机实测过两次）。
  Future<String?> createSession(
    String workspacePath,
    String title, {
    String treeUri = '',
  }) async {
    try {
      return await _channel.invokeMethod<String>('createSession', {
        'workspacePath': workspacePath,
        'treeUri': treeUri,
        'title': title,
      });
    } on MissingPluginException {
      return null;
    }
  }

  /// **建一个新会话并把前缀消息灌进去**（2026-10-13，回答的「新会话分支」）。
  ///
  /// ## 为什么必须走 Kotlin（不能在 Dart 里拼 jsonl）
  ///
  /// `.jsonl` 的格式与路径由 `SessionStore` 说了算
  /// （`<工作区>/.heracles/sessions/<id>.jsonl`）。Dart 侧自己拼字符串
  /// 等于**复制一份格式知识** —— 以后格式一改就两地不一致。
  ///
  /// ## 为什么不是"在原会话上开分支"
  ///
  /// 会话必须**严格 append-only**（铁律 1）：append-only 命中 90–99%
  /// 可依赖，而分支只有 **25–105%、不可预测**（ADR-001）。
  /// 所以"分支"落地成**新建会话 + 复制前缀** —— 新会话从一开始
  /// 就是干净的 append-only 流。代价是上下文要重新预填充一次。
  Future<String?> seedBranch({
    required String workspacePath,
    required String title,
    required List<Map<String, String>> entries,
    String treeUri = '',
  }) async {
    try {
      return await _channel.invokeMethod<String>('seedBranch', {
        'workspacePath': workspacePath,
        'treeUri': treeUri,
        'title': title,
        'entries': entries,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    }
  }

  Future<void> renameSession(
    String workspacePath,
    String sessionId,
    String title, {
    String treeUri = '',
  }) async {
    try {
      await _channel.invokeMethod<bool>('renameSession', {
        'workspacePath': workspacePath,
        'treeUri': treeUri,
        'sessionId': sessionId,
        'title': title,
      });
    } on MissingPluginException {
      // 忽略
    }
  }

  Future<void> deleteSession(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async {
    try {
      await _channel.invokeMethod<bool>('deleteSession', {
        'workspacePath': workspacePath,
        'treeUri': treeUri,
        'sessionId': sessionId,
      });
    } on MissingPluginException {
      // 忽略
    }
  }

  /// 切换收藏，返回新状态
  Future<bool> toggleStar(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async {
    try {
      return await _channel.invokeMethod<bool>('toggleStar', {
            'workspacePath': workspacePath,
            'treeUri': treeUri,
            'sessionId': sessionId,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// ★ 读取一个会话的历史消息（2026-10-10 修复丢记录 bug）
  ///
  /// 返回原始行列表，由上层转成 UI 模型 —— 桥接层不猜 UI 的形状。
  Future<List<Map<String, dynamic>>> loadMessages(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('loadMessages', {
        'workspacePath': workspacePath,
        'treeUri': treeUri,
        'sessionId': sessionId,
      });
      return _maps(list);
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      return const [];
    }
  }

  /// 切换归档，返回新状态
  Future<bool> toggleArchive(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async {
    try {
      return await _channel.invokeMethod<bool>('toggleArchive', {
            'workspacePath': workspacePath,
            'treeUri': treeUri,
            'sessionId': sessionId,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  // ------------------------------------------------------------ 运行

  /// 跑一次 agent。
  ///
  /// **[sessionId] 为 null 时，Kotlin 侧会【自动新建会话】** ——
  /// 这就是"在工作区里直接发消息"的行为，与桌面版一致。
  Future<AgentRunResult> run({
    required String workspacePath,
    required String request,
    required AppSettings settings,
    String? sessionId,
    String treeUri = '',
    List<HAttachment> attachments = const [],
  }) async {
    final provider = settings.effectiveProvider;

    // ★★ 未配置 provider ⇒ **就地明确失败**（2026-10-18，ADR-035 S4）★★
    //
    // ## 为什么不能"兜底"（这是本段存在的全部理由）
    //
    // 改之前是 `null => 'local'`：没选/没配 provider 就**静默**当成"本地后端"。
    // 本地后端删除后 `'local'` 在 Kotlin 侧是 `error(...)` ⇒ 用户看到的会是
    // 一句**装配期异常**（"本地后端已删除…"），既看不懂也不知道该干什么。
    //
    // 所以这里**不兜底到任何后端**：宁可在进通道之前就停下，把
    // **下一步该做什么**直接说给用户（`_reportRunFailure` 会把这句话
    // 原样显示在会话里）。
    //
    // ⚠️ 三个都要拦：`provider == null`（一个都没有）、`baseUrl` 为空、
    //    `apiKey` 为空。**空 Key 绝不能发出去** —— 服务端只会回 401，
    //    用户得到的是"Key 不对"，而真因是"根本没配"。
    //    唯一例外是**自建/局域网端点**：它可能确实不需要 Key（内网自建中转），
    //    所以那种情况只要求 `baseUrl`。
    final needsKey = provider != null && !AppSettings.isLocalConfig(provider);
    if (provider == null ||
        provider.baseUrl.trim().isEmpty ||
        (needsKey && provider.apiKey.trim().isEmpty)) {
      throw const AgentBridgeException(
        '还没有可用的模型提供商：请到「设置 → 模型」里选一个云端提供商并填入 API Key，'
        '然后回到这里重发。',
      );
    }

    // ★ 协议分派（2026-10-14）：三协议真实支持（各有对应 Kotlin provider）
    //
    // | protocol | backend 参数 | Kotlin 分派到 |
    // |---|---|---|
    // | anthropic | 'anthropic' | AnthropicProvider（x-api-key + /v1/messages）|
    // | openaiResponses | 'responses' | OpenAiResponsesProvider（/v1/responses）|
    // | openaiChat | 'cloud' | OpenAiCompatProvider |
    //
    // ⚠️ **`'local'` 已不存在**（ADR-035）：原先"自建/局域网 ⇒ `'local'`
    //   （带 `enable_thinking=false`）"那条分支随本地后端一起删除 ——
    //   自建端点今天同样走 `'cloud'`（OpenAiCompatProvider）。
    //   不要再让这里产出 `'local'`：Kotlin 侧那个分支现在是 `error(...)`。
    final backend = switch (provider.protocol) {
      ProviderProtocol.anthropic => 'anthropic',
      ProviderProtocol.openaiResponses => 'responses',
      ProviderProtocol.openaiChat => 'cloud',
    };

    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('runAgent', {
        'workspacePath': workspacePath,
        'request': request,
        'sessionId': sessionId,
        // SAF tree URI —— 分区存储下必须靠它才能读写
        'treeUri': treeUri,
        'backend': backend,
        // ⚠️ 这里**不再有兜底值**（原 `provider?.model ?? 'qwen3.5-4b'`）：
        //   provider 已在上方确保非空，模型名直接取用户的真实配置。
        //   拿一个写死的模型名去兜底是**假信息** —— 用户没配就该明确失败。
        'baseUrl': provider.baseUrl,
        'apiKey': provider.apiKey,
        'modelName': provider.model,
        // ★ 推理等级五档（2026-10-12，S4/S5）—— 字符串必须与 Kotlin 侧
        //   `ReasoningLevel` 的 `name.lowercase()` 逐字符一致。
        //   缺省 `auto` 与改造前行为一致（本地的 auto = 关思考）。
        //   Kotlin 侧对不认识的值会**回落 AUTO 并留日志**，不会崩。
        'reasoningLevel': settings.reasoningLevel.wire,
        // ★ 审批档位（2026-10-19）—— 字符串与 Kotlin `ApprovalMode` 的 name 对齐：
        //   manual / workspaceAuto / fullAccess。Kotlin 认不出 ⇒ 回落 WORKSPACE_AUTO。
        'permission': settings.permission.name,
        // ★ 单次任务最大轮次（2026-10-18，docs/27 P0-1 / ADR-033）。
        //
        // ## 修的是什么
        //
        // 这个参数**以前根本不存在** —— `AgentLoop` 的 maxTurns 硬编码 8，
        // 所以真机上**云端模型也只在 8 轮内跑**，长任务被无理由截断
        // 且没有任何提示。
        //
        // ## 为什么 `0` 也必须传（不能"默认就不传"）
        //
        // `0` 的语义是**"按后端自动"**（Kotlin `Contract.Budget`：本地 8 / 云端 40），
        // 不是"没设置"。Kotlin 侧按这个名字读；显式传 `0` 让"自动"
        // 这个选择是**可观测**的（抓包/日志里一眼看到用户确实选了自动），
        // 也避免以后有人把 Kotlin 侧默认值改掉时这边的行为悄悄变。
        'maxTurns': settings.maxTurns,
        'attachments': attachments
            .map((a) => {
                  'path': a.path,
                  'name': a.name,
                  'kind': a.kind.name,
                })
            .toList(),
      });
      if (raw == null) {
        throw const AgentBridgeException('Kotlin 侧返回空结果');
      }
      return AgentRunResult.fromMap(raw);
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException(
        '桥接未就绪 —— 请确认已重新构建 APK（不是热重载）',
      );
    }
  }

  /// **停止当前在跑的那一轮**（2026-10-13）。
  ///
  /// 用户实测反馈：「暂停不了？」—— 停止按钮画出来了，但点下去
  /// 只会又发一条消息。Kotlin 侧此前**没有任何取消能力**。
  ///
  /// Kotlin 侧用 `job.cancel()` 真停：取消会传播到
  /// `HttpJson.postSse` 的 `finally`，那里 `close()` 输入流 +
  /// `disconnect()` 连接，**打断阻塞中的 `read()`**。
  ///
  /// 返回值：`true` = 确实取消到了一个在跑的任务；
  /// `false` = 没有在跑的（幂等，不是错误 —— 用户可能连点两下）。
  Future<bool> cancelRun() async {
    try {
      final r = await _channel
          .invokeMapMethod<String, dynamic>('cancelRun', const {});
      return (r?['cancelled'] as bool?) ?? false;
    } on MissingPluginException {
      // 桥接未就绪时不要抛 —— 停止是"尽力而为"的操作，
      // 抛异常会让界面弹一条用户看不懂的红字
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// **向正在跑的任务插话**（2026-10-13，思考间隙引导）。
  ///
  /// ## 语义（与"停止"完全不同，用户原话）
  ///
  /// 「注意不是第一个任务结束，是第一个任务的当前的思考过程结束了
  /// 再引导」—— Kotlin 侧**不打断**当前轮；AgentLoop 在当前轮完整
  /// 结束、下一轮开始前把插话 append 进会话（`Turn.User`）。
  /// 模型在下一轮自行比对原任务与插话，决定修改/追加/删除。
  ///
  /// ## 返回 `false` 时调用方必须走**正常发送**
  ///
  /// 没有在跑的任务时"插话"与"发送"本就是同一件事 ——
  /// Kotlin 侧如实回 `accepted: false`，这里透传；
  /// **不要**在这里代发第二条，避免同一句话跑两遍。
  Future<bool> interruptRun(String text) async {
    try {
      final r = await _channel
          .invokeMapMethod<String, dynamic>('interruptRun', {'text': text});
      return (r?['accepted'] as bool?) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// **设备权限状态**（2026-10-16，无线调试/Shizuku/adb 授权引导）。
  ///
  /// `writeSecureSettings` = 无障碍自愈的钥匙（ADR-016）是否已授予；
  /// `guidance` = 未授予时的三渠道引导文案（已授予为空串）；
  /// `shizuku` = **执行路由诊断**（ping / preV11 / granted / sui）——
  /// 用来解释「命令执行成功但 Shizuku 显示 0 个已授权应用」：
  /// 本机若装了 Stellar 等 Sui 系管理器，Shizuku-API 会**走 Sui**，
  /// Shizuku 的授权列表自然是 0。
  Future<
      ({
        bool writeSecureSettings,
        String guidance,
        Map<String, dynamic> shizuku,
      })> devicePermission() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('devicePermission');
      return (
        writeSecureSettings: (m?['writeSecureSettings'] as bool?) ?? false,
        guidance: (m?['guidance'] as String?) ?? '',
        shizuku: (m?['shizuku'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    } on MissingPluginException {
      return (
        writeSecureSettings: false,
        guidance: '',
        shizuku: <String, dynamic>{},
      );
    } on PlatformException {
      return (
        writeSecureSettings: false,
        guidance: '',
        shizuku: <String, dynamic>{},
      );
    }
  }

  /// **Shizuku 授权并执行 pm grant**（2026-10-16 用户反馈完善）。
  ///
  /// 用户原话：「我在 shizuku 上面都找不到本 app 来授权」——
  /// 因为 App 没集成 Shizuku SDK。现在集成了：
  /// 点这个按钮 → Shizuku 弹授权框 → 同意后自动执行
  /// `pm grant <pkg> WRITE_SECURE_SETTINGS`（无障碍自愈钥匙）。
  ///
  /// 返回 `(success, message)` —— message 是可读的执行结果/错误。
  Future<({bool success, String message})> shizukuGrant() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('shizukuGrant');
      return (
        success: (m?['success'] as bool?) ?? false,
        message: (m?['message'] as String?) ?? '',
      );
    } on MissingPluginException {
      return (success: false, message: '平台未实现');
    } on PlatformException catch (e) {
      return (success: false, message: e.message ?? '调用失败');
    }
  }

  /// **强制走一次 Shizuku 授权弹窗**（2026-10-16）。
  ///
  /// 场景：诊断显示 `Shizuku 已授权本 App = 是`，但 Shizuku UI 显示
  /// 「已授权 0 个应用」—— 因为本 App 的授权是**遗留记录**，
  /// 从未走过 Shizuku 的申请弹窗，而它的列表只收录"走过申请流程"的应用。
  ///
  /// 本方法无条件调用 `Shizuku.requestPermission()`，让弹窗真的出现一次。
  Future<({bool success, String message})> shizukuForceRequest() async {
    try {
      final m =
          await _channel.invokeMapMethod<String, dynamic>('shizukuForceRequest');
      return (
        success: (m?['success'] as bool?) ?? false,
        message: (m?['message'] as String?) ?? '',
      );
    } on MissingPluginException {
      return (success: false, message: '平台未实现');
    } on PlatformException catch (e) {
      return (success: false, message: e.message ?? '调用失败');
    }
  }

  /// **App 进程内的编码层自检**（2026-10-17）。
  ///
  /// ## 它存在的理由
  ///
  /// 编码层的真机验证（`实测-12`）走的是**设备上跑引擎**那条路
  /// （`:cli` 的 `OnDeviceEncodeProbe` 是**别的进程**）。
  /// App 自己的三个设备类 —— `DeviceShellRunner`（Shizuku/Stellar 路由）、
  /// `AgentBuildService`（防 LMK 的前台服务）、`SystemHealthSource`（温度/电量）——
  /// **一次都没在真机上跑过**，它们只是「编译过、APK 装得上」。
  ///
  /// 本方法把它们串起来在**应用进程里**真跑一遍：
  /// 起前台服务 → 读健康 → 定位工具链 → 起 shell（`id`/`java -version`）
  /// → 建 Hello World 骨架 → 真构建 → **自己拆包看条目**（不信 `ok=true`）。
  ///
  /// 返回**给人看的报告文本**（逐行说明每一步的结果，失败也带原因）。
  Future<String> encodeSelfCheck() async {
    try {
      final s = await _channel.invokeMethod<String>('encodeSelfCheck');
      return s ?? '（平台没返回内容）';
    } on MissingPluginException {
      return '平台未实现（测试环境）';
    } on PlatformException catch (e) {
      return '调用失败：${e.message ?? e.code}';
    }
  }

  /// **ask_user 的回答通道**（2026-10-16 用户需求「ask 功能」）。
  ///
  /// 模型调 `ask_user` 工具时会**挂起等待** —— UI 收到 [kAskUser]
  /// 事件后弹窗，用户提交回答时调用本方法。回答作为工具结果
  /// 返回给模型，任务继续。
  ///
  /// 没有在跑的任务时调用是**无害的**（Kotlin 侧队列已置 null，直接丢弃）。
  Future<void> replyAsk(String text) async {
    try {
      await _channel.invokeMethod<bool>('replyAsk', {'text': text});
    } on MissingPluginException {
      // 平台未实现（测试环境）—— 静默
    } on PlatformException {
      // 队列已作废（run 已结束）—— 回答无意义，丢弃
    }
  }

  /// **危险操作审批通道**（2026-10-19）。
  ///
  /// 工具返回 `NeedsApproval` 时 Kotlin 侧会发 [kApprovalRequest] 并**挂起**；
  /// UI 弹窗让用户选「允许 / 拒绝」，然后调用本方法。
  /// 没有在跑的任务时调用无害（Kotlin 侧队列已置 null）。
  Future<void> replyApproval(bool allow) async {
    try {
      await _channel.invokeMethod<bool>('replyApproval', {'allow': allow});
    } on MissingPluginException {
      // 平台未实现（测试环境）—— 静默
    } on PlatformException {
      // 队列已作废（run 已结束）—— 决定无意义，丢弃
    }
  }

  /// **拉取后端的可用模型列表**（2026-10-14，接入第三方 API 服务）。
  ///
  /// ## 为什么需要它
  ///
  /// 用户接入第三方聚合服务（如基元律动 tokenrhythm.studio）时，
  /// **不可能知道后端有哪些模型名** —— 手填必然填错（一个字符就 404/400）。
  /// OpenAI 兼容服务都有标准端点 `GET /v1/models`，拉回来让用户点选。
  ///
  /// ## 顺带读上下文长度
  ///
  /// 调完 [fetchModels] 后，[lastFetchedContextLength] 会带上
  /// 服务端上报的模型能力（**权威**）—— 用户实测痛点：
  /// 模型是 1M 上下文，App 却按猜的 128K 算，导致
  /// ① 使用率显示失真 ② **按 128K×0.8 过早压缩会话**。
  ///
  /// ## 协议（两级回退）
  ///
  /// ① **OpenAI 标准**：`GET {baseUrl}/models`，`Authorization: Bearer <key>`
  ///    响应 `{"data":[{"id":"gpt-4o","context_length":128000},…]}`
  /// ② **中转站专有**（能力字段在标准端点缺失时）：试 `{origin}/api/models`
  ///    —— 实测基元律动在这里返回完整的 `contextWindow` 等字段
  ///
  /// ## 为什么必须问服务端，不能内置表
  ///
  /// 用户实测抓到我编的表错了 2/25（`deepseek-flash` 与 `kimi-k3`
  /// 都是 1M，我写成 128K/256K）。中转站的模型名是**它自己起的别名**，
  /// 同一名字在不同中转站能力可能不同 —— 任何内置表都只是猜。
  ///
  /// ## 为什么用 Dart 直连（与测试连接同理由）
  ///
  /// 这是**配置期的一次性诊断操作**，不走 agent 链路（不建会话、
  /// 不落盘）。且纯 HTTP GET 无平台依赖 —— 不需要动 Kotlin。
  ///
  /// 返回模型 id 列表（按字母排序，去重）；能力映射存在
  /// [lastFetchedCaps] 里。失败抛 [AgentBridgeException]（人话消息）。
  Future<List<String>> fetchModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final url = '$base/models';
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      if (resp.statusCode == 401) {
        throw const AgentBridgeException('API Key 不对（401）');
      }
      if (resp.statusCode != 200) {
        throw AgentBridgeException(
          'HTTP ${resp.statusCode}：'
          '${body.length > 100 ? body.substring(0, 100) : body}',
        );
      }

      final j = jsonDecode(body);
      final ids = <String>[];
      // ★ 收集**每个模型**的能力信息（2026-10-14 重做）
      //
      // ## 之前错在哪
      //
      // 第一版取所有模型的 context_length **最大值**当全局上限 ——
      // 一个 Key 下有 25 个模型（有的 32K、有的 1M），取最大值
      // 会让 32K 的模型也显示 1M 上限 → 压缩永不触发 → 请求超限报错。
      //
      // ## 现在：按模型名精确匹配
      //
      // 存成 `模型 id → 能力` 的映射，用哪个模型就取哪条。
      final caps = <String, ModelCapabilities>{};
      void scanItem(dynamic e) {
        if (e is! Map) return;
        final id = e['id'] ?? e['name'];
        if (id is! String || id.isEmpty) return;
        ids.add(id);
        final c = ModelCapabilities.fromJson(e);
        if (c.hasAny) caps[id] = c;
      }

      if (j is Map && j['data'] is List) {
        // OpenAI 标准形状：{"data":[{"id":"…"},…]}
        for (final e in j['data'] as List) {
          scanItem(e);
        }
      } else if (j is List) {
        // 变体：直接就是数组 [{"id":"…"},…]
        for (final e in j) {
          scanItem(e);
        }
      }
      if (ids.isEmpty) {
        throw const AgentBridgeException('后端返回了空模型列表');
      }
      ids.sort();

      // ★★ 二级回退：标准端点没给能力字段时，试中转站专有端点 ★★
      //
      // 实测（2026-10-14）：基元律动的 `/v1/models` 未必带 `contextWindow`，
      // 但它的公开模型 API `/api/models` **带完整能力画像**
      //（29 个模型全有 contextWindow / maxOutputTokens / supportsTools…）。
      //
      // 为什么值得做：用户实测的痛点正是"上限算错"——
      // 而**能问就不要猜**。多试一个端点，胜过多一张会过期的表。
      if (caps.isEmpty) {
        final extra = await _tryFetchVendorCaps(base, apiKey);
        if (extra != null) caps.addAll(extra);
      }

      _lastFetchedCaps = caps;
      return ids.toSet().toList();
    } on FormatException {
      throw const AgentBridgeException('响应不是合法 JSON —— 检查 Base URL 是否正确');
    } on SocketException catch (e) {
      throw AgentBridgeException('连不上：${e.message}');
    } on HttpException catch (e) {
      throw AgentBridgeException('请求失败：${e.message}');
    }
  }

  /// **只拉模型能力**（不拉列表）—— 供"自动获取"用（2026-10-14 第三版）。
  ///
  /// ## 为什么需要独立入口
  ///
  /// [fetchModels] 是**用户手动点**的操作（拉列表给用户选）。
  /// 但能力获取**不该依赖用户点按钮** —— 那是第二版的设计缺陷：
  /// 不点就永远显示兜底值。
  ///
  /// 本方法在**需要时自动调用**（发消息前 / 打开用量面板时），
  /// 结果由调用方持久化进 provider 配置。
  ///
  /// ## 失败静默
  ///
  /// 拿不到能力**不影响任何功能**（只影响上限显示的准确度）——
  /// 所以不抛异常，返回 null 让调用方保持现有值。
  Future<Map<String, ModelCapabilities>?> fetchCapabilitiesOnly({
    required String baseUrl,
    required String apiKey,
  }) async {
    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    try {
      // ① OpenAI 标准端点
      final caps = <String, ModelCapabilities>{};
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse('$base/models'));
      req.headers.set('Accept', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        final list = (j is Map && j['data'] is List)
            ? j['data'] as List
            : (j is List ? j : const []);
        for (final e in list) {
          if (e is! Map) continue;
          final id = e['id'] ?? e['name'];
          if (id is! String || id.isEmpty) continue;
          final c = ModelCapabilities.fromJson(e);
          if (c.hasAny) caps[id] = c;
        }
      }
      client.close();

      // ② 标准端点没给能力 → 试中转站专有端点
      if (caps.isEmpty) {
        final extra = await _tryFetchVendorCaps(base, apiKey);
        if (extra != null) caps.addAll(extra);
      }
      return caps.isEmpty ? null : caps;
    } catch (_) {
      return null; // 静默：拿不到不影响功能
    }
  }

  /// **试中转站的专有模型端点**（二级回退，2026-10-14）。
  ///
  /// ## 为什么需要
  ///
  /// OpenAI 标准 `/v1/models` **只保证 `id`**（`context_length` 是
  /// 可选扩展）—— 但很多中转站在**自己的**端点里给完整能力画像。
  /// 实测基元律动：`GET {origin}/api/models` →
  /// `{"data":[{"id":…,"contextWindow":1000000,"maxOutputTokens":384000,…}]}`
  ///
  /// ## 为什么不是"为基元律动写死"
  ///
  /// 只试一个**路径约定**（`/api/models`，去掉 Base URL 的 `/v1` 后缀），
  /// 而且**失败完全静默**（返回 null）—— 它不是主路径，
  /// 拉到是赚到，拉不到不影响任何事。
  ///
  /// @return 模型 id → 能力；任何失败都返回 null
  Future<Map<String, ModelCapabilities>?> _tryFetchVendorCaps(
    String base,
    String apiKey,
  ) async {
    try {
      // 从 baseUrl 推出 origin：`https://host/v1` → `https://host`
      final uri = Uri.parse(base);
      final origin = '${uri.scheme}://${uri.authority}';
      final url = '$origin/api/models';

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      final resp = await req.close();
      if (resp.statusCode != 200) {
        client.close();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      final j = jsonDecode(body);
      final out = <String, ModelCapabilities>{};
      final list = (j is Map && j['data'] is List)
          ? j['data'] as List
          : (j is List ? j : const []);
      for (final e in list) {
        if (e is! Map) continue;
        final id = e['id'] ?? e['name'];
        if (id is! String || id.isEmpty) continue;
        final c = ModelCapabilities.fromJson(e);
        if (c.hasAny) out[id] = c;
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      // 完全静默：这是**尽力而为**的增强，不是主路径
      return null;
    }
  }

  // ------------------------------------------------------------ 附件 / 文件

  /// 调 Android 原生选择器（SAF / 相册）挑文件。
  ///
  /// **刻意不用 file_picker**：它的 `compileSdk 34` 与传递依赖
  /// `flutter_plugin_android_lifecycle` 要求的 ≥36 冲突，
  /// 会**直接让整个构建失败**（8.3.7 与 9.2.3 都如此，实测）。
  Future<List<Map<String, dynamic>>> pickFiles({
    bool imagesOnly = false,
    bool multiple = true,
  }) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('pickFiles', {
        'imagesOnly': imagesOnly,
        'multiple': multiple,
      });
      return _maps(list);
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException('桥接未就绪');
    }
  }

  /// 列目录（"文件"视图用）
  Future<List<Map<String, dynamic>>> listDir(String path) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('listDir', {'path': path});
      return _maps(list);
    } on MissingPluginException {
      return const [];
    }
  }

  List<Map<String, dynamic>> _maps(dynamic list) => (list as List? ?? const [])
      .whereType<Map<dynamic, dynamic>>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
}

/// 桥接错误 —— 携带**人类可读**的原因
class AgentBridgeException implements Exception {
  const AgentBridgeException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// agent 运行过程中的**实时事件**（对应 Kotlin 侧 `AgentEvent`）。
///
/// ## 设计取舍：为什么用一个宽对象而不是 sealed class 层次
///
/// Kotlin 侧是 sealed interface（7 个 data class），但 Dart 这边刻意
/// 做成**单一类 + `type` 判别字段**：
/// 事件是**跨进程的弱契约**（Map），不是编译期类型。
/// 硬做成 7 个子类只会多出 7 段 `switch` 样板，却换不来任何编译期保障 ——
/// 真正的风险是"Kotlin 加了新事件类型而 Dart 不认识"，
/// 那用 [type] 判别 + 未知类型降级（[isKnown]）反而处理得更稳。
///
/// ## 所有字段都可空是刻意的
///
/// 不同 `type` 携带不同字段（`tool_started` 没有 `result`，
/// `failed` 没有 `index`）。用可空 + [type] 判别，而不是塞一堆默认值 ——
/// **默认值会伪造信息**（例如把缺失的 `ok` 当成 false，
/// UI 就会把"没执行"显示成"工具失败"）。
class AgentEvent {
  const AgentEvent({
    required this.type,
    required this.ts,
    this.index,
    this.raw,
    this.wallMs,
    this.cache,
    this.tool,
    this.args,
    this.result,
    this.ok,
    this.reason,
    this.finalText,
    this.stopReason,
    this.turnCount,
    this.message,
    this.stepId,
    this.title,
    this.delta,
    this.status,
    this.durationMs,
    this.summary,
    this.planSteps,
    this.doneCount,
    this.activeIndex,
    this.reachedGoal,
    this.planClosedReason,
  });

  /// 判别字段：轮级 `turn_started` / `model_output` / `tool_started` /
  /// `tool_finished` / `blocked` / `finished` / `failed`；
  /// token 级 `step_started` / `reasoning_delta` / `step_delta` / `step_ended`
  final String type;

  /// 事件发生时间（毫秒时间戳）
  final int ts;

  // ---- 轮次 ----
  final int? index;

  /// `model_output`：模型本轮原始输出（「完全展开」档位的数据源）
  final String? raw;

  // ---- 工具 ----
  final String? tool;
  final Map<String, String>? args;

  /// `tool_finished`：工具结果文本
  final String? result;

  /// `tool_finished`：**只有这个事件有 ok**；
  /// 其它事件为 null —— 不要默认成 false
  final bool? ok;

  /// `blocked`：拦截原因（校验失败 / 循环 / 重复 / 无法解析）
  final String? reason;

  // ---- 计时 ----
  /// `model_output` = 本轮生成墙钟；`tool_finished` = 工具执行墙钟
  final int? wallMs;

  /// `model_output`：本轮缓存指标
  final EventCacheStats? cache;

  // ---- 结束 ----
  final String? finalText;
  final String? stopReason;
  final int? turnCount;

  /// `failed`：错误信息
  final String? message;

  // ---- token 级（2026-10-12 流式逐字；见 Kotlin 侧 `AgentEvent` 的
  //      "token 级事件" 段与 `docs/25-流式工作步骤.md` §5.3）----

  /// `step_started` / `reasoning_delta` / `step_delta` / `step_ended`：
  /// 步骤标识，形如 `turn-3`。**token 级事件靠它归属到具体的步骤** ——
  /// 没有它，多步骤的增量只能全堆在最后一条消息上（必然错位）。
  final String? stepId;

  /// `step_started`：人可读标题（如「正在生成第 3 轮」）
  final String? title;

  /// `reasoning_delta` / `step_delta`：**本次增量**（几个字），
  /// 不是累积全文 —— 累加由 UI 自己做（见 `chat_screen` 的 `_deltaBuffer`）。
  final String? delta;

  /// `step_ended`：三态 `ok` / `empty` / `error`。
  ///
  /// ⚠️ **不是布尔** —— "生成了但内容为空"与"生成失败"对用户是不同的。
  final String? status;

  /// `step_ended`：该步骤墙钟耗时
  final int? durationMs;

  /// `step_ended`：生成内容的**最终完整文本** ——
  /// UI 用它替换掉逐字累积的草稿，并在此刻才做 Markdown 格式化。
  final String? summary;

  // ---- ★ 任务计划（2026-10-14，harness）----

  /// `plan_created`：待办清单的每一步文本（按顺序）
  final List<String>? planSteps;

  /// `plan_advanced`：已完成步数（前 N 个为 done）
  final int? doneCount;

  /// `plan_advanced`：当前进行中的步（0 起）；-1 = 全部完成
  final int? activeIndex;

  /// `plan_closed`：任务是否**真正达成目标**（2026-10-15，BUG-1）。
  ///
  /// · `true` → 模型给了最终回答，剩余步骤视为**已完成**（画绿勾）
  /// · `false` → 循环硬停 / 熔断 / 轮次耗尽，**明确的中断**
  /// · `null` → 老版本 Kotlin 没发这个字段（按"未知"处理，不改画法）
  ///
  /// ⚠️ 三态而非布尔：把"中断"画成"完成"是 H-1 记录过的假信息问题。
  final bool? reachedGoal;

  /// `plan_closed`：收尾原因（中断时显示给用户，如"检测到循环，已强制停止"）
  final String? planClosedReason;

  // ------------------------------------------------------------ 判别辅助

  static const kTurnStarted = 'turn_started';
  static const kModelOutput = 'model_output';
  static const kToolStarted = 'tool_started';
  static const kToolFinished = 'tool_finished';
  static const kBlocked = 'blocked';
  static const kFinished = 'finished';
  static const kFailed = 'failed';

  /// **用户插话被注入会话**（2026-10-13，思考间隙引导）——
  /// 到达时机 = 上一轮完整结束、下一轮开始前。
  static const kInterrupted = 'interrupted';

  /// **任务计划产生**（2026-10-14，harness）—— 模型首轮产出待办清单。
  ///
  /// 用户原话：「先拿到问题先分析，**做一个待办**，按照待办完成任务」。
  static const kPlanCreated = 'plan_created';

  /// **任务计划推进**（2026-10-14）——
  /// 由**真实工具执行记录**驱动（不是模型自报）。
  static const kPlanAdvanced = 'plan_advanced';

  /// **任务计划收尾**（2026-10-15，修 BUG-1）。
  ///
  /// 任务结束时 AgentLoop 明确发出 —— 告诉 UI 剩余步骤该显示成
  /// "已完成"（正常达成）还是"已中断"（循环/熔断）。
  ///
  /// 没有它，最后一步（通常是"汇报结果"，**不需要工具**）会
  /// **永远停在"进行中"**（用户实测截图：任务已结束但显示 4/5）。
  static const kPlanClosed = 'plan_closed';

  /// **ask_user：模型向用户提问**（2026-10-16 用户需求）。
  ///
  /// 到达时机：`ask_user` 工具**已挂起等待** —— UI 收到后弹窗，
  /// 用户提交回答走 [replyAsk]。
  static const kAskUser = 'ask_user';

  /// **危险工具需要用户确认**（2026-10-19，三态门禁的 UI 闭环）。
  ///
  /// 到达时机：Kotlin 侧 `AgentLoop` **已挂起**在审批队列上 —— UI 弹窗，
  /// 用户选允许/拒绝后走 [replyApproval]。允许 = 重新执行该工具；
  /// 拒绝/超时 = 作为失败回填给模型（绝不谎称成功）。
  static const kApprovalRequest = 'approval_request';

  // ---- token 级（2026-10-12）----

  /// 一个步骤开始（带 `stepId`，是逐字增量的归属锚点）
  static const kStepStarted = 'step_started';

  /// **思考增量** —— 用户要的「AI 的思考过程，一个字一个字出来」
  static const kReasoningDelta = 'reasoning_delta';

  /// **正文增量** —— 最终答案正在逐字生成
  static const kStepDelta = 'step_delta';

  /// 一个步骤结束 —— UI 据此停止"逐字"状态并重新格式化
  static const kStepEnded = 'step_ended';

  /// Kotlin 侧认识的事件类型。未知类型 = 版本不一致，
  /// UI 应当忽略而不是崩溃（跨进程弱契约的必然情况）。
  static const _knownTypes = {
    kTurnStarted,
    kModelOutput,
    kToolStarted,
    kToolFinished,
    kBlocked,
    kFinished,
    kFailed,
    kInterrupted,
    kPlanCreated,
    kPlanAdvanced,
    kPlanClosed,
    kAskUser,
    kApprovalRequest,
    kStepStarted,
    kReasoningDelta,
    kStepDelta,
    kStepEnded,
  };

  /// `step_ended` 的三态取值（与 Kotlin 侧 `StepEnded.STATUS_*` 对齐）。
  static const kStatusOk = 'ok';
  static const kStatusEmpty = 'empty';
  static const kStatusError = 'error';

  /// 是不是 token 级（逐字）事件。
  bool get isDelta =>
      type == kReasoningDelta || type == kStepDelta;
  bool get isKnown => _knownTypes.contains(type);

  /// 终止事件 —— UI 用它结束"运行中"状态
  bool get isTerminal => type == kFinished || type == kFailed;

  /// 工具**真的执行了**（区别于 blocked：没执行）
  bool get isExecutedTool =>
      (type == kToolStarted || type == kToolFinished) && tool != null;

  factory AgentEvent.fromMap(Map<String, dynamic> m) {
    final rawCache = m['cache'];
    final rawArgs = m['args'];
    return AgentEvent(
      type: (m['type'] as String?) ?? '',
      ts: (m['ts'] as num?)?.toInt() ?? 0,
      index: (m['index'] as num?)?.toInt(),
      raw: m['raw'] as String?,
      wallMs: (m['wallMs'] as num?)?.toInt(),
      cache: rawCache is Map
          ? EventCacheStats.fromMap(rawCache.cast<String, dynamic>())
          : null,
      // ★ blocked 的 tool 可能为 null（Unparseable 分支）—— 原样保留
      tool: m['tool'] as String?,
      args: rawArgs is Map
          ? rawArgs.map((k, v) => MapEntry(k.toString(), v.toString()))
          : null,
      result: m['result'] as String?,
      // ★ 只认真正的 bool；缺失就是 null，不默认 false
      ok: m['ok'] is bool ? m['ok'] as bool : null,
      reason: m['reason'] as String?,
      finalText: m['finalText'] as String?,
      stopReason: m['stopReason'] as String?,
      turnCount: (m['turnCount'] as num?)?.toInt(),
      // ★ `interrupted` 事件的插话原文走 Kotlin 的 `"text"` 字段 ——
      //   复用 `message` 承载（事件类不加专属字段，
      //   `message` 的语义就是"这条事件的人读文本"）
      message: (m['message'] ?? m['text']) as String?,
      // ★ 任务计划（2026-10-14）：`plan_created` 带 steps 数组
      planSteps: (m['steps'] as List?)?.whereType<String>().toList(),
      doneCount: (m['doneCount'] as num?)?.toInt(),
      activeIndex: (m['activeIndex'] as num?)?.toInt(),
      // ★ 计划收尾（2026-10-15，BUG-1）：
      //   `reachedGoal` 决定剩余步骤画绿勾（达成）还是"已中断"（循环/熔断）。
      //   **null 与 false 语义不同** —— null = 老 Kotlin 没发这个字段
      //   （按"未知"处理，不改画法），false = 明确的中断。
      reachedGoal: m['reachedGoal'] as bool?,
      planClosedReason: m['reason'] as String?,
      // ★ token 级字段：**缺失就是 null**，绝不伪造空串 ——
      //   空串 delta 会让 UI 以为"这一步真的吐了个空字"，
      //   而实际是版本不一致（老 Kotlin 不发这些字段）。
      stepId: m['stepId'] as String?,
      title: m['title'] as String?,
      delta: m['delta'] as String?,
      status: m['status'] as String?,
      durationMs: (m['durationMs'] as num?)?.toInt(),
      summary: m['summary'] as String?,
    );
  }

  @override
  String toString() =>
      'AgentEvent($type, index=$index, tool=$tool, stepId=$stepId)';
}

/// 一轮的缓存指标（对应 Kotlin 侧 `CacheStats` 的子集）。
///
/// [cachedTokens] 与 [hitRate] 为 null 表示 **provider 未上报** ——
/// `02-契约规范.md` §3.4 明令：此时 UI 必须显示"不可用"，
/// **不得用 0 代替**（0 会被误读成"缓存坏了"）。
class EventCacheStats {
  const EventCacheStats({
    this.cachedTokens,
    required this.promptTokens,
    required this.outputTokens,
    this.hitRate,
  });

  final int? cachedTokens;
  final int promptTokens;
  final int outputTokens;
  final double? hitRate;

  /// provider 是否上报了缓存字段
  bool get reportingAvailable => cachedTokens != null;

  factory EventCacheStats.fromMap(Map<String, dynamic> m) => EventCacheStats(
        cachedTokens: (m['cachedTokens'] as num?)?.toInt(),
        promptTokens: (m['promptTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (m['outputTokens'] as num?)?.toInt() ?? 0,
        hitRate: (m['hitRate'] as num?)?.toDouble(),
      );
}

/// 一次 agent 运行的完整结果（对应 Kotlin 侧 `AgentRunResult`）
class AgentRunResult {
  const AgentRunResult({
    required this.stopReason,
    required this.finalText,
    required this.turns,
    required this.totalCachedTokens,
    required this.totalPromptTokens,
    required this.totalOutputTokens,
    this.steadyHitRate,
    this.sessionId,
    this.cancelled = false,
  });

  final String stopReason;
  final String finalText;
  final List<AgentTurn> turns;

  final int totalCachedTokens;
  final int totalPromptTokens;
  final int totalOutputTokens;

  /// 稳态命中率（跳过第一轮冷启动）；null = 无法计算
  final double? steadyHitRate;

  /// 本次运行所属会话。**没传 sessionId 时由 Kotlin 自动创建**。
  final String? sessionId;

  /// **这一轮是被用户取消的**（2026-10-13）。
  ///
  /// Kotlin 侧接住 `CancellationException` 时回 `cancelled: true`
  /// （那些字段本身就是空的）。UI 据此**不要**把空 `turns` /
  /// 空 `finalText` 当成"模型回答完了" —— 那会显示一条空回复。
  final bool cancelled;

  factory AgentRunResult.fromMap(Map<String, dynamic> m) {
    final rawTurns = (m['turns'] as List?) ?? const [];
    return AgentRunResult(
      stopReason: (m['stopReason'] as String?) ?? '',
      finalText: (m['finalText'] as String?) ?? '',
      turns: rawTurns
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => AgentTurn.fromMap(e.cast<String, dynamic>()))
          .toList(),
      totalCachedTokens: (m['totalCachedTokens'] as num?)?.toInt() ?? 0,
      totalPromptTokens: (m['totalPromptTokens'] as num?)?.toInt() ?? 0,
      totalOutputTokens: (m['totalOutputTokens'] as num?)?.toInt() ?? 0,
      steadyHitRate: (m['steadyHitRate'] as num?)?.toDouble(),
      sessionId: m['sessionId'] as String?,
      cancelled: (m['cancelled'] as bool?) ?? false,
    );
  }
}

/// 一轮记录（对应 Kotlin 侧 `TurnRecord`）
class AgentTurn {
  const AgentTurn({
    required this.index,
    required this.verdict,
    this.tool,
    this.args,
    this.result,
    required this.wallMs,
    this.cachedTokens,
    required this.promptTokens,
    required this.outputTokens,
    this.toolState,
  });

  final int index;
  final String verdict;
  final String? tool;
  final Map<String, String>? args;
  final String? result;
  final int wallMs;

  /// null = provider 未上报（UI 必须显示"不可用"而非 0%）
  final int? cachedTokens;
  final int promptTokens;
  final int outputTokens;

  /// 工具在本轮的**结构化三态**（2026-10-10 修复 H-1）。
  ///
  /// ## 为什么不再用 [isFailure] 猜
  ///
  /// 原先 UI 靠 `verdict.contains('失败')` 决定卡片颜色，而拦截类的
  /// verdict（"重复调用已拦截…"、"★ 检测到循环，强制停止"）**不含「失败」**
  /// → 被当成成功 → 画出**绿色成功卡**（而工具**从未执行**）。
  ///
  /// 那是比"失败"更糟的**假信息**。靠中文字符串匹配判定状态本身就是
  /// 脆弱的（改一个字就失效），所以改为消费 Kotlin 侧算好的结构化字段。
  ///
  /// `null` = 旧记录或旧后端**没有**提供该字段 —— 此时回落到
  /// [isFailure] 的启发式（并**不会**误报成功，见 [AgentTurn.fromMap]）。
  final ToolState? toolState;

  /// 工具**是否真的执行过**（含失败）。被拦截 = false。
  bool get toolExecuted =>
      toolState == ToolState.succeeded || toolState == ToolState.failed;

  /// 工具是否**成功执行** —— **唯一**允许画绿色的条件。
  ///
  /// `toolState == null`（旧数据）时回落到启发式：只有明确不是失败才当成功。
  bool get toolSucceeded =>
      toolState == ToolState.succeeded ||
      (toolState == null && tool != null && !isFailure);

  /// 工具是否**被拦截、从未执行**。
  bool get toolBlocked => toolState == ToolState.blocked;

  /// 启发式（**仅供旧数据回落**）：verdict 里含失败/拒绝/循环。
  ///
  /// ⚠️ 不要用它决定新数据的卡片颜色 —— 用 [toolState]。
  bool get isFailure =>
      verdict.contains('失败') || verdict.contains('拒绝') || verdict.contains('循环');

  TurnMetrics get metrics => TurnMetrics(
        cachedTokens: cachedTokens,
        promptTokens: promptTokens,
        outputTokens: outputTokens,
        wallMs: wallMs,
      );

  factory AgentTurn.fromMap(Map<String, dynamic> m) {
    final rawArgs = m['args'];
    return AgentTurn(
      index: (m['index'] as num?)?.toInt() ?? 0,
      verdict: (m['verdict'] as String?) ?? '',
      tool: m['tool'] as String?,
      args: rawArgs is Map
          ? rawArgs.map((k, v) => MapEntry(k.toString(), v.toString()))
          : null,
      result: m['result'] as String?,
      wallMs: (m['wallMs'] as num?)?.toInt() ?? 0,
      cachedTokens: (m['cachedTokens'] as num?)?.toInt(),
      promptTokens: (m['promptTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (m['outputTokens'] as num?)?.toInt() ?? 0,
      // ★ 结构化三态：只认已知取值，不认识就当"没提供"（走回落）
      toolState: ToolState.parse(m['toolState'] as String?),
    );
  }
}

/// 工具在一轮里的**三态**（对应 Kotlin 侧 `ToolState`）。
///
/// **被拦截 ≠ 失败** —— 这是 H-1 的根源，也是本枚举存在的理由。
enum ToolState {
  /// 本轮没有请求工具
  none,

  /// 执行了，成功
  succeeded,

  /// 执行了，失败（工具自身报错）
  failed,

  /// **请求了但从未执行** —— 架构层拦截（循环/重复/校验不过）
  blocked;

  /// 容错解析：未知/缺失 → `null`（让调用方走启发式回落，
  /// 而不是把不认识的值当成成功）。
  static ToolState? parse(String? raw) => switch (raw) {
        'succeeded' => ToolState.succeeded,
        'failed' => ToolState.failed,
        'blocked' => ToolState.blocked,
        'none' => ToolState.none,
        _ => null,
      };
}
