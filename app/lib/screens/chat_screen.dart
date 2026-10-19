import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attachment.dart';
import '../models/message.dart';
import '../models/session_usage.dart';
import '../models/settings.dart';
import '../models/view_options.dart';
import '../models/workspace.dart';
import '../services/agent_bridge.dart';
import '../services/model_context_table.dart';
import '../services/settings_controller.dart';
import '../theme/app_theme.dart';
import 'settings_screen.dart';
import '../widgets/input_bar.dart';
import '../widgets/message_row.dart';
import '../widgets/plan_checklist.dart';
import '../widgets/usage_sidebar.dart';
import '../widgets/workspace_drawer.dart';

/// 会话主屏 —— 默认首屏（`06-UI界面设计.md` §6.1）。
///
/// ## 概念模型（2026-10-10 修正）
///
/// ```
/// 工作区 = 用户【选择的一个已有文件夹】
///    ├── 在里面直接发消息 → 自动新建会话
///    └── 会话 ⋯重命名 / 🗑删除 / ⭐收藏 / 📦归档
/// ```
///
/// 核心逻辑全部在 Kotlin（`15-前端选型与通道协议.md` §2 的硬约束）。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.settings});

  final SettingsController settings;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _bridge = AgentBridge();

  final List<HMessage> _messages = [];
  final Map<String, TurnMetrics> _metrics = {};
  final List<HAttachment> _attachments = [];

  /// **输入框控制器**（2026-10-13，「编辑重发」用）——
  /// 长按用户消息 → 编辑 → 原文写进这里，InputBar 用同一个控制器渲染。
  final TextEditingController _inputCtrl = TextEditingController();

  /// **用户对每条回答的反馈**（2026-10-13）—— 消息 id → 赞/踩。
  ///
  /// 只存内存：这是**本条会话内的一次性态度**，不落盘也不上报。
  /// 发行版若要接云端评价，在写这个 Map 的地方加一次网络调用即可。
  final Map<String, AnswerFeedback> _feedback = {};

  /// 每条回答的时间戳 —— 操作行右侧那个 `14:32`。
  /// 消息模型本身没带时间（`HAssistantMessage` 只有 id/text），
  /// 用"进入列表的时刻"记一份，够用且不改模型。
  final Map<String, DateTime> _answerTs = {};

  // ---- ★ 任务计划状态（2026-10-14，harness）----
  //
  // 用户原话：「顶部显示任务计划（1.查看结构 ✓ 2.写HTML ←进行中 3.验证）」
  //
  // 为什么放 chat_screen 而不是塞进 _messages：
  // 计划是**当前任务的进度**，不是对话历史的一条 —— 它常驻列表顶部
  // （随任务推进更新），而不是像消息那样随滚动流走。

  /// 当前任务的待办清单（null = 模型没给计划，或已清）
  List<String>? _planSteps;

  /// 已完成步数（由**真实工具执行**推进，非模型自报）
  int _planDone = 0;

  /// 当前进行中的步（0 起）；-1 = 全部完成
  int _planActive = 0;

  /// 用户收起了清单
  bool _planCollapsed = false;

  /// **计划是否真正达成目标**（2026-10-15，BUG-1）。
  ///
  /// `null` = 还没收尾 / 老版本 Kotlin 没发该字段。
  /// `false` = 中断（循环硬停 / 熔断 / 轮次耗尽）——
  /// UI 必须显示成"已中断"，**不能画成完成**（H-1 的教训：
  /// 把失败画成成功比失败本身更糟）。
  bool? _planReachedGoal;

  /// 中断原因（`_planReachedGoal == false` 时显示给用户）
  String? _planClosedReason;

  /// **排队中的消息**（2026-10-13，按用户参考图改为**列表**）。
  ///
  /// 设置里 `BusySendBehavior.queue`（"排队发送 —— 等当前任务结束再发"）
  /// 是默认值但从未接线，用户报「会话有在工作时，点不了输入框发送消息」。
  ///
  /// ## 为什么是列表而不是"只留一条"
  ///
  /// 我第一版做成"最多一条，后来的替换先来的"。用户给的参考图里
  /// 排队区是一个**可容纳多条**的列表（每行一条 + 置顶/删除/立即发送），
  /// 且输入框提示写着「插话发送全部排队消息」—— 显然支持多条。
  ///
  /// 队列**仍然不产生并行**：只在 `_busy == false` 时逐条出队，
  /// 前一条跑完后才发下一条（`_drainQueue` 每次只取队首）。
  final List<_QueuedMsg> _queue = [];

  /// 忙时输入框是否仍可用 —— 由用户的 `BusySendBehavior` 决定。
  ///
  /// `queue`（默认）与 `interrupt` 都让输入框保持可用：
  /// 前者把消息排队，后者点发送时先停当前任务。
  /// 只有"当前会话在跑"且**没有**任何发送策略时才会禁用。
  bool get _queuedSendEnabled {
    if (!_inputBlocked) return true; // 本来就没在跑
    final b = widget.settings.value.busySend;
    // 两种策略都允许用户继续输入/发送
    return b == BusySendBehavior.queue || b == BusySendBehavior.interrupt;
  }

  bool _busy = false;
  bool _loading = true;
  String? _error;

  // ---- ★ 逐字渲染：buffer + 16ms flush（2026-10-12，`docs/25` §5.3）----
  //
  // ## 为什么必须缓冲，而不是每来一个字就 setState
  //
  // 本地模型满载时约 **250 token/s**（`docs/25` §5.4）。每 token 一次
  // `setState` = 每秒 250 次整棵树重建 —— 结果就是用户要的"逐字"
  // 变成"卡顿"，比一次性显示还难受。
  //
  // 16ms ≈ 60fps 的一帧：**一帧最多重建一次**，不管这一帧里到了多少 token。
  //
  // ⚠️ 这里与 `StreamCoalescer`（Kotlin 侧）**不是重复劳动**：
  //   · Kotlin 侧合并省的是 MethodChannel 与主线程 post 的开销
  //   · 这里省的是 Flutter 的 build/layout 开销
  // 两端都不能省（对方管不到对方那一层）。另外 `docs/25` §13.4 已实测：
  // 真机 chunk 间隔中位数可能到 6 秒，那时压缩比必然是 1.0× ——
  // **不要为了追求压缩比去"优化"这里**，那不是缺陷。
  //
  // key = `stepId + 通道`（`'r'` 思考 / `'t'` 正文）—— 两个通道各攒各的。
  final Map<String, String> _deltaBuffer = {};

  /// 16ms 帧定时器。**必须在 [dispose] 与 [_stopLive] 里取消** ——
  /// 否则页面销毁后它还会跑，对着一个已卸载的 State 调 `setState`。
  Timer? _flushTimer;

  /// 是否还有**没刷出去的**缓冲内容（测试与诊断用）。
  bool get hasPendingDeltas => _deltaBuffer.isNotEmpty;

  /// 16ms 帧定时器**当前是否活着**。
  ///
  /// 暴露它不是为了 UI，而是为了**可测**：`Timer.periodic` 不受 widget
  /// 生命周期管理，泄漏了也不会立刻报错（要等它下一次触发才崩）。
  /// 把状态摊开，测试才能直接断言"dispose 之后它已经不在了"。
  /// 见 `test/stream_render_test.dart` 的「dispose 之后 16ms 定时器必须已取消」。
  @visibleForTesting
  bool get hasFlushTimer => _flushTimer?.isActive ?? false;

  List<HWorkspace> _workspaces = [];

  /// 当前会话（null = 还没开始，发第一条消息时由 Kotlin 自动创建）
  String? _activeSessionId;

  /// 视图选项（分组/排序/筛选）—— 持久化，重启后保留
  ViewOptions _view = const ViewOptions();

  /// 会话搜索关键词
  String _search = '';

  /// 正在从磁盘读会话历史
  bool _loadingHistory = false;

  // ---- 实时流式状态（2026-10-10）----

  /// `heracles/events` 的订阅。
  ///
  /// **必须取消**（见 [dispose] 与 [_startLive]）—— 不取消的话
  /// 平台侧会一直持有 sink，每次进页面都多一条订阅。
  StreamSubscription<AgentEvent>? _eventSub;
  StreamSubscription<Map<String, String>>? _openSessionSub;

  /// 当前「正在生成…」占位行的 id（同一轮复用，不重复插入）
  String? _progressId;

  /// 本轮已通过事件流插入的工具卡片：`"轮次:工具名"` → 消息 id。
  ///
  /// ## 为什么按这个键去重
  ///
  /// 事件流给的是 `ToolStarted`（无 id），而 `await run()` 返回的
  /// `result.turns` 是一次性的完整列表。两条路会**各插一张同样的卡片** ——
  /// 用户看到重复。
  ///
  /// 用「轮次 + 工具名 + 参数」做键：同轮同工具同参数视为同一张卡片。
  /// 不用轮次顺序去猜（事件流断了就错位）。
  final Map<String, String> _liveToolIds = {};

  /// 待归属的模型原始输出：`轮次` → `raw`。
  ///
  /// 收到 `ModelOutput` 时先放这里，等这一轮**有没有工具调用**确定后
  /// 再决定挂到卡片上还是单独成条 —— 保证原话在界面上只出现一次。
  ///
  /// 只在「完全展开」档位会往里写；其它档位这个 map 恒为空。
  final Map<int, String> _pendingRaw = {};

  // ---- 会话守卫（2026-10-10，修复"结果串进新会话"）----
  //
  // ## 问题
  //
  // 真机实测本地模型**稳态单轮约 20 秒**（冷启动可达 132.8 秒 ——
  // 见 `docs/23-时延实测更正.md`，注意别再把冷启动当稳态引用），
  // 多轮任务近 3 分钟。用户等不及就会
  // 开抽屉切会话 —— 而 `await _bridge.run(...)` 返回时**没有检查
  // 当前会话是否还是发起时那个**，于是 A 的整轮记录被插进 B 的列表。
  //
  // 用户此前说过"切换会话记录没了，这个很恐怖啊" —— 这是同一类问题。
  //
  // ## 为什么用"上下文代号"而不只比 sessionId
  //
  // 首条消息时 `_activeSessionId` 是 null（由 Kotlin 自动建会话），
  // 只比 id 会漏掉"换工作区""新建会话"等路径。
  // 代号在**每条换上下文的路径**上自增，与会话 id 双保险。

  /// 会话上下文代号 —— 每次换上下文（切会话 / 新建 / 换工作区 / 删当前会话）自增。
  int _ctxGen = 0;

  /// 运行序号 —— 每次 `runAgent` 发起时自增（见 [_RunOrigin.runSeq]）。
  int _runSeq = 0;

  // ---- 会话用量累计（2026-10-11，t13；需求 `docs/24`）----

  /// **按会话**存的累计用量：`sessionId` → 用量。
  ///
  /// ## 为什么是按会话的 Map，而不是一个"当前会话"的字段
  ///
  /// 一开始我打算用单个字段 + `_switchContext` 里清零。但那样
  /// **A→B→A 会丢掉 A 已经累计的量** —— 而 t11 刚刚才修好"切回原会话
  /// 结果照常出现"，用量却在切回来时归零，同一类不一致会立刻被用户发现。
  ///
  /// 用 Map 后：
  /// - **显示**的永远是**当前会话**那一本账（满足"不是全局统计"）
  /// - 切来切去**不丢**（A 的量还在 A 的 key 下）
  ///
  /// 仍然**不跨重启**（Map 在内存里）—— 与 `docs/24` §7.1 的明确决定一致：
  /// `.jsonl` 没有各轮 token 数据，从磁盘恢复会严重少算。
  ///
  /// key 用 `''` 表示"还没建会话"（首条消息时 `_activeSessionId` 为 null）；
  /// Kotlin 建好会话返回 id 后会把这份量**迁移**到真实 id 下
  /// （见 [_runAgent] 里迁移那段）。
  final Map<String, SessionUsage> _usageBySession = {};

  /// 上下文上限（token）；`<= 0` = 未知
  int _contextLimit = -1;

  /// 上限的**来源说明**（诊断用）—— 让用户知道这个数字从哪来：
  /// 「服务端上报」/「DeepSeek-V4 系列 1M」/「按后端默认值」
  String _contextLimitSource = '';

  /// 自动获取能力**进行中**（防重入 —— 面板打开时可能连续触发）
  bool _autoFetchingCaps = false;

  /// 冻结区估算 token（系统提示词 + 工具定义）；`-1` = 还没跑过
  int _frozenTokens = -1;

  /// 右侧边栏**用按钮打开**（**不依赖边缘滑动**，见 `docs/24` §4.3）。
  ///
  /// ⚠️ 刻意**不引入第二个 GlobalKey** ——
  /// 我第一版加了个 `_endDrawerKey`，但它没挂到 `Scaffold` 上
  /// （`Scaffold` 用的是 [_scaffoldKey]），于是 `currentState` 恒为 null、
  /// 点指示器**静默无反应**。集成测试当场抓到了。
  ///
  /// 同一个 `Scaffold` 已经有 `_scaffoldKey`，`openEndDrawer()` 就在它上面 ——
  /// 复用即可。多一个 GlobalKey 只是多一个能忘记挂的地方。
  void _openUsageSidebar() => _scaffoldKey.currentState?.openEndDrawer();

  /// 当前会话的累计用量（没有则零元）。
  SessionUsage get _usage => _usageBySession[_activeSessionId ?? ''] ?? SessionUsage.empty;

  /// 当前实时订阅归属的运行。`null` = 没有正在收事件的运行。
  _RunOrigin? _liveOrigin;

  /// **在途运行**（正在跑的那次 `run()`）。`null` = 没有运行在途。
  ///
  /// ## 与 [_liveOrigin] 的关键区别（2026-10-11 修复 t11 的 B1）
  ///
  /// | | 含义 | 切会话时 |
  /// |---|---|---|
  /// | [_liveOrigin] | "这条**事件订阅**属于谁" | **清空**（旧会话的事件不该进新列表） |
  /// | `_inflightRun` | "有没有一次运行**还在跑**" | **保留**，直到 `run()` 真正返回 |
  ///
  /// 少了这个字段，切走就等于"忘记还有活没干完" ——
  /// 用户切回来时界面既没有进度、也不知道该不该等（B1-b）。
  _RunOrigin? _inflightRun;

  // ---- 拦截卡片的 per-run 去重（2026-10-10 修复 N-1 / N-2）----
  //
  // ## 为什么需要它（N-1）
  //
  // 拦截轮次有**两条**路径会画 `HBlocked`：
  //   ① 实时 `Blocked` 事件（`_onAgentEvent`）
  //   ② `run()` 返回后的兜底循环（`_runAgent`）
  //
  // 两条都可能画同一张，所以必须去重。但 t8 最初写的去重是
  // **遍历整个 `_messages`** 按 `index + tool` 找 —— 那是**跨运行**的：
  // `_messages.clear()` 只在切会话/新建/删会话时发生，同一会话内
  // 连续两次运行之间**不清空**；而 `AgentLoop` 每次运行的 `turnIndex`
  // 都**从 1 开始**。于是第二次运行的拦截卡会被误判成"已画过" →
  // **静默吞掉**（用户少看到一次拦截 —— 正是本轮要消灭的"看不到过程"）。
  //
  // ## 为什么用 key 集合而不是"记录本次起始 _messages.length"
  //
  // 长度基线那种做法很脆：一轮里 `_messages` 会被插入/删除多次
  // （占位行、原始输出、助手回答…），任何一次插入都会让基线漂移。
  // key 集合与既有的 [_liveToolIds] 同构，语义直接：**本次运行已画过的**。
  //
  // ## 顺带把 N-2 也关掉
  //
  // N-2：`Blocked` 事件在**兜底渲染之后**到达 → 又画一张（重复）。
  // 用同一个 key 集合即可收敛：**事件路径也登记 key**，
  // 兜底路径见到就跳过（反之亦然）。两个路径共享同一份"已画"事实，
  // 无论谁先谁后都只画一张。
  //
  // 每次运行开始（[_startLive]）清空；运行结束（[_stopLive]）一并清理。
  final Set<String> _drawnBlockedKeys = {};

  /// token 级事件 → 正在流式生成的那条步骤消息：`stepId` → 消息 id。
  ///
  /// ## 为什么按 stepId 而不是"最后一条消息"
  ///
  /// 多轮时会有多个步骤，且工具卡片会插在中间。把增量堆到"最后一条"
  /// 上必然错位（`AgentEvent.StepStarted.stepId` 的 KDoc 记的正是这条）。
  ///
  /// 每次运行开始（[_startLive]）清空；运行结束（[_stopLive]）一并清理。
  final Map<String, String> _streamStepIds = {};

  /// 当前仍在逐字生成的步骤（用于在控制台/测试里判断状态）。
  bool get hasActiveStreamStep =>
      _streamStepIds.values.any((id) => _stepIndexOf(id) >= 0);

  /// ★ 用户是否**手动上滑过** —— 上滑即暂停自动滚动（`docs/25` §5.3 第 3 条）。
  ///
  /// 用户往上拉，通常是想回看上面的内容 / 复制一段文本。
  /// 这时如果还硬把视口拽到底，他**根本读不了** —— 手指一松就被拖回去。
  ///
  /// 由 [_onScroll] 置位；由"回到底部"或下一次发送复位。
  bool _autoScrollPaused = false;

  /// 暂停自动滚动期间是否来了新内容 —— 决定要不要显示「有新内容」按钮。
  ///
  /// **只在暂停时才有意义**：没暂停时视口本来就在底部，
  /// 显示一个"有新内容"按钮只会让人以为漏看了什么。
  bool _hasNewContent = false;

  int _seq = 0;
  String _nextId() => 'm${_seq++}';

  @override
  void initState() {
    super.initState();
    // ★ 监听手动滚动 —— 用户上滑即暂停自动滚动（`docs/25` §5.3 第 3 条）
    _scroll.addListener(_onScroll);
    // ★ 通知点击定位会话（2026-10-19）：热启动走广播流，冷启动走 pending 兜底
    _openSessionSub = AgentBridge.openSessionRequests.listen(_onOpenSessionRequest);
    _restoreView();
    unawaited(_reload().then((_) => _consumePendingOpenSession()));
  }

  /// **完成通知点击 → 打开对应会话**（2026-10-19）。
  ///
  /// 找不到工作区（已被移除/换了路径）时**安静忽略** —— 通知是"顺手一看"，
  /// 不该弹错误打断用户。工作区还没加载完时先存起来，`_reload` 后补处理。
  Map<String, String>? _pendingOpenRequest;

  Future<void> _onOpenSessionRequest(Map<String, String> req) async {
    final sid = req['sessionId'] ?? '';
    // ignore: avoid_print
    print('HERC-OPEN dart request sid=$sid ws=${req['workspacePath']} '
        'workspaces=${_workspaces.length}');
    if (sid.isEmpty) return;
    if (_workspaces.isEmpty) {
      _pendingOpenRequest = req;
      return;
    }
    final wsPath = req['workspacePath'] ?? '';
    String? wsId;
    for (final w in _workspaces) {
      if (w.path == wsPath) {
        wsId = w.id;
        break;
      }
    }
    // 路径对不上（/sdcard vs /storage/emulated/0 这类别名）⇒ 按**会话 id** 反查。
    // 会话 id 全局唯一，比路径可靠。
    if (wsId == null) {
      for (final w in _workspaces) {
        if (w.sessions.any((s) => s.id == sid)) {
          wsId = w.id;
          break;
        }
      }
    }
    // 最后兜底：用当前工作区（用户至少能看到那个会话）
    wsId ??= _activeWorkspace?.id;
    if (wsId == null) return;
    await _selectSession(wsId, sid);
  }

  Future<void> _consumePendingOpenSession() async {
    final p = await _bridge.consumePendingOpenSession();
    if (p != null && mounted) {
      await _onOpenSessionRequest(p);
      return;
    }
    final queued = _pendingOpenRequest;
    if (queued != null && mounted) {
      _pendingOpenRequest = null;
      await _onOpenSessionRequest(queued);
    }
  }

  /// 恢复视图选项。
  ///
  /// 失败就用默认值 —— **不能因为一条脏设置让侧边栏打不开**。
  Future<void> _restoreView() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('view_options');
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic> && mounted) {
        setState(() => _view = ViewOptions.fromJson(m));
      }
    } catch (_) {
      // 忽略 —— 用默认值
    }
  }

  Future<void> _saveView(ViewOptions v) async {
    setState(() => _view = v);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('view_options', jsonEncode(v.toJson()));
    } catch (_) {
      // 存不下来不影响本次使用
    }
  }

  // ------------------------------------------------------------ 数据加载

  /// 重新读取工作区与会话。
  ///
  /// @param silent true = 不显示加载圈（用于抽屉打开时的静默刷新）。
  ///   不静默的话，每次滑出侧边栏都会闪一下转圈，很难看。
  Future<void> _reload({bool silent = false}) async {
    if (mounted && !silent) setState(() => _loading = true);
    try {
      final raw = await _bridge.listWorkspaces();
      if (!mounted) return;

      // 保留用户当前的展开状态 —— 否则每次刷新都会重置
      final prevExpanded = {for (final w in _workspaces) w.id: w.expanded};

      final list = <HWorkspace>[];
      for (final m in raw) {
        final path = (m['path'] as String?) ?? '';
        if (path.isEmpty) continue;
        final treeUri = (m['treeUri'] as String?) ?? '';
        // 读该工作区里的真实会话（必须带 treeUri，否则 SAF 下读不到）
        final sessions = await _bridge.listSessions(path, treeUri: treeUri);
        list.add(HWorkspace(
          id: path,
          name: (m['name'] as String?) ?? path.split('/').last,
          path: path,
          // 首次加载时默认展开第一个；之后保留用户的选择
          expanded: prevExpanded[path] ?? list.isEmpty,
          writable: (m['writable'] as bool?) ?? true,
          treeUri: treeUri,
          sessions: _markActive(sessions),
        ));
      }
      if (!mounted) return;
      setState(() {
        _workspaces = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取工作区失败：$e';
      });
    }
  }

  List<HSession> _markActive(List<HSession> sessions) =>
      sessions.map((s) => s.copyWith(active: s.id == _activeSessionId)).toList();

  HWorkspace? get _activeWorkspace {
    for (final w in _workspaces) {
      if (w.sessions.any((s) => s.active)) return w;
    }
    return _workspaces.isNotEmpty ? _workspaces.first : null;
  }

  HSession? get _activeSession {
    for (final w in _workspaces) {
      for (final s in w.sessions) {
        if (s.active) return s;
      }
    }
    return null;
  }

  String get _workspaceName => _activeWorkspace?.name ?? '未选择工作区';

  // ------------------------------------------------------------ 工作区操作

  /// **选一个已有文件夹**作为工作区（不是"新建目录"）
  Future<void> _pickWorkspace() async {
    Navigator.of(context).pop(); // 关抽屉
    try {
      final ws = await _bridge.pickWorkspace();
      if (!mounted) return;
      if (ws == null) {
        setState(() => _error = '未选择文件夹（或这个位置无法读写，请换一个）');
        return;
      }
      // ★ 换工作区 = 换上下文 —— 必须让在途运行的结果失效，
      //   否则上一个工作区某会话的结果会串进新工作区的列表。
      _switchContext();
      setState(() => _activeSessionId = null);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// **登记并使用内置「应用工作区」**（2026-10-17）—— 一个"能构建"的工作区。
  ///
  /// ## 为什么需要第二个入口（而不是让 [_pickWorkspace] 兜底）
  ///
  /// 编码层（构建 APK / 逆向）要求工作区**同时**能被 App 与 shell 写：
  /// 中间产物由 shell（Shizuku/Stellar）产出，插 dex / 进程内对齐 / 读产物由 App 自己写。
  /// 真机实测（`测试机`，2026-10-17）同时满足的只有
  /// `Android/data/<pkg>/files/**`，而 SAF 选择器**选不到**那里。
  /// 用户若选了 `/sdcard` 上的项目，构建会跑到一半才因写权限失败。
  ///
  /// 所以两个入口**互不兜底**：用户必须知道自己在选"我自己的项目"
  /// 还是"能构建的内置目录"。
  ///
  /// ## 为什么要顺手建一个会话
  ///
  /// 侧边栏的列表**只渲染有会话的工作区**（分组视图过滤掉 `sessions.isEmpty`，
  /// 单列表视图按会话铺行）。只登记、不建会话的话，用户点完按钮
  /// **界面上什么都不会发生** —— 既看不到新工作区，也没有能发消息的会话。
  /// 建一个会话顺带满足"点完出现在侧边栏且被选中"。
  Future<void> _addAppWorkspace() async {
    Navigator.of(context).pop(); // 关抽屉
    try {
      final ws = await _bridge.ensureAppWorkspace();
      if (!mounted) return;
      final path = (ws?['path'] as String?) ?? '';
      if (path.isEmpty) {
        // 建不出来就如实报 —— 不假装成功、不留一个点不动的空工作区
        setState(() => _error = '无法创建默认工作区');
        return;
      }
      final treeUri = (ws?['treeUri'] as String?) ?? '';

      // ★ 换工作区 = 换上下文 —— 必须让在途运行的结果失效，
      //   否则上一个工作区某会话的结果会串进新工作区的列表（同 [_pickWorkspace]）。
      _switchContext();

      final id = await _bridge.createSession(path, '新会话', treeUri: treeUri);
      if (!mounted) return;
      setState(() {
        _activeSessionId = id;
        _messages.clear();
        _metrics.clear();
        _error = null;
      });
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// 从列表移除一个工作区。
  ///
  /// ★ **这是第 5 条换上下文路径**（2026-10-10 修复 M-1）。
  ///
  /// 移除后 [_reload] 会让 [`_activeWorkspace`] **静默回退**到
  /// `_workspaces.first` —— 即"当前在看的工作区"变了。
  /// 若这里不自增代号，在途运行的守卫仍返回 true，
  /// 那个运行的结果就会渲染进**另一个工作区**的列表。
  ///
  /// 所以必须调 [_switchContext]（自增代号 + 停实时流）。
  ///
  /// ⚠️ 注意：即使移除的**不是**当前工作区，也照样自增 ——
  /// 判断"哪个是当前"依赖 `_workspaces` 的顺序，而 `_reload` 之后
  /// 那个顺序可能变。**无条件作废更安全**：代价只是丢弃一次
  /// 已经落盘的运行结果，切回去还能看到。
  Future<void> _removeWorkspace(String workspaceId) async {
    _switchContext();
    await _bridge.removeWorkspace(workspaceId);
    await _reload();
  }

  void _toggleWorkspace(String workspaceId) {
    setState(() {
      _workspaces = _workspaces
          .map((w) => w.id == workspaceId ? w.copyWith(expanded: !w.expanded) : w)
          .toList();
    });
  }

  // ------------------------------------------------------------ 会话操作

  Future<void> _newSession(String workspaceId) async {
    Navigator.of(context).pop();
    // 新建会话 = 换上下文：让在途运行失效，并停掉实时流
    _switchContext();
    final ws = _workspaces.firstWhere((w) => w.id == workspaceId,
        orElse: () => _workspaces.first);
    final id = await _bridge.createSession(workspaceId, '新会话', treeUri: ws.treeUri);
    if (!mounted) return;
    setState(() {
      _activeSessionId = id;
      _messages.clear();
      _metrics.clear();
      _error = null;
    });
    await _reload(silent: true);
  }

  /// ★★ 切换会话（2026-10-10 严重 bug 修复）
  ///
  /// ## 曾经的 bug
  ///
  /// 首版切换会话时直接 `_messages.clear()` —— 而消息**只存在内存里**，
  /// 所以切走再切回来，记录**永久消失**。
  ///
  /// 用户反馈原话：
  /// > "切换会话，会话之前的记录没了，这个很恐怖啊！！"
  ///
  /// ## 现在
  ///
  /// 消息在**发送的瞬间**就写进 `<工作区>/.heracles/sessions/<id>.jsonl`，
  /// 切换时从磁盘**读回来**。
  ///
  /// ## 与 ADR-015 的关系
  ///
  /// ADR-015 说"不同会话的缓存语义不兼容"—— 那讲的是**发送给模型的前缀**，
  /// 不是**用户可见的历史**。两者是不同层次的东西，之前我混淆了。
  Future<void> _selectSession(String workspaceId, String sessionId) async {
    Navigator.of(context).pop();

    // ★ 切会话 = 换上下文：让在途运行的结果失效（否则 A 的结果会串进 B），
    //   并停掉实时流（旧会话的事件不该再进来）
    _switchContext();

    setState(() {
      _activeSessionId = sessionId;
      _workspaces = _workspaces
          .map((w) => w.copyWith(
                sessions: w.sessions
                    .map((s) => s.copyWith(active: s.id == sessionId))
                    .toList(),
              ))
          .toList();
      // 先清空显示，随后用磁盘内容填满（避免看到上一个会话的残留）
      _messages.clear();
      _metrics.clear();
      _error = null;
      _loadingHistory = true;
    });

    try {
      final raw = await _bridge.loadMessages(
        workspaceId,
        sessionId,
        treeUri: _treeUriOf(workspaceId),
      );
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(_toMessages(raw));
        _loadingHistory = false;
      });

      // ★ 切回一个**仍在运行**的会话 → 重连事件订阅（2026-10-11，t11 的 #3）
      //
      // 不重连的话，用户只能干等 `run()` 返回（一轮 5–20 秒，多轮近 3 分钟）
      // 且界面看不出任何在跑的迹象 —— 那正是 B1-b「切回来像坏了」。
      //
      // 放在 `loadMessages` **之后**：先把磁盘上的历史铺好，
      // 再让实时事件往后追加，顺序才对（否则新事件会被随后的 clear 冲掉）。
      final r = _inflightRun;
      if (r != null && _isViewingRun(r)) {
        _reconnectLive(r);
        // 重连后可能在等第一个事件 —— 先给一句"正在运行"，
        // 别让用户在两次事件之间以为又停了
        setState(() {
          final id = _progressId ?? _nextId();
          _progressId = id;
          _upsertProgress(id, '正在运行…（等待模型输出）');
        });
      }

      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
        _error = '读取会话记录失败：$e';
      });
    }
  }

  /// 把磁盘上的消息行转成 UI 模型。
  ///
  /// 磁盘格式见 `docs/22-会话持久化.md`：
  /// ```json
  /// {"role":"user","text":"...","ts":123}
  /// {"role":"tool","tool":"write_file","args":{...},"result":"...","ok":true}
  /// {"role":"assistant","text":"...","cached":1024,"prompt":1200,"out":50,"ms":6530}
  /// ```
  List<HMessage> _toMessages(List<Map<String, dynamic>> raw) {
    final out = <HMessage>[];
    for (final m in raw) {
      final role = (m['role'] as String?) ?? '';
      final text = (m['text'] as String?) ?? '';
      final id = _nextId();

      switch (role) {
        case 'user':
          final attach = m['attach'] as String?;
          out.add(HUserMessage(
            id: id,
            text: attach == null || attach.isEmpty
                ? text
                : '$text\n\n📎 $attach',
          ));
        case 'tool':
          final argsRaw = m['args'];
          final args = <String, String>{};
          if (argsRaw is Map) {
            argsRaw.forEach((k, v) => args[k.toString()] = v.toString());
          }
          // ★★ 读回时还原三态（2026-10-10 修复 H-1）★★
          //
          // 新记录带 `state`（succeeded / failed / blocked）；
          // `blocked` 必须还原成 `HBlocked`，**绝不能**画成工具卡片 ——
          // 否则切会话/重启后又变回那张假的绿色成功卡。
          //
          // 老记录没有 `state`，只有 `ok`：**不追溯**，按 `ok` 落地。
          // 那几条历史记录仍会显示成功 —— 这是如实的结果，
          // 我们不用不可靠的规则去改写用户的历史（见 SessionStore 的说明）。
          final state = m['state'] as String?;
          if (state == 'blocked') {
            // 原因优先用落盘的 `reason`（用户要知道**为什么**被拦），
            // 老记录没有就退到 result，再不行给个通用文案
            final reason = (m['reason'] as String?)?.trim();
            final res = (m['result'] as String?)?.trim();
            out.add(HBlocked(
              id: id,
              reason: (reason != null && reason.isNotEmpty)
                  ? reason
                  : ((res != null && res.isNotEmpty)
                      ? res
                      // 老记录没存原因 —— 给一句**不与标题重复**的话，
                      // 否则标题与正文都写"已拦截，未执行"，看起来像 bug
                      : '本轮请求未被执行（原因未记录）'),
              tool: m['tool'] as String?,
              args: args.isEmpty ? null : args,
            ));
          } else {
            out.add(HToolCall(
              id: id,
              tool: (m['tool'] as String?) ?? '未知工具',
              args: args,
              result: m['result'] as String?,
              status: state != null
                  // 新记录：只认 state
                  ? (state == 'succeeded'
                      ? ToolStatus.success
                      : ToolStatus.failure)
                  // 老记录：按 ok 回落（不会误报成功以外的状态）
                  : ((m['ok'] as bool?) == true
                      ? ToolStatus.success
                      : ToolStatus.failure),
            ));
          }
        case 'assistant':
          out.add(HAssistantMessage(id: id, text: text));
          _metrics[id] = TurnMetrics(
            cachedTokens: (m['cached'] as num?)?.toInt(),
            promptTokens: (m['prompt'] as num?)?.toInt() ?? 0,
            outputTokens: (m['out'] as num?)?.toInt() ?? 0,
            wallMs: (m['ms'] as num?)?.toInt() ?? 0,
          );
        case 'system':
          // 读取出错时的提示 —— 必须显示，否则用户以为记录真的没了
          out.add(HAssistantMessage(id: id, text: text));

        // ---- ★★ 工作步骤（2026-10-12，S5 修复「切会话步骤消失」）★★ ----
        //
        // ## 用户报的 bug
        //
        // > "我从会话1切换会话2，前面几轮输出的工作步骤不见了……
        // >  但是它已经生成的步骤会消失"
        //
        // ## 根因
        //
        // `HStepStream`（逐字步骤）**过去根本不落盘** ——
        // 切会话 → `_messages.clear()` → 从磁盘重读 → 磁盘上没有步骤
        // ⇒ 消失。见 `models/message.dart` 顶部被推翻的旧设计说明。
        //
        // ## 现在
        //
        // Kotlin 侧在**每个步骤结束时**追加一行 `{"role":"step",...}`
        // （`SessionStore.appendStep`），这里把它**还原成同一张步骤卡片**
        // —— 用的就是实时路径那个 `HStepStream`，所以「实时看到的」与
        // 「切回来读到的」长得一样（同一套渲染代码，不会两处漂移）。
        //
        // ⚠️ 未知 role 必须**静默跳过**而不是崩 —— `.jsonl` 是长期存在的
        // 用户数据，将来加 role 时旧版本 App 仍要能读出其余消息
        // （本 switch 无 `default:`，正是这个语义：不认识就什么都不做）。
        case 'step':
          out.add(HStepStream(
            id: id,
            // 落盘时 stepId 可能缺失（兜底路径）—— 补一个稳定的占位 id
            stepId: (m['stepId'] as String?) ?? 'disk-$id',
            title: (m['title'] as String?) ?? '',
            index: (m['i'] as num?)?.toInt(),
            reasoning: (m['think'] as String?) ?? '',
            text: text,
            // ★ 读回来的都是**已结束**的步骤：不能再画成"正在生成"，
            //   否则用户切回来会看到一堆永远转圈的卡片。
            finished: true,
            status: (m['stage'] as String?) ?? StepStage.ok.wire,
            durationMs: (m['ms'] as num?)?.toInt(),
            // ★ 落盘时被上限截断过 —— 如实告知，不假装完整
            truncated: (m['truncated'] as bool?) == true,
          ));
      }
    }
    return out;
  }

  /// ★ 重命名 —— 之前是空实现
  Future<void> _renameSession(String workspaceId, String sessionId) async {
    final s = _findSession(workspaceId, sessionId);
    final controller = TextEditingController(text: s?.title ?? '');
    final h = Hue.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: h.surfaceAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HRadius.lg),
          side: BorderSide(color: h.border),
        ),
        title: Text('重命名会话', style: TextStyle(color: h.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: h.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: TextButton.styleFrom(foregroundColor: h.textDim),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: h.accent),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _bridge.renameSession(workspaceId, sessionId, name,
        treeUri: _treeUriOf(workspaceId));
    await _reload();
  }

  /// ★ 删除 —— 之前是空实现
  Future<void> _deleteSession(String workspaceId, String sessionId) async {
    final h = Hue.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: h.surfaceAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HRadius.lg),
          side: BorderSide(color: h.border),
        ),
        title: Text('删除会话', style: TextStyle(color: h.text)),
        content: Text(
          '这会删除该会话的记录。\n工作区里的文件不会被删除。',
          style: TextStyle(fontSize: 13, height: 1.5, color: h.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(foregroundColor: h.textDim),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: HColors.errorOn(h.dark)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await _bridge.deleteSession(workspaceId, sessionId,
        treeUri: _treeUriOf(workspaceId));
    if (sessionId == _activeSessionId) {
      // ★ 删掉的正是当前会话 = 换上下文：
      //   在途运行的结果绝不能插进"已经不存在的会话"的列表
      _switchContext();
      setState(() {
        _activeSessionId = null;
        _messages.clear();
        _metrics.clear();
      });
    }
    await _reload();
  }

  /// ★ 收藏 —— 之前是空实现
  Future<void> _toggleStar(String workspaceId, String sessionId) async {
    // 乐观更新：先改 UI 再落盘（失败会被 reload 纠正）
    setState(() {
      _workspaces = _workspaces.map((w) {
        if (w.id != workspaceId) return w;
        return w.copyWith(
          sessions: w.sessions
              .map((s) => s.id == sessionId ? s.copyWith(starred: !s.starred) : s)
              .toList(),
        );
      }).toList();
    });
    await _bridge.toggleStar(workspaceId, sessionId,
        treeUri: _treeUriOf(workspaceId));
    await _reload(silent: true);
  }

  /// ★ 归档（2026-10-10 新增，配合「筛选会话」）
  Future<void> _toggleArchive(String workspaceId, String sessionId) async {
    setState(() {
      _workspaces = _workspaces.map((w) {
        if (w.id != workspaceId) return w;
        return w.copyWith(
          sessions: w.sessions
              .map((s) =>
                  s.id == sessionId ? s.copyWith(archived: !s.archived) : s)
              .toList(),
        );
      }).toList();
    });
    await _bridge.toggleArchive(workspaceId, sessionId,
        treeUri: _treeUriOf(workspaceId));
    await _reload(silent: true);
  }

  /// 取某个工作区的 treeUri（SAF 下必须有）
  String _treeUriOf(String workspaceId) {
    for (final w in _workspaces) {
      if (w.id == workspaceId) return w.treeUri;
    }
    return '';
  }

  HSession? _findSession(String workspaceId, String sessionId) {
    for (final w in _workspaces) {
      if (w.id != workspaceId) continue;
      for (final s in w.sessions) {
        if (s.id == sessionId) return s;
      }
    }
    return null;
  }

  void _openSettings() {
    // 只有从抽屉里进来才需要先关抽屉；从提示条点进来时**不能** pop
    // （那会把聊天页自己弹掉 —— 2026-10-19 首启引导的坑）。
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(controller: widget.settings),
    ));
  }

  /// **模型是否真的能用**（2026-10-19 首启引导）。
  ///
  /// 判据集中在 [AppSettings.hasUsableProvider]（与 `AgentBridge` 发送前校验同源），
  /// 避免 UI 与发送路径各写一份、久了漂移。
  bool get _modelReady => widget.settings.value.hasUsableProvider;

  // ------------------------------------------------------------ 附件

  Future<void> _pickAttachment() async {
    final h = Hue.of(context);
    final source = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HRadius.lg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: h.accent),
              title: Text('照片', style: TextStyle(color: h.text)),
              subtitle: Text('截图、图片',
                  style: TextStyle(fontSize: 11.5, color: h.textFaint)),
              onTap: () => Navigator.of(ctx).pop('image'),
            ),
            ListTile(
              leading: Icon(Icons.folder_open_rounded, color: h.accent),
              title: Text('文件', style: TextStyle(color: h.text)),
              subtitle: Text('代码、文本、文档',
                  style: TextStyle(fontSize: 11.5, color: h.textFaint)),
              onTap: () => Navigator.of(ctx).pop('file'),
            ),
            const SizedBox(height: HSpace.sm),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    try {
      final picked = await _bridge.pickFiles(
        imagesOnly: source == 'image',
        multiple: true,
      );
      if (!mounted || picked.isEmpty) return;
      setState(() {
        for (final f in picked) {
          final path = (f['path'] as String?) ?? '';
          final name = (f['name'] as String?) ?? '';
          if (path.isEmpty) continue;
          if (_attachments.any((a) => a.path == path)) continue;
          _attachments.add(HAttachment(
            id: 'att-${DateTime.now().microsecondsSinceEpoch}-$name',
            name: name.isEmpty ? path.split('/').last : name,
            path: path,
            kind: HAttachment.kindOf(name),
            sizeBytes: (f['size'] as num?)?.toInt() ?? 0,
          ));
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '选择文件失败：$e');
    }
  }

  void _removeAttachment(String id) {
    setState(() => _attachments.removeWhere((a) => a.id == id));
  }

  // ------------------------------------------------------------ 运行

  /// 订阅 `heracles/events`，开始边跑边显示。
  ///
  /// ## 这条路径是「增强」，不是「唯一」
  ///
  /// [run] 仍然 `await` 到完整 `AgentRunResult` —— 事件流断了、
  /// 平台侧没起来、甚至整条 EventChannel 失效，最终结果**照样**会
  /// 由 [run] 的返回值补齐（见 [_runAgent] 的兜底段）。
  ///
  /// 这一点是刻意的：流式是体验改进，**不是数据通路**。
  /// 让显示依赖一条可能断掉的实时通道，会把"看不到过程"变成"看不到结果"。
  void _startLive(_RunOrigin origin) {
    // 先取消旧的：连发两条消息时不能有两条订阅同时改 _messages
    _eventSub?.cancel();
    _progressId = null;
    _liveToolIds.clear();
    _pendingRaw.clear();
    // ★ 新的运行 = 新的一次"已画过"事实（修复 N-1：跨运行去重会吞卡）
    _drawnBlockedKeys.clear();
    // ★ 新的运行 = 新的逐字状态（旧的缓冲绝不能并进这一轮的步骤）
    _clearStreamState();
    // ★ 归属先设好 —— 事件可能**立刻**到达，那时它必须已经被认可
    _liveOrigin = origin;
    // 在途运行登记：切会话时**不清**它（见 _inflightRun 的说明）
    _inflightRun = origin;

    _eventSub = _bridge.events.listen(
      _onAgentEvent,
      onError: (Object e) {
        // 事件流出错**不能**影响本轮运行 —— 只记一条诊断。
        // 不做 setState(_error = ...)：那会在界面上弹一个红条，
        // 让用户以为任务失败了，而其实它还在正常跑。
        // ignore: avoid_print
        print('HERC-EVENT 事件流异常（不影响结果）：$e');
      },
    );
  }

  // ------------------------------------------------------------ ★ 逐字渲染

  /// 启动 16ms 帧定时器（幂等）。
  ///
  /// ## 为什么是 `Timer.periodic` 而不是"每次收到 delta 就起一个 Timer"
  ///
  /// 前者是**固定帧率**：无论一来来了 1 个字还是 50 个字，
  /// 每秒最多重建 60 次。后者在满载时（250 tok/s）会退化成
  /// "每个 token 重建一次"—— 正是缓冲要防的那件事。
  void _ensureFlushTimer() {
    _flushTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _flushDeltas(),
    );
  }

  /// 把缓冲里的增量**一次性**并进 `_messages`，然后只 `setState` 一次。
  ///
  /// ## 两条轨（思考 / 正文）分别攒
  ///
  /// 缓冲 key 是 `stepId + 通道`，所以一次 flush 里两个通道的增量
  /// **各归各的**，绝不会因为"同一次 flush"而被粘到一起 ——
  /// 粘了用户就再也分不清哪句是思考、哪句是答案（`docs/25` §2 错误一）。
  void _flushDeltas() {
    if (_deltaBuffer.isEmpty) return;
    if (!mounted) {
      _deltaBuffer.clear();
      return;
    }

    // 先摘出来再改 UI：flush 期间可能又有新 delta 进来（Timer 回调是同步的，
    // 但 setState 之后的重建流程不是），摘出来保证"这一帧的内容"是确定的
    final pending = Map<String, String>.from(_deltaBuffer);
    _deltaBuffer.clear();

    setState(() {
      pending.forEach((key, chunk) {
        final sep = key.indexOf('|');
        if (sep < 0) return;
        final stepId = key.substring(0, sep);
        final track = key.substring(sep + 1);

        final msgId = _streamStepIds[stepId];
        if (msgId == null) return;
        final i = _stepIndexOf(msgId);
        if (i < 0) return;
        final cur = _messages[i] as HStepStream;

        _messages[i] = track == _trackReasoning
            ? cur.copyWith(reasoning: cur.reasoning + chunk)
            : cur.copyWith(text: cur.text + chunk);
      });
    });

    // 新内容到了 —— 仅在暂停自动滚动时提示（见 _onScroll 的说明）
    if (_autoScrollPaused) {
      _hasNewContent = true;
    } else {
      _scrollToBottom();
    }
  }

  /// 缓冲 key 的两条轨。
  ///
  /// ★ **必须是两个 key** —— 思考流与正文流是两个独立通道，
  /// 混进一个 buffer 之后 `delta` 会被按到达顺序拼成一串，
  /// 思考和正文就粘死了（`docs/25` §5.3：两条轨分开）。
  static const _trackReasoning = 'r';
  static const _trackText = 't';

  String _bufKey(String stepId, String track) => '$stepId|$track';

  /// 某条步骤消息在 `_messages` 里的下标；找不到返回 -1。
  int _stepIndexOf(String msgId) =>
      _messages.indexWhere((m) => m.id == msgId && m is HStepStream);

  /// 找到（或新建）某个 `stepId` 的逐字步骤消息。
  ///
  /// ## 为什么 `step_started` 缺失时也要能建
  ///
  /// `step_started` 是**增强**：万一它丢了（事件流在建立订阅前就开始吐字），
  /// 只要收到 `delta` 就补建一条 —— 否则用户看到的是"字全丢了"。
  /// 标题退化成「正在生成…」，不影响可读性。
  String _ensureStep(String stepId, {String? title, int? index}) {
    final existing = _streamStepIds[stepId];
    if (existing != null) {
      final i = _stepIndexOf(existing);
      if (i >= 0) {
        if (title != null && title.isNotEmpty) {
          _messages[i] = (_messages[i] as HStepStream).copyWith(title: title);
        }
        return existing;
      }
    }
    final id = _nextId();
    _streamStepIds[stepId] = id;
    _messages.add(HStepStream(
      id: id,
      stepId: stepId,
      title: title ?? (index != null ? '正在生成…（第 $index 轮）' : '正在生成…'),
    ));
    return id;
  }

  /// 把某条缓冲区内容并入步骤（**逐字路径**，不经 `_messages` 重建）。
  void _bufferDelta(AgentEvent e) {
    final stepId = e.stepId;
    final delta = e.delta;
    // stepId 缺失 / delta 缺失 = 版本不一致（老 Kotlin 不发这些字段）。
    // 静默忽略 —— 绝不伪造内容，也绝不崩。
    if (stepId == null || stepId.isEmpty) return;
    if (delta == null || delta.isEmpty) return;

    final track =
        e.type == AgentEvent.kReasoningDelta ? _trackReasoning : _trackText;
    final key = _bufKey(stepId, track);
    _deltaBuffer[key] = (_deltaBuffer[key] ?? '') + delta;
  }

  /// `step_ended` —— 收口：用**最终完整文本**替换逐字草稿，并格式化。
  void _finishStep(AgentEvent e) {
    final stepId = e.stepId;
    if (stepId == null || stepId.isEmpty) return;

    // ★★ 先把这条步骤的缓冲**刷掉**（顺序不能反）★★
    //
    // 若先 `finished = true` 再 flush，最后那截还在缓冲里的增量会被追加到
    // "已格式化"的文本后面 —— 用户看到结尾突然多出一段没格式化的字。
    _flushStepBuffers(stepId);

    final i = _stepIndexOf(_streamStepIds[stepId] ?? '');
    if (i < 0) return;
    final cur = _messages[i] as HStepStream;

    // 最终文本优先用 `summary`（Kotlin 侧给的完整生成结果）；
    // **但要防退步**：本地后端确实出现过 summary 比逐字累积更短的情况
    // （思考吃光预算被截断，见 `docs/25` §13.3）——此时保留累积文本，
    // 否则用户会看到内容"变少"。
    final summary = e.summary ?? '';
    final raw = summary.length >= cur.text.length ? summary : cur.text;
    // ★ 协议剥壳（2026-10-13，用户截图暴露）：
    //   步骤正文在流式期间裸渲染原始输出（要快，这是设计），
    //   但 StepEnded 后**必须**剥掉 `{"final":…}` / `{"tool":…}`
    //   的协议外壳 —— 那是给 AgentLoop 解析用的，不是给人看的。
    //   用户原话：「我想知道工作步骤里面，{}里面的输出是表示什么」
    //   答案：是模型输出协议；用户不该看到它。
    //   剥壳失败（非法 JSON）保持原文 —— 诚实优先，不伪造内容。
    final text = stripProtocolShell(raw);

    setState(() {
      _messages[i] = cur.copyWith(
        text: text,
        finished: true,
        status: e.status,
        durationMs: e.durationMs,
      );
    });
    _streamStepIds.remove(stepId);
  }

  /// 只针对某一个 stepId 的缓冲做 flush（`step_ended` 前用）。
  void _flushStepBuffers(String stepId) {
    if (_deltaBuffer.isEmpty) return;
    final pending = <String, String>{};
    for (final track in [_trackReasoning, _trackText]) {
      final key = _bufKey(stepId, track);
      final v = _deltaBuffer.remove(key);
      if (v != null && v.isNotEmpty) pending[key] = v;
    }
    if (pending.isEmpty) return;
    pending.forEach((key, chunk) {
      final sep = key.indexOf('|');
      if (sep < 0) return;
      final sid = key.substring(0, sep);
      final track = key.substring(sep + 1);
      final i = _stepIndexOf(_streamStepIds[sid] ?? '');
      if (i < 0) return;
      final cur = _messages[i] as HStepStream;
      _messages[i] = track == _trackReasoning
          ? cur.copyWith(reasoning: cur.reasoning + chunk)
          : cur.copyWith(text: cur.text + chunk);
    });
  }

  /// 清掉所有逐字状态（切会话 / 运行结束）。
  ///
  /// ## 为什么连 `_deltaBuffer` 一起清
  ///
  /// 缓冲里是**上一个上下文**的字。切会话后不清，下一次 flush 会把它
  /// 并进新会话的步骤里 —— 那正是"别的会话的内容串进来"这类最吓人的 bug。
  void _clearStreamState() {
    _deltaBuffer.clear();
    _streamStepIds.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  // ------------------------------------------------------------ 自动滚动

  /// 监听用户手动滚动 —— 上滑即**暂停**自动滚动（`docs/25` §5.3 第 3 条）。
  ///
  /// ## 判据：`pixels < maxScrollExtent - 阈值`
  ///
  /// 不用 `userScrollDirection`：那个字段在惯性与回弹期间会乱跳，
  /// 会把"贴底但正在回弹"误判成上滑，于是**一直暂停**，用户再也看不到新内容。
  /// 比位置更稳，且语义直白：**离底部够远 = 用户在看上面的东西**。
  ///
  /// 阈值 24px：小于一行的点击抖动，大于惯性回弹的过冲。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final away = pos.maxScrollExtent - pos.pixels;
    final paused = away > _autoScrollSlack;

    if (paused != _autoScrollPaused) {
      setState(() {
        _autoScrollPaused = paused;
        // 回到底部 = 用户重新跟上了，提示按钮该消失
        if (!paused) _hasNewContent = false;
      });
    }
  }

  /// "离底部多远算用户在看上面"的阈值（px）
  static const _autoScrollSlack = 24.0;

  /// 用户点了「有新内容」→ 回到底部并恢复自动滚动。
  void _resumeAutoScroll() {
    setState(() {
      _autoScrollPaused = false;
      _hasNewContent = false;
    });
    _scrollToBottom();
  }

  /// **重连**一个仍在运行的会话的事件订阅（2026-10-11，t11 的 #3）。
  /// ## 为什么需要它
  ///
  /// 切会话时 [_stopLive] 取消了订阅（正确 —— 旧会话的事件不该进新列表）。
  /// 但**后端仍在跑**。用户切回来时如果不重连，就只能干等
  /// `run()` 返回（本地模型一轮 5–20 秒，多轮近 3 分钟）——
  /// 那正是"看不到过程"的老问题，也正是本轮要消灭的东西。
  ///
  /// ## 单 sink 约束（为什么**不能**并行运行）
  ///
  /// `MainActivity.eventSink` 是**单个**字段，且 `toEventMap` 的事件里
  /// **只有 `index`、没有 session id** —— 若两个运行并行，
  /// 它们的事件会混进同一条流，UI **在原理上无法分辨**哪个属于哪个会话。
  ///
  /// 所以"一次只允许一个运行"是**结构性约束**，不是偷懒。
  /// 要做多会话并行，必须先给事件加 session id + sink 多路复用
  /// （设计层面改动，见 `docs/` 讨论），**不要**在 UI 层硬塞。
  ///
  /// 也正因如此，重连是安全的：任何时刻最多只有一次运行在途。
  void _reconnectLive(_RunOrigin origin) {
    // 已经有订阅（用户没切走过）→ 不必重连
    if (_eventSub != null) return;
    // 这次运行已经不在途了（跑完/失败）→ 不该重连
    if (_inflightRun?.runSeq != origin.runSeq) return;

    _liveOrigin = origin;
    _eventSub = _bridge.events.listen(
      _onAgentEvent,
      onError: (Object e) {
        // ignore: avoid_print
        print('HERC-EVENT 事件流异常（不影响结果）：$e');
      },
    );
  }

  /// 收事件 —— **每个事件都只做增量更新**，不重建整个列表。
  ///
  /// ## 会话守卫（2026-10-10）—— 这是**纵深防御**，不是主要机制
  ///
  /// 防止事件串会话的**主要机制**是 [_stopLive] 取消订阅：
  /// `EventChannel.receiveBroadcastStream()` 在最后一个监听者取消时
  /// 会 `setMessageHandler(name, null)`，此后平台侧发来的消息
  /// **在通道层就被丢弃**，根本不会调用到这里。
  ///
  /// ⚠️ 换句话说：**这个守卫目前无法被测试覆盖到**。
  /// 我用 mock 的 sink 在取消后推事件，实测证明 `_onAgentEvent`
  /// **不会被调用**（探针打印为空）；把守卫改成恒真，测试照样全绿。
  /// 所以请不要以为"有测试保护着这一行"。
  ///
  /// 那为什么还留着？它防的是**将来**可能出现的窗口：
  /// 订阅取消是异步的（`cancel()` 返回 Future），不同 Flutter 版本
  /// 对"取消期间已入队消息"的处理不保证一致；而这里只多一次
  /// 整数比较，代价可忽略。**宁可留一层不会错判的检查。**
  void _onAgentEvent(AgentEvent e) {
    if (!mounted) return;
    // 事件不属于当前上下文 → 丢弃（见 [_hasLiveOrigin] 的说明）
    if (!_hasLiveOrigin) return;

    // ---- ★★ token 级事件：**先拦一道**（2026-10-12）★★
    //
    // 后端（S2）已在发 `step_started` / `reasoning_delta` / `step_delta` /
    // `step_ended`。**未知类型必须降级忽略，不能崩** ——
    // 这是跨进程弱契约的必然情况（`AgentEvent` 的 KDoc 与 `docs/25` §13.5
    // 都点名要求 Dart 侧先加降级分支）。
    //
    // 下面 switch 的 `default:` 分支负责"不认识就忽略"，
    // 这里负责"认识的走逐字路径"。
    if (e.type == AgentEvent.kStepStarted ||
        e.type == AgentEvent.kReasoningDelta ||
        e.type == AgentEvent.kStepDelta ||
        e.type == AgentEvent.kStepEnded) {
      _onTokenEvent(e);
      return;
    }

    switch (e.type) {
      // ---- 一轮开始：显示「正在生成…」占位 ----
      //
      // 这是本次修复的**核心可见成果**：本地模型一轮 5–20 秒，
      // 这行字让用户知道 agent 在干活，而不是卡死了。
      case AgentEvent.kTurnStarted:
        setState(() {
          final id = _progressId ?? _nextId();
          _progressId = id;
          _upsertProgress(id, '正在生成…（第 ${e.index ?? '?'} 轮）');
        });

      // ---- 模型原始输出 ----
      //
      // 只有「完全展开」档位收集它。收起档位**根本不存** ——
      // 省内存，也避免切档位时突然冒出一堆旧原话。
      //
      // 这里**不直接**插一条 HRawOutput：先暂存到 _pendingRaw，
      // 因为马上就会知道这一轮**有没有工具调用** ——
      //   · 有 → 挂到那张工具卡片上（见 kToolStarted）
      //   · 没有 → 在轮末补一条独立的 HRawOutput（见 _flushPendingRaw）
      // 这样原始输出在界面上**只出现一次**，不重复。
      case AgentEvent.kModelOutput:
        if (_showRaw) {
          final raw = e.raw ?? '';
          if (raw.trim().isNotEmpty) {
            _pendingRaw[e.index ?? -1] = raw;
          }
        }
        // 拿到输出了 → 占位可以撤掉（马上会有工具卡片或最终回答接上）
        _removeProgress();

      // ---- 工具开始：立刻插一张 pending 卡片 ----
      case AgentEvent.kToolStarted:
        final tool = e.tool ?? '';
        if (tool.isEmpty) break;
        setState(() {
          final id = _nextId();
          _liveToolIds[_toolKey(e.index, tool, e.args)] = id;
          _messages.add(HToolCall(
            id: id,
            tool: tool,
            args: e.args ?? const {},
            status: ToolStatus.running,
            // 「完全展开」档位：把这一轮的模型原话挂到卡片上
            rawOutput: _pendingRaw.remove(e.index ?? -1),
          ));
        });
        _scrollToBottom();

      // ---- 工具结束：把那张卡片改成成功/失败 ----
      case AgentEvent.kToolFinished:
        final tool = e.tool ?? '';
        setState(() {
          final id = _liveToolIds[_toolKey(e.index, tool, e.args)];
          if (id != null) {
            final i = _messages.indexWhere((m) => m.id == id);
            if (i >= 0 && _messages[i] is HToolCall) {
              // ok 为 null 时按失败处理是**刻意的保守**：真的执行成功
              // Kotlin 侧一定会带 ok=true（见 AgentBridge.toEventMap）。
              _messages[i] = (_messages[i] as HToolCall).copyWith(
                result: e.result,
                status: e.ok == true ? ToolStatus.success : ToolStatus.failure,
              );
            }
          }
        });
        _scrollToBottom();

      // ---- 被拦截：**不是**工具失败，单独一类 ----
      case AgentEvent.kBlocked:
        setState(() {
          // ★ per-run 去重（修复 N-1 / N-2）
          //
          // 若兜底路径**先**画了同一张（窗口窄但要防），这里就不再画。
          // 两条路径共用 [_drawnBlockedKeys]，谁先谁后都只出一张。
          final key = _toolKey(e.index, e.tool ?? '', e.args);
          if (_drawnBlockedKeys.contains(key)) return;
          _drawnBlockedKeys.add(key);

          // 这一轮没有工具卡片可挂 —— 原话单独成条，且排在拦截卡片之前：
          // 先看到"模型说了什么"，再看到"为什么被拦"
          _appendPendingRaw(e.index ?? -1);
          _messages.add(HBlocked(
            id: _nextId(),
            reason: e.reason ?? '已拦截',
            // ★ tool 可能为 null（Unparseable 分支）
            tool: e.tool,
            args: e.args,
            index: e.index,
          ));
        });
        _scrollToBottom();

      // ★ 思考间隙引导（2026-10-13）——
      //   到达时机 = 上一轮已完整结束、插话刚被 append。
      //   渲染成**用户消息**（本来就是用户说的话）——
      //   模型在下一轮看到它，自行比对原任务并调整。
      case AgentEvent.kInterrupted:
        setState(() {
          _appendAllPendingRaw();
          final pid = _progressId;
          if (pid != null) {
            _messages.removeWhere((m) => m.id == pid);
            _progressId = null;
          }
          _messages.add(HUserMessage(id: _nextId(), text: e.message ?? ''));
        });
        _scrollToBottom();

      // ---- ★ 任务计划（2026-10-14，harness）----
      //
      // 用户原话：「先拿到问题先分析，做一个待办，按照待办完成任务」
      //          「顶部显示任务计划（1.查看结构 ✓ 2.写HTML ←进行中 3.验证）」
      //
      // 两个事件：产生（steps）与推进（doneCount / activeIndex）。
      // 推进由 Kotlin 侧依据**真实工具执行记录**推导 ——
      // UI 只管显示，不自己猜进度。
      case AgentEvent.kPlanCreated:
        setState(() {
          _planSteps = e.planSteps;
          _planDone = 0;
          _planActive = 0;
        });

      case AgentEvent.kPlanAdvanced:
        setState(() {
          _planDone = e.doneCount ?? _planDone;
          _planActive = e.activeIndex ?? _planActive;
        });

      // ★ 计划收尾（2026-10-15，修 BUG-1）——
      //
      // 用户实测：任务结束（模型给了最终回答），计划却永远停在
      // 「4/5 · 确认功能完整后给出最终说明  进行中」。
      //
      // 根因：计划推进只认"工具成功"，而**最后一步通常不需要工具**
      //（"汇报结果"这类）—— 模型直接输出 final 就结束了。
      //
      // 现在 Kotlin 侧在收尾时明确发本事件，UI 据此把剩余步骤置为终态：
      //   · reachedGoal = true  → 全部标完成（画绿勾）
      //   · reachedGoal = false → **中断**（不能画成成功）
      //   · null                → 老版本 Kotlin，保持原样（不猜）
      case AgentEvent.kPlanClosed:
        setState(() {
          if (e.reachedGoal == true) {
            _planDone = _planSteps?.length ?? _planDone;
            _planActive = -1;
            _planReachedGoal = true;
          } else if (e.reachedGoal == false) {
            // 中断：保留已完成的部分，标记"已中断"（不假装完成）
            _planActive = -1;
            _planReachedGoal = false;
            _planClosedReason = e.planClosedReason;
          }
        });

      // ---- ★ ask_user：模型向用户提问（2026-10-16）----
      //
      // 用户需求：「ask 功能」—— agent 卡住/信息不足时**问用户**
      // 而不是瞎猜、放弃或谎称完成（`实测-08` 的教训）。
      //
      // ## 到达时机
      //
      // `ask_user` 工具**已挂起等待** —— 此刻弹窗，用户提交的回答
      // 经 `replyAsk` 回到工具，模型下一轮拿到。
      //
      // ## 为什么用弹窗而不是插一条消息
      //
      // 提问是**模态**的：任务停在这里等回答（有超时兜底）。
      // 弹窗明确了"现在需要你回答"，比混进消息流更不易被忽略。
      case AgentEvent.kAskUser:
        unawaited(_showAskDialog(context, e.message ?? ''));

      // ---- ★ 危险工具审批（2026-10-19）----
      //
      // 到达时机：Kotlin 侧已经**挂起**在审批队列上（工具返回 NeedsApproval）。
      // 允许 ⇒ 重新执行该工具；拒绝/关弹窗 ⇒ 作为失败回填，模型不会以为做成了。
      // 不弹窗的后果：队列等 10 分钟后超时 —— 用户只看到任务卡死。
      case AgentEvent.kApprovalRequest:
        unawaited(_showApprovalDialog(
          context,
          tool: e.tool,
          args: e.args,
          reason: e.reason ?? e.message ?? '',
        ));

      // ---- 收尾：撤掉占位 ----
      //
      // Finished / Failed 都只负责"把转圈的占位撤掉" + 把还没归属的
      // 原始输出补出来（例如只有最终回答、没有任何工具调用的那一轮）。
      // 最终回答**不在这里插** —— 由 run() 的返回值统一插入，
      // 避免同一条回答出现两次。
      case AgentEvent.kFinished:
      case AgentEvent.kFailed:
        setState(() {
          _appendAllPendingRaw();
          final pid = _progressId;
          if (pid != null) {
            _messages.removeWhere((m) => m.id == pid);
            _progressId = null;
          }
          // ★ 折叠"与最终回答重复"的步骤正文（2026-10-13，用户反馈
          //   "final 的内容展示给用户看了，与真正发出来的又是一样的，
          //   观感不好"）—— 最终回答由 run() 返回值统一插一条，
          //   步骤卡里不再重复同一句话。折叠 ≠ 丢内容：展开仍可见。
          final ft = e.finalText;
          if (ft != null && ft.isNotEmpty) {
            for (var i = 0; i < _messages.length; i++) {
              final m = _messages[i];
              if (m is! HStepStream || !m.finished) continue;
              final stripped = stripProtocolShell(m.text).trim();
              if (stripped.isNotEmpty && stripped == ft.trim()) {
                _messages[i] = m.copyWith(bodyCollapsed: true);
              }
            }
          }
        });
        // 运行收尾 —— 逐字状态里可能还有没结束的步骤（事件流断了、
        // `step_ended` 丢了）。留一条永远转圈的步骤会让用户以为还活着。
        _settleOrphanSteps(e.type == AgentEvent.kFailed);

      default:
        // ★★ 未知类型（Kotlin 侧比 Dart 新）—— 忽略而不是崩 ★★
        //
        // 这正是 S2 交接里点名的"第一优先级"：后端已经在发新事件，
        // 若这里抛异常，用户一发消息 App **直接崩**。
        //
        // 唯一的行为是记一条诊断 —— 不 setState、不报错弹窗：
        // 用户不需要知道"有个他不认识的事件类型"，
        // 那既不影响结果、也不影响他能做的事。
        // ignore: avoid_print
        print('HERC-EVENT 未知事件类型「${e.type}」已忽略'
            '（Dart 侧比 Kotlin 侧旧，请更新前端；不影响运行结果）');
        break;
    }
  }

  /// token 级事件的落地（`step_started` / `*_delta` / `step_ended`）。
  ///
  /// ## 与轮级路径的关系
  ///
  /// 两者**并存**，粒度不同（`AgentEvent` 的 KDoc：不是新旧替代）：
  ///   · 轮级（`turn_started` / `model_output` …）承载**结果与统计**
  ///   · token 级承载**正在吐字的过程**
  ///
  /// ## 这里为什么大部分不 `setState`
  ///
  /// `*_delta` 只往缓冲里塞（见 [_deltaBuffer]）—— 真正重建由 16ms 帧
  /// 定时器统一做。`step_started` / `step_ended` 是**低频关键帧**
  /// （一轮各一次），必须立刻可见，所以直接 setState。
  void _onTokenEvent(AgentEvent e) {
    switch (e.type) {
      case AgentEvent.kStepStarted:
        final stepId = e.stepId;
        if (stepId == null || stepId.isEmpty) return;
        setState(() {
          _ensureStep(stepId, title: e.title, index: e.index);
          // 逐字开始了 —— 「正在生成…」占位让位给真正的步骤卡片
          final pid = _progressId;
          if (pid != null) {
            _messages.removeWhere((m) => m.id == pid);
            _progressId = null;
          }
        });
        _ensureFlushTimer();

      case AgentEvent.kReasoningDelta:
      case AgentEvent.kStepDelta:
        // ★ 补建：万一 `step_started` 丢了，字也不能丢
        if (e.stepId != null && e.stepId!.isNotEmpty) {
          final missing = _streamStepIds[e.stepId!] == null;
          if (missing) {
            setState(() => _ensureStep(e.stepId!, index: e.index));
          }
        }
        _bufferDelta(e);
        _ensureFlushTimer();

      case AgentEvent.kStepEnded:
        _finishStep(e);

      default:
        break;
    }
  }

  /// 运行收尾时把**没有 `step_ended`** 的逐字步骤收口。
  ///
  /// 不这么做的话，事件流中断（或 `step_ended` 丢失）会让界面永远停在
  /// "转圈 + 生成中" —— 用户看着一个早就结束的运行以为它还活着。
  /// `docs/25` §13.2 那条"必须成对出现"的约束在**线上**是可能被违反的
  /// （流断了就不成对），所以 UI 侧必须能自愈。
  void _settleOrphanSteps(bool failed) {
    if (_streamStepIds.isEmpty) {
      _clearStreamState();
      return;
    }
    _flushDeltas();
    final ids = _streamStepIds.values.toList();
    setState(() {
      for (final msgId in ids) {
        final i = _stepIndexOf(msgId);
        if (i < 0) continue;
        final cur = _messages[i] as HStepStream;
        _messages[i] = cur.copyWith(
          finished: true,
          status: failed ? AgentEvent.kStatusError : AgentEvent.kStatusOk,
        );
      }
    });
    _streamStepIds.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// 当前档位是否显示模型原始输出（「完全展开」）。
  ///
  /// 命名换成 [_showRaw] 而不是 `_fullSteps`：t3 时我用它表示
  /// 「详细及以上」，但那与 `StepDetail.fullResult` 语义重叠、容易混淆。
  /// 现在这个 getter **只**表示"要不要显示原话"，与档位表一一对应。
  bool get _showRaw => widget.settings.value.stepDetail.showRawOutput;

  /// 把某一轮的待显示原话**单独**插成一条消息（工具卡片接不上时用）。
  void _appendPendingRaw(int index) {
    final raw = _pendingRaw.remove(index);
    if (raw == null) return;
    _messages.add(HRawOutput(
      id: _nextId(),
      index: index < 0 ? 0 : index,
      raw: raw,
    ));
  }

  /// 把**所有**没归属的原话插出来（轮次结束时兜底）。
  void _appendAllPendingRaw() {
    if (_pendingRaw.isEmpty) return;
    final keys = _pendingRaw.keys.toList()..sort();
    for (final k in keys) {
      _appendPendingRaw(k);
    }
  }

  /// 同一张工具卡片的去重键。
  ///
  /// 事件的 `index` 与 `result.turns` 的轮次能对上（都来自 `AgentLoop`）。
  /// 不加 index 会误合并"不同轮、同名同参"的两次合法调用。
  String _toolKey(int? index, String tool, Map<String, String>? args) {
    final a = args == null
        ? ''
        : (args.entries.toList()..sort((x, y) => x.key.compareTo(y.key)))
            .map((e) => '${e.key}=${e.value}')
            .join(',');
    return '${index ?? -1}:$tool:$a';
  }

  /// 插入或更新「正在生成…」占位（同一轮只保留一行）。
  void _upsertProgress(String id, String label) {
    final i = _messages.indexWhere((m) => m.id == id);
    if (i >= 0) {
      _messages[i] = HProgress(id: id, label: label);
    } else {
      _messages.add(HProgress(id: id, label: label));
    }
  }

  /// 撤掉占位行（一轮结束 / 拿到输出后）。
  void _removeProgress() {
    final id = _progressId;
    if (id == null) return;
    _progressId = null;
    setState(() => _messages.removeWhere((m) => m.id == id));
  }

  /// 把一次运行的结果**并入**当前会话的累计用量（2026-10-11，t13）。
  ///
  /// ## 三条规则（全部来自 `docs/24` §4 的真实教训）
  ///
  /// 1. **`cachedTokens == null` 不参与累计** —— 由 [SessionUsage.ofTurn] 保证：
  ///    未上报的轮次只计入 `unreportedTurns` / `unreportedPromptTokens`，
  ///    **绝不**把 `null` 当 0 加进命中率的分子分母。
  /// 2. 分子分母**配对**（都只来自已上报轮次），否则命中率被稀释。
  /// 3. 每次运行算一次 `runs`（不是每轮）。
  ///
  /// 只并入 `result.turns`：那是**这次真正发出去的**每一轮，且每轮都带 `cache`。
  /// 把一次运行的用量记到**发起它的那个会话**头上（2026-10-11，t13）。
  ///
  /// ## 为什么按 `origin.sessionId` 而不是"当前会话"
  ///
  /// token 是**真花掉的**。用户切走再切回，A 的用量不该少算 ——
  /// 所以账记在**发起方**，而不是"当前正在看的会话"。
  /// （对比：**渲染**才只看当前会话 —— 那是 t7 的语义，两者不同。）
  ///
  /// `origin.sessionId == null`（首条消息自动建会话）时先记在 `''` 下，
  /// Kotlin 返回真实 id 后由 [_migrateUsageKey] 迁移过去。
  void _accrueRunUsage(_RunOrigin origin, AgentRunResult result) {
    final key = origin.sessionId ?? '';
    var acc = _usageBySession[key] ?? SessionUsage.empty;
    for (final t in result.turns) {
      acc = acc.add(SessionUsage.ofTurn(
        cachedTokens: t.cachedTokens,
        promptTokens: t.promptTokens,
        outputTokens: t.outputTokens,
        wallMs: t.wallMs,
        // 「步数」= 请求了工具的次数（含被拦截的 —— 那也是一步，
        // 用户看到的是"agent 尝试过"）
        requestedTool: t.tool != null,
      ));
    }
    // runs 是"运行次数"，逐轮累加里不含它，单独加
    final next = acc.add(const SessionUsage().copyRuns(1));

    // 自动建会话的就地迁移：这次运行刚拿到 sessionId
    final created = result.sessionId;
    if (origin.sessionId == null && created != null && created.isNotEmpty) {
      _usageBySession[created] =
          (_usageBySession[created] ?? SessionUsage.empty).add(next);
      _usageBySession.remove('');
    } else {
      _usageBySession[key] = next;
    }

    // 冻结区规模随运行更新（供上下文分项）—— 与 setState 一起做
    unawaited(_refreshContextUsage());
  }

  /// **自动获取模型能力**（2026-10-14，第三版核心修复）。
  ///
  /// ## 为什么必须自动
  ///
  /// 第二版把能力获取绑在设置页的「获取可用模型」按钮上 —— 后果：
  /// · 用户不点 → 永远显示兜底值（`⚠️ 未从服务端获取`）
  /// · 用户点了但 App 重启 → 内存缓存丢失 → 又回到兜底
  ///
  /// 用户实测截图正是这个。**这是设计缺陷，不是用户操作问题**：
  /// harness 必须自己知道模型能力（上下文管理职责），
  /// 而不是等用户去点某个按钮。
  ///
  /// ## 行为
  ///
  /// 后台拉一次 → 成功则**写回 provider 配置**（持久化）→
  /// 下次打开面板或发消息时就是准确值。
  ///
  /// 失败静默（拿不到只影响显示精度，不影响功能）。
  Future<void> _autoFetchCapabilities(
    ModelProviderConfig p,
    String modelName,
  ) async {
    _autoFetchingCaps = true;
    try {
      final caps = await _bridge.fetchCapabilitiesOnly(
        baseUrl: p.baseUrl,
        apiKey: p.apiKey,
      );
      if (caps == null || caps.isEmpty) return;
      // 写回 provider 配置（持久化）
      final merged = <String, ModelCapability>{
        ...p.modelCapabilities,
        for (final e in caps.entries)
          if (e.value.contextWindow != null && e.value.contextWindow! > 0)
            e.key: ModelCapability(
              contextWindow: e.value.contextWindow!,
              maxOutputTokens: e.value.maxOutputTokens,
              supportsTools: e.value.supportsTools,
              supportsReasoning: e.value.supportsReasoning,
            ),
      };
      await widget.settings.updateProvider(
        p.copyWith(modelCapabilities: merged),
      );
      // 拉到后刷新面板
      if (mounted) unawaited(_refreshContextUsage());
    } catch (_) {
      // 静默 —— 拿不到能力不影响任何功能
    } finally {
      _autoFetchingCaps = false;
    }
  }

  /// 刷新上下文上限与冻结区（调用 Kotlin 侧的只读接口）。
  ///
  /// 失败/桥接未就绪时保持 `-1` ⇒ UI 显示"未知"，
  /// **不猜**、也不显示 `~0`（那会让人以为上下文是空的）。
  Future<void> _refreshContextUsage() async {
    // ★ 上下文上限**从服务端获取**（2026-10-14，第三版）
    //
    // ## 前两版都错，用户的批评逐步逼近真相
    //
    // | 版本 | 做法 | 用户批评 |
    // |---|---|---|
    // | 1 | 让用户手填 | 「1M 就是 1M，不用自己选的」 |
    // | 2 | 我凭印象编内置表 | 「deepseek-flash 是 1M，kimi-k3 也是 1M，结果呢？」|
    //
    // 第二版实测**错了 2/25**。结论：内置表这条路**方法上就不成立** ——
    // 中转站的模型名是它自己起的别名，任何快照表都会错。
    //
    // **能问就不要猜**（服务端有权威值，实测基元律动 /api/models
    // 返回 29 个模型的 contextWindow）。
    final p = widget.settings.value.effectiveProvider;
    // ★ 2026-10-18（ADR-035 S4）：本地后端已删除 ⇒ **恒为云端**。
    //   原先这里算 `isLocal = AppSettings.isLocalConfig(p)`，再据此决定
    //   要不要走服务端能力、以及上限兜底取 4096 还是 128K。
    //   现在只剩云端一条路（自建/局域网端点也走 `backend='cloud'`）。
    const isCloud = true;
    final modelName = p?.model ?? '';

    // ★ ① 服务端上报的**该模型**能力 —— 三层来源：
    //   (a) provider 配置里持久化的能力（用户点过"获取可用模型"）
    //   (b) 内存缓存（本次会话内刚拉过）
    //   (c) **自动拉取**（都没有时，后台拉一次并持久化）
    var fromServer = p?.modelCapabilities[modelName]?.contextWindow;
    if ((fromServer == null || fromServer <= 0) && isCloud && p != null) {
      fromServer = _bridge.capabilitiesOf(modelName)?.contextWindow;
      if (fromServer == null && !_autoFetchingCaps) {
        // 自动拉取（不阻塞 UI：本次先用兜底，拉到后下次就准了）
        unawaited(_autoFetchCapabilities(p, modelName));
      }
    }
    // ③ 诚实兜底（今天恒为云端默认值 —— 本地 4096 那条已随 ADR-035 删除）
    final fallback = await _bridge.contextLimitTokens(isCloud: isCloud);

    final limit = ModelContextTable.resolve(
      fromServer: fromServer,
      modelName: modelName,
      fallback: fallback,
    );

    final frozen = await _bridge.lastFrozenTokens();
    if (!mounted) return;
    setState(() {
      _contextLimit = limit;
      // ★ 来源必须如实标注 —— 让用户知道这个数字是**实测值**还是**兜底猜测**
      //   （第二版就是因为我没标来源，用户无法判断我猜错了）
      //
      // ★ 2026-10-18（ADR-035 S4）：原先还有第三条 `isLocal ? '本地实测
      //   （llama.cpp -c 参数）'` —— 本地后端已删，那条来源不存在了。
      _contextLimitSource = fromServer != null
          ? '服务端上报'
          : '⚠️ 未从服务端获取，按保守值估算';
      _frozenTokens = frozen;
    });
  }

  /// 当前上下文占用 —— 供边栏与指示器使用。
  ContextUsage get _contextUsage => ContextUsage(
        // 还没跑过（-1）时算 0：界面上"冻结区"就是"还没建立"，
        // 与"上限未知"是两回事
        frozenTokens: _frozenTokens > 0 ? _frozenTokens : 0,
        conversationTokens: _estimateConversationTokens(),
        limit: _contextLimit,
        limitSource: _contextLimitSource,
      );

  /// 估算**对话消息**的 token（与 `TextMath` 同系数，见 `session_usage.dart`）。
  ///
  /// 刻意不把工具卡片的长结果全算进去：那是**历史**，
  /// 而真正进上下文的是 `Session` 里的 role 文本。
  /// 这里按屏幕上可见的消息文本估，量级正确即可（一期标 `~`）。
  int _estimateConversationTokens() {
    var total = 0;
    for (final m in _messages) {
      switch (m) {
        case HUserMessage(:final text):
          total += estimateTokens(text);
        case HAssistantMessage(:final text):
          total += estimateTokens(text);
        case HToolCall(:final tool, :final result):
          total += estimateTokens(tool);
          if (result != null) total += estimateTokens(result);
        case HBlocked(:final reason):
          total += estimateTokens(reason);
        case HRawOutput(:final raw):
          total += estimateTokens(raw);
        case HStepStream(:final reasoning, :final text):
          // 逐字步骤的**过程文本**也要算 —— 它同样是模型吐出来的字，
          // 只是思考与正文分了两条轨（两段都要计，不能只算正文）
          total += estimateTokens(reasoning) + estimateTokens(text);
        case HProgress():
          // 占位行不是真实上下文内容
          break;
      }
    }
    return total;
  }

  ///
  /// [_selectSession] 会 `_messages.clear()` 然后从磁盘重新填。
  /// 如果这时还有一条订阅活着，**旧会话的事件会插进新会话的列表** ——
  /// 用户会看到"切过去之后冒出别人的工具卡片"。
  /// 那正是"会话记录错乱"这一类最吓人的 bug。
  void _stopLive() {
    _eventSub?.cancel();
    _eventSub = null;
    _progressId = null;
    _liveToolIds.clear();
    _pendingRaw.clear();
    _drawnBlockedKeys.clear();
    // ★ 逐字状态一并清（含 16ms 定时器）—— 见 [_clearStreamState]
    _clearStreamState();
    // 停止收事件 = 这次运行的实时归属作废
    _liveOrigin = null;
  }

  /// 换会话上下文 —— **所有会改变"当前在看哪个会话"的路径都必须调它**。
  ///
  /// ## 它使什么失效（2026-10-11 更新语义）
  ///
  /// | | 切上下文时 | 理由 |
  /// |---|---|---|
  /// | 事件订阅（[_liveOrigin]） | **取消** | 旧会话的事件不该进新列表 |
  /// | `_ctxGen` | **自增** | 记录"用户动过视图"（自动建会话时要用） |
  /// | **在途运行**（[_inflightRun]） | **保留！** | 活还在干，切回来要能看到（t11 的 B1） |
  ///
  /// ⚠️ 早期版本的自增语义是"让**所有在途运行**立即失效" —— 那正是
  /// 「切会话后原会话不工作」的根因：用户切回来时结果被永久丢弃。
  /// 现在只有**订阅**失效；**运行本身**是否该渲染由 [_isViewingRun] 判。
  ///
  /// ## 为什么必须有这个单一入口
  ///
  /// 之前 `_stopLive()` 散在 `_selectSession` / `_newSession` 里，
  /// 而**换工作区**和**删当前会话**这两条路径漏了 —— 那正是
  /// "结果串会话"能发生的缝隙。集中成一个方法，新增路径时只需调它。
  void _switchContext() {
    _ctxGen++;
    _stopLive();
    // ★★ 清空任务计划（2026-10-15 真机实测修复，BUG-2）★★
    //
    // ## 修的是什么
    //
    // 用户实测（2026-10-14 21:17 截图）：点「新会话」后，
    // 新会话页面**仍显示上一个会话的任务计划**
    //（「在工作区根目录创建 hello.txt」1/2）—— 用户会以为
    // "新会话里已经有个任务在跑了"。
    //
    // ## 根因
    //
    // `_planSteps` / `_planDone` / `_planActive` 是**屏幕级字段**，
    // 切会话/换工作区时没有清空。而计划是**某个会话的**进度，
    // 不是屏幕的属性。
    //
    // ## 为什么放在这里
    //
    // `_switchContext()` 是"换上下文"的统一入口（换工作区、换会话
    // 都走它），放这里能**一处覆盖所有路径**，不依赖每个调用点记得清。
    //
    // ## 遗留说明
    //
    // 现在的行为是"切走就丢"——**切回来不会恢复**。
    // 更完整的做法是把计划持久化进会话（切回来还能看到），
    // 但那需要动会话文件格式，本轮先修"串味"这个明确的错误。
    //
    // ⚠️ 自己调 setState（不依赖调用方包）——
    //    8 个调用点里有的是在 async 回调里，未必都包了 setState。
    //    包一层判断：已 dispose 时 setState 会抛。
    if (!mounted) return;
    setState(() {
      _planSteps = null;
      _planDone = 0;
      _planActive = 0;
      _planReachedGoal = null;
      _planClosedReason = null;
    });
  }

  /// 这次运行的结果**该不该**渲染到当前界面？
  ///
  /// ## 判据（2026-10-11 修复 t11 的 B1-a）
  ///
  /// **用户现在看的是不是这次运行所属的那个会话。**
  ///
  /// ## 为什么不再是"上下文代号有没有变"
  ///
  /// t7 用的是 `origin.ctxGen == _ctxGen`。那能挡住"A 的结果串进 B"，
  /// 但**顺带把 A→B→A 也判成了"切走"** —— 而用户切回来时看的**就是 A**，
  /// 结果却被永久丢弃：
  ///
  /// ```
  /// A 发消息 → 切到 B → 切回 A → run() 返回
  ///   ctxGen 已 +2 → 守卫判否 → 结果丢弃
  ///   而磁盘上还没有那一轮（persistTurns 要等 run() 返回才写）
  ///   → 用户看着 A，A 的结果永远不出现 = 「原会话不工作了」
  /// ```
  ///
  /// 新判据看的是**当前视图**，与"中间路过哪里"无关：
  /// 只要用户最终停在 A，A 的结果就该出现。
  ///
  /// ## 两种会话身份要分开判（首条消息时 sessionId 还是 null）
  ///
  /// - **已知会话**（`origin.sessionId != null`）：只要 `_activeSessionId`
  ///   等于它就算在看 —— 这正是 A→B→A 能恢复的原因。
  /// - **自动建会话**（`origin.sessionId == null`）：那次运行**正在创建**新会话，
  ///   Dart 侧此刻还不知道它的 id。而它在 `run()` 返回前**不会出现在侧边栏**，
  ///   用户**无法选中它**，所以"切走再切回"对它不成立。
  ///   此时仍用代号判"用户有没有动过"——保守且正确。
  bool _isViewingRun(_RunOrigin origin) {
    if (origin.sessionId == null) {
      // 自动建会话：视图必须仍停在"未选会话"，且中途没换过上下文
      return _activeSessionId == null && origin.ctxGen == _ctxGen;
    }
    return _activeSessionId == origin.sessionId;
  }

  /// **有没有一次运行还在跑**（与"正在看哪个会话"无关）。
  bool get _runInFlight => _inflightRun != null;

  /// 在途运行**是不是当前正在看的这个会话的**。
  bool get _currentRunIsVisible {
    final r = _inflightRun;
    if (r == null) return false;
    if (r.sessionId == null) return _activeSessionId == null;
    return r.sessionId == _activeSessionId;
  }

  /// **当前会话自己**有没有在跑的运行（按钮该显示"停止"还是"等待"）。
  ///
  /// 与 [_runInFlight] 的区别：那个是"全局有没有运行"。
  /// 在会话 B 看到"停止"按钮会让人以为能停 B 的东西 —— 那是误导。
  bool get _currentSessionRunning => _currentRunIsVisible;

  /// 输入框是否应当**禁用**。
  ///
  /// ## 为什么不是简单的 `_busy`
  ///
  /// `_busy` 是**屏幕级**字段 —— 用它禁用输入框，会导致
  /// "在 A 发消息 → 切到 B → B 的输入框也被禁用"（用户报的"不工作"真身）。
  ///
  /// ## ★ 方案选择：为什么是 B（解释清楚）而不是 A（放开输入）
  ///
  /// t14 任务给了两个方案，**选 B**，理由如下：
  ///
  /// **方案 A（让"当前会话无运行"时输入框可用）不可行** —— 它会
  /// 让**两个运行并行**，而这是**结构性禁止**的：
  ///
  /// ```
  /// MainActivity.eventSink      是【单个】字段
  /// AgentBridge.toEventMap()    事件里【只有 index，没有 session id】
  /// ```
  ///
  /// ⇒ 两个运行的事件会**混进同一条流**，UI **在原理上无法分辨**
  /// 哪个事件属于哪个会话。（同见 [_reconnectLive] 的注释。）
  ///
  /// 所以 A 不是"实现难"，而是**当前传输层不支持**。硬做会引入
  /// "B 的界面显示 A 的过程"这类**比原 bug 更糟**的错误。
  ///
  /// **方案 B（保留禁用 + 说明原因 + 修正按钮语义）**是诚实的：
  /// - 禁用**仍然禁用**（不制造并行）
  /// - 但**必须显示说明横幅** —— 不能是"灰掉的输入框 + 没有解释"
  /// - 按钮语义分开：只有**当前会话**在跑才是"停止"，
  ///   别的会话在跑显示**沙漏**（在 B 看到"停止"会以为能停 B 的东西）
  ///
  /// ## 后果与代价（如实说明）
  ///
  /// 用户在 A 跑着时切到 B，**仍然不能在 B 发消息**（要等 A 完成）。
  /// 但至少**知道为什么**（横幅指名道姓说是哪个会话在跑），
  /// 而不是面对一个无法解释的灰输入框。
  ///
  /// **真正的解法**（本轮不做，属设计层改动）：
  /// 事件加 `sessionId` + `eventSink` 多路复用 → 之后才能真正放开并行。
  bool get _inputBlocked => _runInFlight;

  /// 当前收到的事件**该不该**采纳。
  ///
  /// ## 判据（2026-10-11 随 t11 更新）
  ///
  /// = "有订阅在收 **且** 用户正看着那次运行所属的会话"。
  ///
  /// ## 为什么 `null` 要当作**不匹配**
  ///
  /// `_liveOrigin == null` 表示"**当前没有在收事件的运行**"
  /// （已跑完、已切走、已离开页面）。
  /// 此时若还收到事件，必然是**平台侧的迟到事件**
  /// （`cancel()` 是异步的，取消前 post 的事件仍会到达）。
  /// 那种事件属于**上一次上下文**，必须丢弃。
  ///
  /// ## 为什么不再比 `ctxGen`（重要）
  ///
  /// [#3 重连] 之后，用户在 A→B→A 途中 `_ctxGen` 已经 +2，
  /// 但**看的就是 A** —— 若还比 `ctxGen`，重连后收到的每一个事件
  /// 都会被误丢，实时进度又没了（B1-b 原地复活）。
  ///
  /// 所以这里复用 [_isViewingRun]：判"**在不在看它**"，
  /// 而不是"中间路过哪里"。这与 [_runAgent] 里判结果是否渲染**同一套语义**
  /// —— 两处必须一致，否则会出现"结果渲染了但事件全丢"这种
  /// 更难查的半吊子状态。
  bool get _hasLiveOrigin {
    final o = _liveOrigin;
    return o != null && _isViewingRun(o);
  }

  /// ★ **发送入口**（2026-10-13）—— 按 `BusySendBehavior` 分派。
  ///
  /// | 情形 | 行为 |
  /// |---|---|
  /// | 没在跑 | 直接 `_runAgent` |
  /// | 在跑 + `queue`（默认） | 存进队列 + 提示「已排队」；跑完自动发 |
  /// | 在跑 + `interrupt` | 先 `_stopRun()`，再把这条发出去 |
  ///
  /// ## 为什么排队是"替换"而不是"追加多条"
  ///
  /// 队列超过一条就意味着用户其实想要"依次执行一堆"——
  /// 那是另一个功能（任务列表），不是这里该假装支持的。
  /// 只留一条 + 明确提示，语义干净且不会静默丢消息。
  /// **一键重试上一次请求**（2026-10-19）。
  ///
  /// ## 为什么要它
  ///
  /// 失败后用户此前**没有任何重试入口**：错误条不可关、不可展开，切走只剩 6 秒
  /// SnackBar。用户唯一能做的就是把话再打一遍 —— 在手机上这是真实成本。
  ///
  /// 取**最后一条用户消息**重新走 [send]（排队/中断语义与手动输入完全一致），
  /// 并清掉错误条；失败消息本身留在列表里（历史应当可追溯，不假装修复过）。
  void _retryLastRun() {
    String? last;
    for (final m in _messages) {
      if (m is HUserMessage && m.text.trim().isNotEmpty) last = m.text;
    }
    if (last == null) return;
    setState(() => _error = null);
    _onSend(last);
  }

  void _onSend(String request) {
    if (!_busy) {
      unawaited(_runAgent(request));
      return;
    }
    final behavior = widget.settings.value.busySend;
    if (behavior == BusySendBehavior.interrupt) {
      // 中断并发送：先停，再发（stop 是异步的，等它完成）
      unawaited(() async {
        await _stopRun();
        if (!mounted) return;
        await _runAgent(request);
      }());
      return;
    }
    // 排队：**追加**到队尾（2026-10-13 按参考图改为多条）。
    //
    // ★ 不再往消息列表里塞「已排队」的助手消息 ——
    //   用户原话：「排队的消息要在输入框上面显示……
    //   不是在工作步骤里显示已排队」。
    //   现在以**输入框上方的排队条**呈现（见 `InputBar.queue`）。
    setState(() {
      _queue.add(_QueuedMsg(
        text: request,
        attachments: List<HAttachment>.of(_attachments),
      ));
      _attachments.clear();
    });
  }

  /// 当前运行结束后，把队首发出去（在 `_runAgent` 的 finally 里调）。
  ///
  /// **每次只发一条** —— 队列的意义是"排队"，不是"批量并行"。
  /// 发出去的那条跑完后会再次出队，于是自然形成串行。
  void _drainQueue() {
    if (_queue.isEmpty) return;
    final head = _queue.removeAt(0);
    // 把附件放回输入区，让 `_runAgent` 走正常路径抓到它们
    setState(() => _attachments.addAll(head.attachments));
    unawaited(_runAgent(head.text));
  }

  /// 立即发送某条排队消息（参考图里的 ↑ 按钮）。
  ///
  /// ## ★ 语义修正（2026-10-13，用户逐字反馈）
  ///
  /// 「不是停旧开新……是要引导」——
  /// **不打断**当前运行：插话通过 `interruptRun` 通道进入 AgentLoop 的
  /// 插话队列，在**当前这轮的思考过程结束后**（下一轮开始前）被
  /// append 进会话。模型在下一轮自行比对原任务与插话
  /// （是修改、追加还是删除），重新调整接下来的任务。
  ///
  /// ## 两个分支
  ///
  /// | 状态 | 行为 |
  /// |---|---|
  /// | 正在跑 | `interruptRun` → 队列移除这条 → UI 等下一轮的 `interrupted` 事件渲染它 |
  /// | 没在跑 | 从队列取出，走**正常发送**（"插话"与"发送"本就是一件事） |
  ///
  /// 失败兜底：`interruptRun` 返回 false（竞态：刚好跑完）→
  /// 消息退回队首，等 `_drainQueue` 正常发出 —— **绝不静默丢失**。
  void _sendQueuedNow(int index) {
    if (index < 0 || index >= _queue.length) return;
    final item = _queue.removeAt(index);
    unawaited(() async {
      if (_busy) {
        final accepted = await _bridge.interruptRun(item.text);
        if (!mounted) return;
        if (accepted) return; // 插话已入队，等 interrupted 事件渲染
        // 竞态：刚好跑完 —— 退回队首走正常出队，不丢消息
        setState(() => _queue.insert(0, item));
        return;
      }
      // 没在跑：正常发送（把附件放回，走 _runAgent 全路径）
      setState(() => _attachments.addAll(item.attachments));
      await _runAgent(item.text);
    }());
  }

  /// 删除一条排队消息（参考图的 🗑）。
  void _removeQueued(int index) {
    if (index < 0 || index >= _queue.length) return;
    setState(() => _queue.removeAt(index));
  }

  /// 把一条排队消息**置顶**（参考图的 ⧉ = 插话优先）。
  ///
  /// 语义：它会在**当前运行结束后第一个**发出（不是立刻中断当前运行 ——
  /// 那是 ↑ 按钮的语义，两者必须分清）。
  void _pinQueued(int index) {
    if (index <= 0 || index >= _queue.length) return;
    setState(() {
      final item = _queue.removeAt(index);
      _queue.insert(0, item);
    });
  }

  /// ★ **用户点了停止**（2026-10-13）。
  ///
  /// ## 用户报的现象
  ///
  /// 「暂停不了？」—— 停止按钮画得出来（`_SendButton` 的 busy 分支），
  /// 但点下去只会**又发一条消息**。两层原因：
  ///   ① `InputBar` 的 `onTap` 恒为 `_send`
  ///   ② Kotlin 侧根本没有取消接口（整个仓库搜不到）
  /// 两处都已补：`InputBar.onStop` + `AgentBridge.cancelRun` +
  /// `MainActivity.handleCancelRun`（`job.cancel()` 会打断阻塞中的
  /// `HttpJson.postSse` 的 `read()`）。
  ///
  /// ## 为什么这里还要做界面收尾
  ///
  /// Kotlin 侧取消后，`run()` 会回一个 `cancelled: true` 的结果
  /// （见 `MainActivity` 的 `CancellationException` 分支）。
  /// 那次 `_runAgent` 的 `await` 会照常返回，**它自己的 finally
  /// 会把 `_busy` 复位** —— 所以这里不需要手动复位。
  ///
  /// [silent] = 不要写「已停止」的助手消息。
  ///
  /// **为什么需要**：「立即发送排队消息」的路径（`_sendQueuedNow`）
  /// 内部也走 `_stopRun` —— 但那里停止只是**发新消息的前奏**，
  /// 紧接着就是新一轮运行。若还写「已停止。你可以继续发消息。」，
  /// 用户看到的是：回答被停 → 冒出一句"已停止" → 又开始生成 ——
  /// 三段混乱（用户原话：「结果上面的消息直接停止，
  /// 然后又是显示正在生成」）。打断式的停止不需要告别语。
  Future<void> _stopRun({bool silent = false}) async {
    final ok = await _bridge.cancelRun();
    if (!mounted) return;
    if (!ok) {
      // 没停到（刚好跑完 / 连点两下）—— 幂等，不报错也不写消息
      return;
    }
    setState(() {
      // ★ 2026-10-13 修：**必须立刻复位 `_busy`**
      //
      // 用户报：「暂停了还在显示正在生成，输入框的发送按钮也还是暂停按钮」。
      //
      // 根因：`_stopRun` 原来只调 `_stopLive()`（停事件订阅），
      // 而 `_busy` 要等 `_runAgent` 的 `await` 返回、在它的 `finally`
      // 里才复位 —— 那是**几百毫秒到几秒之后**。于是：
      //   · 顶部/卡片还显示"正在生成"
      //   · 发送键还是停止图标（用户以为没停掉）
      //
      // 取消是**用户显式动作**，界面必须**立刻**反映 —— 不等 Kotlin 往返。
      _busy = false;
      _inflightRun = null;
      _stopLive();
      // ★ 清掉被中断那轮的"正在生成"占位 —— 否则它挂着
      //   （`HProgress` 没有 finished 状态可置，直接移除最干净：
      //   那一轮没有产出任何最终内容，占位没有存在价值）
      _messages.removeWhere((m) => m is HProgress);
      if (!silent) {
        _messages.add(HAssistantMessage(
          id: _nextId(),
          text: '已停止。你可以继续发消息。',
        ));
      }
    });
    _scrollToBottom();

    // ⚠️ 关于"后端是不是还在跑"（用户的原话疑问）
    //
    // **会真停**，不是只把前端遮起来：
    //   · 模型生成期间 → `job.cancel()` 传播到 `HttpJson.postSse`
    //     的 `finally`，`close()` 输入流打断阻塞中的 `read()`
    //   · 工具执行期间 → `ToolSpec.execute` 是 **suspend** 函数，
    //     取消同样在挂起点生效
    // 所以这里不需要额外做"后台回收"。
  }

  /// 取一条回答的时间（没有就返回 null —— 操作行会省略时间）。
  DateTime? _tsOf(String id) => _answerTs[id];

  /// ★ **从这条回答开一个新会话分支**（2026-10-13 用户要求）。
  ///
  /// ## 语义（如实说明，不假装能做到做不到的事）
  ///
  /// 底层会话是**严格 append-only** 的（铁律 1：append-only 命中
  /// 90–99% 可依赖，而**分支只有 25–105%、不可预测** —— ADR-001）。
  /// 所以这里**不是**在原会话上开分支（那会破坏缓存纪律），
  /// 而是：**新建一个会话，并把原会话到这条回答为止的内容复制过去** ——
  /// 新会话从一开始就是一条干净、可缓存的 append-only 流。
  ///
  /// 用户得到的效果一样（"从这里另起一条线"），
  /// 但代价是**上下文要重新预填充一次**（新会话第一轮无缓存命中）。
  /// 这个取舍写在注释里，避免以后有人以为"分支是免费的"。
  Future<void> _branchFrom(HMessage m) async {
    final ws = _activeWorkspace;
    if (ws == null) return;
    final cut = _messages.indexOf(m);
    if (cut < 0) return;

    // 取"从开头到这条回答"的消息（含），作为新会话的初始内容
    final prefix = _messages.sublist(0, cut + 1);
    final title = prefix
        .whereType<HUserMessage>()
        .map((e) => e.text)
        .firstOrNull ?? '分支';

    try {
      final newId = await _bridge.seedBranch(
        workspacePath: ws.path,
        // 标题取这条线的第一句用户消息（与自动建会话的规则一致）
        title: title.length > 24 ? '${title.substring(0, 24)}…' : title,
        treeUri: ws.treeUri,
        entries: [
          for (final old in prefix)
            ...[
              // ★★ 工作步骤也要分支（2026-10-15 用户反馈修复）★★
              //
              // ## 修的是什么
              //
              // 用户原话：「分支会话没有把思考过程也分支过去，
              //            仅仅分支了正文结论」
              //
              // 步骤卡片（`HStepStream`）承载了**思考过程 + 工具调用过程**，
              // 它们以 `role:"step"` 存在会话 jsonl 里（含 `think` 字段）。
              // 旧代码只搬 user/assistant 的**正文** —— 分支出去的新会话
              // 里看不到"当时怎么想的、调了什么工具"，信息丢失。
              //
              // ## 为什么放在对应消息**前面**
              //
              // 步骤是"产生这条回答的过程"，时序上必然在回答之前 ——
              // 保持时序，读回来的对话流才与原会话一致。
              if (old is HStepStream && old.reasoning.isNotEmpty || old is HStepStream && old.text.isNotEmpty)
                {
                  'role': 'step',
                  'text': old.text,
                  'think': old.reasoning,
                  'stepId': old.stepId,
                  'title': old.title,
                  if (old.index != null) 'i': old.index.toString(),
                  'stage': old.status ?? StepStage.ok.wire,
                  if (old.durationMs != null) 'ms': old.durationMs.toString(),
                },
              // 步骤本身**不进对话正文**（它们是过程，不是结论）——
              // 但 assistant 的正文要保留
              if (old is! HStepStream)
                {
                  'role': old is HUserMessage ? 'user' : 'assistant',
                  'text': old is HUserMessage
                      ? old.text
                      : (old is HAssistantMessage ? old.text : ''),
                },
            ],
        ],
      );
      if (!mounted || newId == null) return;
      await _reload();          // 让新会话出现在列表里
      _switchContext();         // 换上下文（t7 的守卫：结果不会串）
      setState(() {
        _activeSessionId = newId;
        _messages
          ..clear()
          ..addAll(prefix);
        // 时间戳跟着搬过来（新会话里这些回答仍是"当时说的"）
        for (final old in prefix) {
          final t = _answerTs[old.id];
          if (t != null) _answerTs[old.id] = t;
        }
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '建立分支失败：$e');
    }
  }

  /// ★ **真实运行** —— 调用 Kotlin 侧的 `AgentLoop`。
  ///
  /// **没有会话时 Kotlin 会自动新建** —— 这就是
  /// "在工作区里直接发消息"的行为，与桌面版一致。
  Future<void> _runAgent(String request) async {
    setState(() {
      final names = _attachments.map((a) => a.name).join('、');
      final label = _attachments.isEmpty
          ? request
          : '${request.isEmpty ? '（仅附件）' : request}\n\n📎 $names';
      _messages.add(HUserMessage(id: _nextId(), text: label));
      _error = null;
    });
    _scrollToBottom();

    final ws = _activeWorkspace;
    if (ws == null) {
      setState(() {
        _error = '请先选择一个工作区';
        _messages.add(HAssistantMessage(
          id: _nextId(),
          text: '还没有工作区。\n\n'
              '工作区就是你让智能体操作的那个项目文件夹。'
              '点左上角菜单 → ⊕ 选择工作区。',
        ));
      });
      _scrollToBottom();
      return;
    }

    setState(() => _busy = true);

    // ★ 记录这次运行的**归属**：哪个会话、哪个工作区、第几次运行。
    //   await 返回后据此判断"用户是不是正看着它"。
    final origin = _RunOrigin(
      runSeq: ++_runSeq,
      ctxGen: _ctxGen,
      sessionId: _activeSessionId,
      workspaceId: ws.id,
    );

    // ★ 开始订阅实时事件 —— 之后每轮的 TurnStarted / ToolStarted /
    //   ToolFinished / Blocked 都会**当场**反映到界面上，
    //   不用等下面这个 await 返回。
    //
    //   归属必须在**订阅之前**设好：否则订阅刚建立、
    //   第一个事件就到达时 `_liveOrigin` 还是 null，
    //   会被 [_hasLiveOrigin] 当成迟到事件**误丢**。
    _startLive(origin);

    final snapshot = List<HAttachment>.of(_attachments);
    // ★★ 附件在**发出的那一刻**就清空（2026-10-13 修用户报的 bug）★★
    //
    // 用户原话：「文件发送出去了，输入框上还有文件在输入框上，图片也是，
    // 任务完成了，这个文件不见了」——
    //
    // 旧行为：`_attachments.clear()` 在 `await` 返回后、且**只在
    // `stillHere`（用户仍看着这个会话）时**才执行。于是：
    //   · 运行期间附件 chip 一直挂在输入框上（用户以为没发出去）
    //   · 中途切走会话 → 永远不清 → 回来看到残留
    //   · 运行失败 → 也走不到 clear（异常分支）
    //
    // 正确语义：附件**已经随这次请求提交了**，就该立刻从输入区消失 ——
    // 与"运行成功与否"无关。快照 `snapshot` 已抓住内容，界面可以放手。
    setState(_attachments.clear);

    try {
      final result = await _bridge.run(
        workspacePath: ws.path,
        request: request,
        settings: widget.settings.value,
        sessionId: _activeSessionId,
        treeUri: ws.treeUri,
        attachments: snapshot,
      );
      if (!mounted) return;

      // ★★ 结果该不该渲染（2026-10-11 修复 t11 的 B1-a）★★
      //
      // 判"**用户是不是正看着这次运行所属的会话**"，而不是
      // "上下文代号有没有变过"。后者会把 A→B→A 判成"切走"，
      // 于是用户切回 A 时结果被永久丢弃 —— 那就是「原会话不工作」。
      //
      // ⚠️ 刻意**不**在这里 `return`：下面 finally 还要复位 `_busy`
      //    与清理订阅。提前 return 会让以后的人很容易改错。
      final stillHere = _isViewingRun(origin);
      // ★ 被用户取消的那一轮：结果字段全是空的，**不能当正常回答渲染**
      //   （否则会往列表里塞一个空 turns + 空 finalText 的"回答"）。
      //   `_stopRun` 已经写过一条「已停止」的助手消息，这里只需跳过补齐。
      final wasCancelled = result.cancelled;
      if (stillHere && !wasCancelled) {
        setState(() {
          // ---- 兜底补齐 ----
          //
          // 这里**只补事件流没画出来的东西**：
          //   · 已经由 ToolStarted/ToolFinished 实时画过的卡片 → 跳过
          //     （否则同一张卡片出现两次）
          //   · 事件流断了/没起来 → 这里照旧全部补齐，结果不丢
          for (final t in result.turns) {
            if (t.tool == null) continue;

            // ★★ 被拦截的轮次**画成 HBlocked，不画工具卡片**（修复 H-1）★★
            //
            // 被拦截 = 请求了工具但**从未执行**。它必然不在 `_liveToolIds`
            // 里（因为没有 `ToolStarted` 事件），所以**每次拦截都走这条路**。
            //
            // 修复前：这里无条件插一张 `HToolCall`，且 `t.isFailure` 对
            // "重复调用已拦截"这类 verdict 返回 false → **绿色成功卡**。
            // 结果是用户同时看到「已拦截，未执行」**和**一张绿卡 ——
            // 后者是**假信息**：他会以为文件真的被改了。
            //
            // 另外：如果 `Blocked` 事件已经把它画成 `HBlocked` 了，
            // 这里再画一张就是重复。所以先按 `[轮次:工具:参数]` 查一下
            // 是否已有同轮的拦截卡片 —— **只在本次运行内查**
            // （见 [_drawnBlockedKeys] 关于 N-1 的说明）。
            if (t.toolBlocked) {
              final key = _toolKey(t.index, t.tool!, t.args);
              if (!_drawnBlockedKeys.contains(key)) {
                _drawnBlockedKeys.add(key);
                _messages.add(HBlocked(
                  id: _nextId(),
                  reason: t.verdict,
                  tool: t.tool,
                  args: t.args,
                  index: t.index,
                ));
              }
              continue;
            }

            final key = _toolKey(t.index, t.tool!, t.args);
            final liveId = _liveToolIds[key];
            if (liveId != null) {
              // 实时画过 —— 但如果事件流中途断了，状态可能停在 running，
              // 这里用最终结果**纠正**它（幂等）
              final i = _messages.indexWhere((m) => m.id == liveId);
              if (i >= 0 && _messages[i] is HToolCall) {
                final cur = _messages[i] as HToolCall;
                if (cur.status == ToolStatus.running) {
                  _messages[i] = cur.copyWith(
                    result: t.result,
                    // ★ 只认结构化三态 —— 不再用 `isFailure` 猜
                    status: t.toolSucceeded
                        ? ToolStatus.success
                        : ToolStatus.failure,
                  );
                }
              }
              continue;
            }
            _messages.add(HToolCall(
              id: _nextId(),
              tool: t.tool!,
              args: t.args ?? const {},
              result: t.result,
              // ★ 同上：结构化的 toolSucceeded 是唯一权威
              status: t.toolSucceeded ? ToolStatus.success : ToolStatus.failure,
            ));
          }
          if (result.finalText.isNotEmpty) {
            final id = _nextId();
            _messages.add(HAssistantMessage(id: id, text: result.finalText));
            // 记这条回答的时间（操作行右侧显示，2026-10-13）
            _answerTs[id] = DateTime.now();
            final last = result.turns.isNotEmpty ? result.turns.last : null;
            _metrics[id] = last?.metrics ??
                const TurnMetrics(
                    cachedTokens: null,
                    promptTokens: 0,
                    outputTokens: 0,
                    wallMs: 0);
          }
          // 撤掉可能残留的「正在生成…」占位
          final pid = _progressId;
          if (pid != null) {
            _messages.removeWhere((m) => m.id == pid);
            _progressId = null;
          }
        });

        // 首次发消息时 Kotlin 自动建了会话 —— 记下来并刷新侧边栏
        if (_activeSessionId == null && result.sessionId != null) {
          _activeSessionId = result.sessionId;
        }
        await _reload();
      } else {
        // 用户看着**别的会话** —— 结果**不渲染**（t7 的成果，必须保持）。
        //
        // 数据在 Kotlin 侧**已经落盘**（`persistTurns` 在 `result.success`
        // 之前执行），所以用户切回原会话时 `_selectSession` 会从磁盘读回来。
        //
        // 这里什么也不做是**正确的**：若去 setState，就会把 A 的东西写进 B；
        // 若去 `_reload()`，会覆盖 B 正在看的列表。
        _logDroppedRun(origin);
      }

      // ★ 用量记账 —— **在守卫之外**（2026-10-11，t13）
      //
      // 与"渲染"是**两件不同的事**：
      //   · 渲染：只给"用户正在看的那个会话"（t7 的语义）
      //   · 记账：token **是真花掉的**，记在**发起它的那个会话**头上
      //
      // 所以即使用户切走了（`stillHere == false`），这笔账也要记到 A，
      // 而不是丢掉 —— 否则 A 的用量会随"切走时机"随机少算。
      _accrueRunUsage(origin, result);
    } on AgentBridgeException catch (e) {
      if (!mounted) return;
      _reportRunFailure(e.message, origin);
    } catch (e) {
      if (!mounted) return;
      _reportRunFailure('$e', origin);
    } finally {
      // ★★ 收尾必须**无条件**执行 ★★
      //
      // 1. `_inflightRun` 清空 —— 否则「正在运行」横幅永远挂着，
      //    用户会以为一个早就结束的任务还在跑。
      // 2. `_busy` 复位 —— 只在"结果被渲染"的分支里复位会让用户切走后
      //    **输入框永久禁用**，比原来的串会话 bug 更糟。
      if (mounted) {
        setState(() {
          _busy = false;
          if (_inflightRun?.runSeq == origin.runSeq) {
            _inflightRun = null;
          }
        });
      } else {
        _busy = false;
        if (_inflightRun?.runSeq == origin.runSeq) {
          _inflightRun = null;
        }
      }

      // ★ 只清理**属于本次运行**的实时状态。
      //
      // ## 为什么用 `runSeq` 而不是对象 `identical`（2026-10-11，t11 的 #3）
      //
      // 原来写的是 `identical(_liveOrigin, origin)`。那依赖
      // "每个 origin 对象只对应一条订阅"这个前提 —— 而 #3 的重连
      // **复用同一个 origin 对象**建新订阅，前提就变了：一旦将来有人
      // 改成"重连时新建 origin"，`identical` 会失效 →
      // **漏取消 → 悬挂订阅**（平台侧一直持有 sink）。
      //
      // `runSeq` 表达的是意图（"这条订阅属于第几次运行"），
      // 不依赖对象身份，重连多少次都成立。
      // ★★ 出队必须在 `await` **之前**（2026-10-13）
      //
      // 原来放在整个 finally 的末尾 —— 而它前面有
      // `await _eventSub?.cancel()`。那个 await 要等一个真实异步回合，
      // 出队就被推迟了；更实际的问题是：**用户会感到明显的延迟**
      // （取消订阅 + 重新订阅的往返都排在前面）。
      //
      // 出队本身不依赖"订阅是否已清" —— 新一轮的 `_startLive` 会
      // 建立自己的订阅。所以提到 await 之前，语义更直接、也更快。
      //
      // ⚠️ 只在 `_busy` 已复位后出队 —— 否则新一轮会被当成"还在忙"，
      //    排队消息永远发不出去（那正是"排队是骗人的"）。
      if (mounted && !_busy) _drainQueue();

      if (_liveOrigin?.runSeq == origin.runSeq) {
        await _eventSub?.cancel();
        _eventSub = null;
        _liveOrigin = null;
        _progressId = null;
        _liveToolIds.clear();
        _pendingRaw.clear();
        _drawnBlockedKeys.clear();
      }
    }
    _scrollToBottom();
  }

  /// 丢弃某次运行的结果时的诊断日志。
  ///
  /// **不弹 UI 提示**：用户主动切走了，结果又没丢（在磁盘上），
  /// 弹个提示只会打断他在新会话里做的事。
  /// 但必须留下可排查的痕迹 —— 否则将来有人报"结果没出现"时无从判断。
  void _logDroppedRun(_RunOrigin origin) {
    // ignore: avoid_print
    print(
      'HERC-GUARD 已切换会话，丢弃运行结果'
      '（发起时 session=${origin.sessionId ?? '(自动新建)'} / '
      'ws=${origin.workspaceId} / gen=${origin.ctxGen}；'
      '当前 session=$_activeSessionId / gen=$_ctxGen）'
      '—— 数据已由 Kotlin 落盘，切回原会话可见',
    );
  }

  /// 运行失败的处理 —— **同样要过会话守卫**。
  ///
  /// ## 为什么错误必须区别于成功
  ///
  /// 成功的结果**已经落盘**，丢弃它用户切回去还能看到，
  /// 所以静默是正确的。
  ///
  /// 但**失败没有落盘** —— 用户切回去只会看到自己那条消息，
  /// 永远不知道为什么没下文。静默丢弃会让一次真实的失败
  /// 变成"莫名其妙没反应"，那正是本次要根治的体验。
  ///
  /// 所以失败用 **SnackBar**（瞬时、悬浮）提示：
  /// 它**不往 `_messages` 里插任何东西**，因此不会污染当前会话，
  /// 同时又让用户知道"刚才那次是失败的"。
  void _reportRunFailure(String message, _RunOrigin origin) {
    // ★ 与结果渲染用**同一套**判据（2026-10-11）
    //
    // 必须是 `_isViewingRun` 而不是"上下文代号变没变" ——
    // 否则 A→B→A 之后用户回到 A，失败却被判成"已切走"，
    // 只在 SnackBar 里闪一下（甚至因为 SnackBar 已过期而完全看不到），
    // 而 A 的列表里永远只有自己那条消息、没有任何解释。
    final stillHere = _isViewingRun(origin);
    if (stillHere) {
      // 没切走 —— 照旧内联显示（这是用户最需要看到失败的地方）
      setState(() {
        _error = message;
        _messages
            .add(HAssistantMessage(id: _nextId(), text: '运行失败：$message'));
      });
      return;
    }

    // 已切走 —— 用 SnackBar，**不碰** _messages / _error
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('上一个会话的运行失败：$message'),
        duration: const Duration(seconds: 6),
      ),
    );
    _logDroppedRun(origin);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    // ★ 离开页面必须停订阅 —— 否则平台侧一直持着 sink（泄漏），
    //   且事件会打到一个已卸载的 State 上。
    _eventSub?.cancel();
    _eventSub = null;
    _openSessionSub?.cancel();
    _openSessionSub = null;
    // ★★ 16ms 帧定时器**必须**在这里取消 ★★
    //
    // `Timer.periodic` 不受 widget 生命周期管理：不取消的话，离开页面后
    // 它每 16ms 还在跑，回调里对着一个已卸载的 State 调 setState
    // —— 轻则报 "setState() called after dispose()"，重则内存泄漏
    // （Timer 持有闭包 → 闭包持有 State → State 永不回收）。
    // 顺带把缓冲一起丢掉：里面的字属于已经离开的这个页面。
    _clearStreamState();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    // `provider` 仍用于切会话时的后端变更判定（ADR-015）。
    // ⚠️ 原先这里还算过一个 `isCloud`（`!isLocalConfig(provider)`）喂给
    //    `InputBar.isLocalBackend` —— 两者都随本地后端删除（ADR-035 S4）。
    final provider = widget.settings.value.effectiveProvider;

    return Scaffold(
      key: _scaffoldKey,
      // ★ 横滑呼出侧边栏（2026-10-10 实测定稿）
      //
      // ## 走过的弯路
      //
      // 1. 最初 `drawerEdgeDragWidth: 40` —— 只覆盖左边缘 40dp。
      //    用户从屏幕中间滑（x=400px ≈ 145dp）**在区域外**，所以没反应。
      //    我误判成"与系统返回手势冲突"，其实只是区域太小。
      //
      // 2. 然后关掉内置手势、自己写 `GestureDetector` 做全屏横滑 ——
      //    诊断日志证明判定逻辑全对（`should open; scaffoldState=true`），
      //    但 `openDrawer()` 就是不生效。
      //
      // 3. **回到内置手势，把宽度开到 200dp** —— 这是最终方案。
      //
      // ## 为什么是 200dp
      //
      // 屏幕宽 411dp，200dp ≈ 48% —— 等效于"从左侧近一半区域起划"，
      // 满足"从中间滑动"的诉求。
      //
      // ## 与系统返回手势的关系（实测结论）
      //
      // HyperOS 保留最左约 20dp 做系统返回：
      //   · x=5px   (~2dp)  → 被系统接管，退回桌面
      //   · x=80px  (~29dp) → 我们接住，抽屉打开 ✅
      //   · x=400px (~145dp)→ 我们接住（200dp 覆盖到）✅
      //
      // 两者**部分重叠但不相斥** —— 20dp 归系统，20–200dp 归我们。
      // 用户自然的手指位置落在这里。
      //
      // **☰ 按钮始终保留** —— 手势是补充，不是唯一入口。
      drawerEnableOpenDragGesture: true,
      drawerEdgeDragWidth: 200,

      // ★ 右侧边栏：用量与上下文（2026-10-11，t13；`docs/24`）
      //
      // ## 为什么 `endDrawerEnableOpenDragGesture: false`
      //
      // `docs/24` §4.3 + `docs/21` §2.2 的教训：**右侧边缘是系统返回区**，
      // 而"右滑关闭"又是抽屉的通用手势 —— 让"边缘右滑"同时承担
      // "打开边栏"与"系统返回"两种含义，必然打架。
      //
      // 关掉它**只影响"关闭态的边缘打开手势"**（`DrawerController` 在
      // `_controller.isDismissed` 分支里才挂那个 GestureDetector），
      // **打开态的右滑关闭仍然有效**（另一个分支常驻）。
      // 所以：**打开走按钮，关闭可右滑** —— 正是 `docs/24` 的建议。
      endDrawerEnableOpenDragGesture: false,
      endDrawer: UsageSidebar(
        usage: _usage,
        contextUsage: _contextUsage,
        onClose: () => Navigator.of(context).pop(),
      ),
      onEndDrawerChanged: (open) {
        if (open) unawaited(_refreshContextUsage());
      },
      onDrawerChanged: (open) {
        // 抽屉打开时静默刷新 —— 会话可能在别处变化
        if (open && !_loading) _reload(silent: true);
      },
      drawer: WorkspaceDrawer(
        workspaces: _workspaces,
        loading: _loading,
        onSelectSession: _selectSession,
        onNewSession: _newSession,
        onOpenSettings: _openSettings,
        onAddWorkspace: _pickWorkspace,
        // ★ 内置「应用工作区」—— 与"选文件夹"并列的第二入口（2026-10-17）。
        //   两个入口互不兜底：一个选用户自己的项目，一个进能构建的内置目录。
        onAddAppWorkspace: _addAppWorkspace,
        onRemoveWorkspace: _removeWorkspace,
        onRenameSession: _renameSession,
        onDeleteSession: _deleteSession,
        onToggleStar: _toggleStar,
        onToggleArchive: _toggleArchive,
        onToggleWorkspace: _toggleWorkspace,
        viewOptions: _view,
        onViewOptionsChanged: _saveView,
        searchQuery: _search,
        onSearchChanged: (q) => setState(() => _search = q),
      ),
      appBar: AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: Icon(Icons.menu_rounded, size: 22, color: h.text),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: Row(
          children: [
            // ★ 标题只有工作区名（2026-10-12，用户要求）：
            //   「你标题上面的这个本地模型名称还放着那干嘛？」——
            //   BackendBadge（[本地|qwen3.5-4b] 绿胶囊）移除。
            //   模型信息在输入框的模型选择框里已经有了，标题不重复。
            Flexible(
              child: Text(
                _activeSession?.title ?? _workspaceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: h.text,
                ),
              ),
            ),
          ],
        ),
        actions: [
          // ★ 常驻**紧凑指示器** → 点击打开右侧边栏（2026-10-11，t13）
          //
          // 为什么常驻的是它、而不是一个普通图标：
          // 用户要"命中率显示在一个固定位置"。手机上放不下参考图那种
          // 三簇状态条（`docs/24` §5），所以这里只放**一个数**，
          // 详情进边栏。数本身可点 —— 少一次"先找图标"的认知成本。
          UsageIndicator(
            usage: _usage,
            contextUsage: _contextUsage,
            onTap: _openUsageSidebar,
          ),
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded, size: 20, color: h.textDim),
            onPressed: _busy ? null : _reload,
          ),
          const SizedBox(width: HSpace.xs),
        ],
      ),
      body: Column(
        children: [
          // ★ 首启引导（2026-10-19）：没配 Key 时**主动**告诉用户下一步做什么，
          //   而不是等发送失败后给一句"还没有可用的模型提供商"。
          if (!_modelReady) _SetupBanner(h: h, onOpenSettings: _openSettings),
          if (_error != null)
            _ErrorBanner(
              message: _error!,
              h: h,
              onRetry: _retryLastRun,
              onDismiss: () => setState(() => _error = null),
            ),
          // ★ 在途运行说明（2026-10-11，t11 的 B1-b / B2）
          //
          // 有运行在途、但**当前列表里看不到它的实时进度**时，必须说明
          // 情况 —— 否则用户看到的是"半截会话 + 禁用的输入框"，
          // 只能得出"这个 App 坏了"的结论。
          //
          // ⚠️ 「正在生成…」横幅已移除（2026-10-13 用户要求）。
          //
          // 用户原话：「正在生成的提示不应该固定在标题栏下方，去除，
          // 有流式响应布局」—— 顶部常驻横幅占掉一行高度，而流式响应
          // 本身（思考过程 + 正文逐字）已经在列表里实时显示，
          // 横幅是冗余的。
          //
          // **但输入被禁用时必须仍有解释**（t14 的教训：静默禁用 =
          // 用户以为界面坏了）—— 改由输入框自己的 `stopLabel` +
          // 附件区/输入框状态表达，不再用顶部横幅。
          // ★ 消息列表 + 悬浮的「有新内容」按钮（2026-10-13 再改版）
          //
          // ## 为什么必须用 Stack（上一版做错了）
          //
          // 上一版把 `Align` 作为 Column 的**直接子项** —— 那仍然占掉
          // 一整行高度（Align 有尺寸）。用户当场指出：
          // 「虽然变成一个圆圈了，但是还不是占了一整行嘛？
          //   不是这个按钮的左边一行都是空白反而挡住了后面的文字」。
          //
          // 正解：把列表与按钮放进 **Stack** —— 按钮是**覆盖层**，
          // 不再参与 Column 的高度分配，列表可以铺满整个可视区。
          Expanded(
            child: Column(
              children: [
                // ★ 任务计划清单（2026-10-14，harness）——
                //   常驻列表**顶部**（不随消息滚走）：用户随时能看到
                //   "还要做什么、现在在哪一步"。用户原话：
                //   「顶部显示任务计划（1.查看结构 ✓ 2.写HTML ←进行中 3.验证）」
                if (_planSteps != null && _planSteps!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        HSpace.lg, HSpace.md, HSpace.lg, 0),
                    child: PlanChecklist(
                      steps: _planSteps!,
                      doneCount: _planDone,
                      activeIndex: _planActive,
                      collapsed: _planCollapsed,
                      // ★ 收尾状态（2026-10-15，BUG-1）——
                      //   false = 中断（显示警示，不画成成功）
                      reachedGoal: _planReachedGoal,
                      closedReason: _planClosedReason,
                      onToggle: () =>
                          setState(() => _planCollapsed = !_planCollapsed),
                    ),
                  ),
                Expanded(
                  child: Stack(
              children: [
                Positioned.fill(
                  child: _messages.isEmpty
                      ? _emptyState(h)
                      // ★ `ListView.builder` = **惰性构建**：视口外的条目根本
                      //   不会被创建。逐字场景下这很重要 —— 一轮可能生成几百个
                      //   步骤片段，全部构建会让滚动直接掉帧（`docs/25` §7 第 1 条）。
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(
                              HSpace.lg, HSpace.lg, HSpace.lg, HSpace.sm),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) {
                            final m = _messages[i];
                            return MessageRow(
                              message: m,
                              metrics: m is HAssistantMessage
                                  ? _metrics[m.id]
                                  : null,
                              // ★ 工作步骤展示档位 —— 直接驱动工具卡片的渲染密度
                              stepDetail: widget.settings.value.stepDetail,
                              // ★ 回答末尾的操作行（2026-10-13）
                              timestamp:
                                  m is HAssistantMessage ? _tsOf(m.id) : null,
                              feedback: _feedback[m.id],
                              onFeedback: (f) => setState(() {
                                _feedback[m.id] = f;
                              }),
                              onBranch: () => unawaited(_branchFrom(m)),
                              // ★ 编辑重发（2026-10-13，DeepSeek 移动端同款）：
                              //   原文放回输入框 + 聚焦 —— 用户改完自己点发送。
                              //   不做历史改写（append-only）
                              onEdit: (text) {
                                _inputCtrl.text = text;
                                _inputCtrl.selection = TextSelection.fromPosition(
                                    TextPosition(offset: text.length));
                              },
                            );
                          },
                        ),
                ),
                // ---- 悬浮的「有新内容」小圆圈 ----
                //   用户原话：「应该变成一个小圆圈按钮在右侧」。
                //   叠在列表**右下角**（避开输入框），不占任何布局高度。
                if (_autoScrollPaused && _hasNewContent)
                  Positioned(
                    right: HSpace.lg,
                    bottom: HSpace.md,
                    child: _NewContentButton(onTap: _resumeAutoScroll, h: h),
                  ),
              ],
                  ),
                ),
              ],
            ),
          ),
          InputBar(
            // ★ 输入可用性按【当前会话】判，不是全局 `_busy`（2026-10-11 修 t14）
            //
            // ## 用户报的"切换会话就不工作"的真身
            //
            // 原来这里是 `enabled: !_busy` —— `_busy` 是**屏幕级**字段。
            // 于是在会话 A 发消息后（本地模型 ~11-15 秒），切到会话 B：
            //   · B 的输入框被**禁用**（`TextField(enabled: false)` 真的不能输入）
            //   · 右下角按钮显示成**停止态**
            // 用户看起来像"卡住了 / 不工作了"，**实际是 A 还没跑完**。
            //
            // ## 为什么仍然不能放开（不是偷懒，是结构性约束）
            //
            // 放开就意味着**两个运行并行**，而 `MainActivity.eventSink` 是**单个**字段、
            // 事件里**只有 `index` 没有 session id** —— 两个运行的事件会**混进同一条流**，
            // UI **在原理上无法分辨**哪个事件属于哪个会话。
            // （详见 `_reconnectLive` 的注释与 `docs/24`。）
            //
            // 所以这里做的是**诚实的方案**：
            //   · 当前会话**没有**在跑的运行 → 输入框**可用**
            //   · 当前会话**有**在跑的运行（或全局有运行在途）→ 按用户的
            //     `BusySendBehavior` 处理：
            //       · `queue`（默认）→ **仍可用**，消息排队，跑完自动发
            //       · `interrupt`   → 仍可用，点发送会先停当前任务
            //     —— 见下方 `enabled` 与 `_queuedSendEnabled` 的说明
            //
            // 即：**不让用户在不知情的情况下撞上禁用的输入框**。
            enabled: !_inputBlocked || _queuedSendEnabled,
            busy: _busy,
            // 按钮语义也要分清：只有**当前会话**在跑时才是"停止"，
            // 别的会话在跑时显示"等待" —— 否则用户在 B 看到"停止"会以为能停 B 的东西
            stopLabel: _currentSessionRunning,
            // ★ 发送：忙时按设置走"排队"或"中断"
            onSend: _onSend,
            // ★ 停止（2026-10-13）—— 只在"当前会话在跑"时被点击
            onStop: () => unawaited(_stopRun()),
            // ★ 编辑重发（2026-10-13）：与 MessageRow 共用同一控制器
            inputController: _inputCtrl,
            // ★ 排队待发栏（2026-10-13，输入框上方）
            queuedTexts: [for (final q in _queue) q.text],
            onQueuedSendNow: _sendQueuedNow,
            onQueuedRemove: _removeQueued,
            onQueuedPin: _pinQueued,
            attachments: _attachments,
            onPickAttachment: _pickAttachment,
            onRemoveAttachment: _removeAttachment,
            // ★ 输入框上方那一行开关（2026-10-12，S4）
            //
            // 权限改的是**设置**（会持久化），不等同于"这一次运行"的参数 ——
            // 与 `_settleOrphanSteps` 那类运行态无关。
            permission: widget.settings.value.permission,
            onPermissionChanged: (v) =>
                unawaited(widget.settings.setPermission(v)),
            reasoningLevel: widget.settings.value.reasoningLevel,
            onReasoningLevelChanged: (v) =>
                unawaited(widget.settings.setReasoningLevel(v)),
            // ★ 最大轮次（2026-10-18，docs/27 P0-1 / ADR-033）——
            //   与推理等级同属"单次运行的成本参数"，接法保持一致：
            //   改的是**设置**（持久化），不是"仅这一次运行"的临时参数。
            maxTurns: widget.settings.value.maxTurns,
            onMaxTurnsChanged: (v) =>
                unawaited(widget.settings.setMaxTurns(v)),
            // 本地只有开/关两态那条提示已随本地后端删除（ADR-035 S4）——
            // 不再传 `isLocalBackend`（InputBar 里该参数已移除）。
            // 模型选择框（2026-10-12）：显示当前 provider 的短名，
            // 点击跳设置页（模型/推理等级的正式选择在那里 —— 图二的形态）
            providerLabel: provider?.model,
            // ★ 后端列表（用户要求：模型可以点击选择其他模型）
            providers: widget.settings.value.providers,
            activeProviderId: widget.settings.value.activeProviderId,
            onProviderSelected: (id) =>
                unawaited(widget.settings.setActiveProvider(id)),
            // ★ 点进中转站的模型目录（2026-10-14）——
            //   用户原话：「选择基元律动来当模型用是可以点进去选择模型的」。
            //   二级弹层列出该 provider 的目录，点选即换模型（provider 顺带激活）。
            onOpenModelCatalog: (id) =>
                unawaited(_pickFromCatalog(context, id)),
            onModelTap: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
    );
  }

  /// **ask_user 弹窗**（2026-10-16）—— 模型提问，用户回答。
  ///
  /// ## 交互
  ///
  /// ```
  /// ┌─ 模型需要你的回答 ─────────┐
  /// │                            │
  /// │ 「这个文件已存在，要覆盖     │
  /// │   还是另存为新文件？」       │
  /// │                            │
  /// │ [你的回答____________]      │
  /// │                            │
  /// │        [跳过]  [提交回答]   │
  /// └────────────────────────────┘
  /// ```
  ///
  /// · **提交回答** → `replyAsk` → 工具拿到 → 模型继续
  /// · **跳过** → 也发一条（"（用户未回答）"）—— 让模型明确知道
  ///   用户没答，而不是干等超时（10 分钟）
  /// · **关弹窗（点外面）** → 同跳过
  Future<void> _showAskDialog(BuildContext context, String question) async {
    final ctrl = TextEditingController();
    final h = Hue.of(context);
    String? answer;
    try {
      answer = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (dlgCtx) => AlertDialog(
          backgroundColor: h.surfaceAlt,
          title: Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 20, color: h.accent),
              const SizedBox(width: HSpace.sm),
              const Text('模型需要你的回答',
                  style: TextStyle(fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                question,
                style: TextStyle(
                    fontSize: 14, height: 1.5, color: h.text),
              ),
              const SizedBox(height: HSpace.md),
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                style: TextStyle(fontSize: 14, color: h.text),
                decoration: InputDecoration(
                  hintText: '你的回答…',
                  hintStyle: TextStyle(
                      fontSize: 13, color: h.textFaint),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(HRadius.sm),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: HSpace.sm, vertical: HSpace.sm),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dlgCtx).pop(''),
              child: Text('跳过',
                  style: TextStyle(
                      fontSize: 13, color: h.textDim)),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dlgCtx).pop(ctrl.text.trim()),
              style: FilledButton.styleFrom(
                backgroundColor: h.accent,
              ),
              child: const Text('提交回答',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
    } finally {
      // 无论提交、跳过还是点外面 —— 都要让工具拿到**确定的结果**：
      // · 有回答 → 原文
      // · 无回答 → 明确的"未回答"标记（模型不会干等超时）
      // finally 保证弹窗因任何原因关闭都会走到（包括 dispose）。
      final text = (answer == null || answer.isEmpty)
          ? '（用户未回答，请自行决定下一步）'
          : answer;
      await _bridge.replyAsk(text);
    }
  }

  /// **危险操作审批弹窗**（2026-10-19）。
  ///
  /// 工具返回 `NeedsApproval`（今天 = `run_shell_command` 的命令守卫）时，
  /// Kotlin 侧已挂起等待。这里给用户**明确的决定入口**：
  ///
  /// · 允许 ⇒ `replyApproval(true)` ⇒ 重新执行该工具
  /// · 拒绝 / 点外面 / 系统返回 ⇒ `replyApproval(false)` ⇒ 作为失败回填给模型
  ///
  /// 无论走哪条路都必须回一个决定 —— 否则队列干等 10 分钟，
  /// 用户看到的是"任务卡死"，且模型得不到任何反馈。
  Future<void> _showApprovalDialog(
    BuildContext context, {
    required String? tool,
    required Map<String, String>? args,
    required String reason,
  }) async {
    final h = Hue.of(context);
    // 只展示最有信息量的一段：命令原文 / 路径；太长截断（弹窗不是日志）
    final detail = (args ?? const <String, String>{})
        .entries
        .map((e) => '${e.key}: ${e.value}')
        .join('\n')
        .trim();
    final shownDetail =
        detail.length > 500 ? '${detail.substring(0, 500)}…' : detail;

    final decision = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dlgCtx) => AlertDialog(
        backgroundColor: h.surfaceAlt,
        title: Row(
          children: [
            Icon(Icons.gpp_maybe_outlined, size: 20, color: h.accent),
            const SizedBox(width: HSpace.sm),
            const Text('需要你确认', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reason.isEmpty ? '这个操作需要你确认后才会执行。' : reason,
              style: TextStyle(fontSize: 14, height: 1.5, color: h.text),
            ),
            if (shownDetail.isNotEmpty) ...[
              const SizedBox(height: HSpace.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(HSpace.sm),
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(HRadius.sm),
                ),
                child: Text(
                  shownDetail,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    fontFamily: 'monospace',
                    color: h.textDim,
                  ),
                ),
              ),
            ],
            const SizedBox(height: HSpace.sm),
            Text(
              '允许：执行这次调用；拒绝：本次不执行（模型会收到"被拒绝"）。',
              style: TextStyle(fontSize: 12, color: h.textFaint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop('deny'),
            child: Text('拒绝',
                style: TextStyle(fontSize: 13, color: h.textDim)),
          ),
          // ★ 「本会话始终允许」（2026-10-19）：同一工具 + 同一关键参数不再问。
          //   只在本 run 内有效（不落盘）—— 跨任务的持久白名单是另一个安全决定。
          TextButton(
            onPressed: () => Navigator.of(dlgCtx).pop('allow_always'),
            child: Text('本会话始终允许',
                style: TextStyle(fontSize: 13, color: h.textDim)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dlgCtx).pop('allow'),
            style: FilledButton.styleFrom(backgroundColor: h.accent),
            child: const Text('允许', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
    // null = 点外面/返回键 ⇒ 按**拒绝**处理（安全默认，绝不放行）
    await _bridge.replyApproval(decision ?? 'deny');
  }

  /// **目录选模型**（2026-10-14，二级弹层）。
  ///
  /// 用户原话：「选择基元律动来当模型用是可以点进去选择模型的」——
  /// 中转站一个 Key 下有几十个模型，主弹层里点该 provider 应直接
  /// 进它的目录选。点选即：`model` 换成选中的 + 该 provider 激活。
  ///
  /// ## 为什么放在 chat_screen
  ///
  /// 它需要 [widget.settings]（读目录 + 写回）—— 与模型弹层同级的数据面。
  Future<void> _pickFromCatalog(BuildContext context, String providerId) async {
    final p = widget.settings.value.providers
        .where((e) => e.id == providerId)
        .firstOrNull;
    if (p == null) return;
    if (p.modelCatalog.isEmpty) return;

    final h = Hue.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: HSpace.sm),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HSpace.lg),
              child: Row(
                children: [
                  Text('${p.name} 的模型',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600,
                          color: h.text)),
                  const Spacer(),
                  Text('${p.modelCatalog.length} 个',
                      style: TextStyle(fontSize: 12, color: h.textFaint)),
                ],
              ),
            ),
            const SizedBox(height: HSpace.xs),
            // ★ 可滚动 —— 目录可能几十项（中转站的常态）
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: p.modelCatalog.length,
                itemBuilder: (_, i) {
                  final id = p.modelCatalog[i];
                  final isCurrent =
                      p.id == widget.settings.value.activeProviderId &&
                          id == p.model;
                  return ListTile(
                    dense: true,
                    title: Text(id, style: TextStyle(fontSize: 14, color: h.text)),
                    trailing: isCurrent
                        ? Icon(Icons.check_rounded, size: 18, color: h.accent)
                        : null,
                    onTap: () => Navigator.of(sheetCtx).pop(id),
                  );
                },
              ),
            ),
            const SizedBox(height: HSpace.sm),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await widget.settings.setProviderModel(providerId, picked);
  }

  /// 空态 —— 区分「没工作区」与「有工作区没会话」
  Widget _emptyState(Hue h) {
    if (_loading || _loadingHistory) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: h.textFaint),
        ),
      );
    }
    if (_workspaces.isEmpty) {
      return _Hint(
        h: h,
        icon: Icons.folder_open_rounded,
        title: '先选一个工作区',
        body: '工作区 = 你要让智能体操作的\n那个项目文件夹。\n\n'
            '点左上角菜单 → ⊕ 选择工作区。\n'
            '要构建 APK 就用「默认工作区」。',
        actionLabel: '选择文件夹',
        onAction: _pickWorkspace,
      );
    }
    return _Hint(
      h: h,
      icon: Icons.auto_awesome_rounded,
      // 空态文案（2026-10-12，用户指定）：
      // 「你好，今天想做些什么？」—— 与 llama.cpp Web UI 的
      // "Hello there / Type a message..." 空态同一形态，中文语境
      title: '你好，今天想做些什么？',
      body: _activeSession == null
          ? '发送消息或点击 + 上传文件或图片'
          : '这是会话「${_activeSession!.title}」。\n继续发消息即可。',
    );
  }
}

/// 「有新内容」按钮 —— 自动滚动被用户打断后的回归入口。
///
/// ## 为什么必须有它（而不是"暂停就暂停"）
///
/// 用户上滑是想回看上面的东西。此时新内容仍在源源不断到达
/// （本地模型一轮能吐几百个字），但那**只在列表里，不在视口里**。
/// 没有这个按钮，用户只能自己猜"生成完了没有"，而且很容易以为
/// **内容丢了** —— 比"被动跟着滚"更糟。
///
/// ## 热区 ≥44px
///
/// 移动端触控目标下限（[kMinTapTarget]）—— 这个按钮是唯一路径，
/// 点不到就等于没有。
/// **小圆形「有新内容」按钮**（2026-10-13 改版）。
///
/// 用户原话：「有新内容占的空间太大了，应该变成一个小圆圈按钮在右侧」。
///
/// 旧版是占满一行高度的胶囊（带"有新内容"文字），在流式生成时
/// 会把输入框往上顶、列表可视区变矮。现在改成：
///   · 直径 40 的**圆形**（内部图标 18）
///   · 由调用方用 `Align(centerRight)` 叠在列表右下角 —— **不占布局高度**
///   · 语义靠图标 + Tooltip（无障碍仍可读）
class _NewContentButton extends StatelessWidget {
  const _NewContentButton({required this.onTap, required this.h});

  final VoidCallback onTap;
  final Hue h;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '有新内容，点击回到底部',
      child: Material(
        color: h.accent,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            // 40 略小于 kMinTapTarget(44) 的视觉圆，但 InkWell 的
            // 命中区由外边距补足到 44（见下方 padding 说明）
            width: 40,
            height: 40,
            child: Icon(
              Icons.arrow_downward_rounded,
              size: 20,
              color: h.dark ? const Color(0xFF1A0E08) : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条**排队待发**的消息（2026-10-13）。
///
/// 只活在内存里 —— 它还没"发生"，不属于对话记录（所以不落盘、
/// 也不进 `_messages`）。用户关掉 App 就等于放弃这些排队。
class _QueuedMsg {
  const _QueuedMsg({required this.text, this.attachments = const []});
  final String text;
  final List<HAttachment> attachments;
}

/// **步骤正文的协议剥壳**（2026-10-13，用户截图暴露的渲染缺陷）。
///
/// ## 背景：模型输出的两层数据
///
/// 模型每轮的原始输出是**协议 JSON**（本地 GBNF 强约束 / 云端
/// `response_format`，见 `02-契约规范.md`）：
///
/// ```json
/// {"final":"我是 Heracles…"}          ← 最终回答（正文在里面）
/// {"tool":"write_file","args":{…}}    ← 工具调用
/// ```
///
/// 流式期间**裸渲染**原始流（要逐字快，剥壳等不到），这是设计；
/// 但 `StepEnded` 之后**必须**剥壳 —— 用户原话：
/// 「我想知道工作步骤里面，{}里面的输出是表示什么」。
/// 答案：`{}` 是**给 AgentLoop 解析用的输出协议**，不是给用户的。
/// 用户该看到的是剥壳后的内容 + 正常 Markdown 渲染。
///
/// ## 规则（诚实优先）
///
/// | 输入 | 输出 |
/// |---|---|
/// | `{"final":"X"}` | `X`（剥掉外壳，内容原样） |
/// | `{"tool":…}` | 空串（工具调用有它自己的卡片，正文区不重复渲染） |
/// | 合法 JSON 但两者都不是 | 原文（未知协议形态，不猜） |
/// | **非 JSON**（纯文本回答） | 原文（本来就是人话） |
///
/// 另：`**粗体**` 的星号在此处**不**处理 —— 步骤正文是"过程叙述"，
/// 与最终回答的 Markdown 渲染是两个层级（HStepStream 的渲染器管它）。
String stripProtocolShell(String raw) {
  final s = raw.trim();
  if (!s.startsWith('{') || !s.endsWith('}')) return raw;
  try {
    final j = jsonDecode(s);
    if (j is Map) {
      final f = j['final'];
      if (f is String) return f;
      // 工具调用：正文区不渲染 —— 卡片由 ToolStarted/ToolFinished 负责
      if (j.containsKey('tool')) return '';
      // 未知协议形态：不猜，原文返回
      return raw;
    }
    return raw;
  } catch (_) {
    // 非法 JSON（可能是被截断的半截输出）—— 保持原文。
    // 剥壳失败绝不能丢内容：用户看到原始协议好过看到空白。
    return raw;
  }
}

/// 空态提示
class _Hint extends StatelessWidget {  const _Hint({
    required this.h,
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final Hue h;
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: h.textFaint),
            const SizedBox(height: HSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: h.text,
              ),
            ),
            const SizedBox(height: HSpace.md),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.7, color: h.textFaint),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: HSpace.xl),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: Text(actionLabel!),
                style: FilledButton.styleFrom(
                  backgroundColor: h.accent,
                  foregroundColor: h.dark
                      ? const Color(0xFF1A0E08)
                      : const Color(0xFFFFFFFF),
                  padding: const EdgeInsets.symmetric(
                      horizontal: HSpace.xl, vertical: HSpace.md),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误横幅 —— 桥接或后端出错时显示。
///
/// **不能静默** —— 否则用户以为"模型很笨"，实际是连接问题。
/// **首启引导条**（2026-10-19）—— 没配模型时直接告诉用户去哪配。
///
/// 之前的体验：用户发第一句话 → 运行失败 → 错误条写"还没有可用的模型提供商"。
/// 用户只知道"不能用"，不知道"下一步点哪"。现在在发之前就说清楚，
/// 并且给一个**可点的入口**（而不是让用户自己在设置里翻）。
class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.h, required this.onOpenSettings});

  final Hue h;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: h.accent.withValues(alpha: 0.10),
      padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.sm, HSpace.sm, HSpace.sm),
      child: Row(
        children: [
          Icon(Icons.key_rounded, size: 16, color: h.accent),
          const SizedBox(width: HSpace.sm),
          Expanded(
            child: Text(
              '还没有配置模型 API Key —— 填好才能开始对话',
              style: TextStyle(fontSize: 12, height: 1.4, color: h.text),
            ),
          ),
          TextButton(
            onPressed: onOpenSettings,
            style: TextButton.styleFrom(
              foregroundColor: h.accent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('去设置', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.h,
    this.onRetry,
    this.onDismiss,
  });

  final String message;
  final Hue h;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: HColors.errorOn(h.dark).withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
          horizontal: HSpace.lg, vertical: HSpace.sm + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded,
              size: 16, color: HColors.errorOn(h.dark)),
          const SizedBox(width: HSpace.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  fontSize: 12, height: 1.4, color: HColors.errorOn(h.dark)),
            ),
          ),
          // ★ 2026-10-19：错误必须**可恢复**（此前只能干看着，切走就只剩一句
          //   SnackBar，用户没有任何重试入口）。
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: HColors.errorOn(h.dark),
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          if (onDismiss != null)
            IconButton(
              tooltip: '关闭',
              onPressed: onDismiss,
              icon: Icon(Icons.close_rounded,
                  size: 16, color: HColors.errorOn(h.dark)),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

/// 「另一个会话正在运行」横幅 —— **已废弃**（2026-10-13）。
///
/// ## 为什么删除（用户要求）
///
/// 用户原话：「正在生成的提示不应该固定在标题栏下方，去除，
/// 有流式响应布局」。
///
/// 该横幅常驻占掉一行高度，而流式响应（思考过程 + 正文逐字）
/// 本身已经在列表里实时可见 —— 顶部再挂一条是**冗余**。
///
/// ## 为什么可以安全删除（t14 的教训没有被违背）
///
/// t14 的核心要求是「禁用输入必须说明原因」，不是"必须有横幅"。
/// 现在这层信息改由**输入框自身**表达：
///   · 同一个会话在跑 → `_SendButton` 显示**停止**图标（用户知道能停）
///   · 别的会话在跑   → `_SendButton` 显示**沙漏**（用户知道不是这里）
/// 见 `input_bar.dart` 的 `stopLabel` 说明。
///
/// 保留本注释块是为了让后来者知道这里**曾经有什么、为什么拿掉** ——
/// 避免有人"补回一个横幅"再把用户不想要的东西加回去。



/// 一次运行的**归属** —— 用来判断它返回时用户是不是已经切走了。
///
/// ## 为什么需要这个（2026-10-10 修复 HIGH 缺陷）
///
/// 真机实测本地模型**稳态单轮约 20 秒**（冷启动 132.8 秒 —— 见
/// `docs/23-时延实测更正.md`；别再拿冷启动当稳态引用），多轮任务近 3 分钟。
/// 用户等不到结果时最自然的动作就是**去切会话看看别的** ——
/// 于是 `await _bridge.run(...)` 返回时，当前显示的可能已经是另一个会话了。
///
/// 修复前：结果被**无条件**插进当前的 `_messages` → A 的工具卡片与回复
/// 出现在 B 的列表里。更糟的是 `_stopLive()` 清空了 `_liveToolIds`
/// （去重表），所以 A 的**整轮**记录会完整地串过去。
///
/// ## 为什么同时存 sessionId 和 ctxGen
///
/// - `ctxGen` 是**主判据**：每条"换上下文"的路径都会自增它，
///   覆盖切换会话、新建会话、换工作区、删除当前会话全部情形。
/// - `sessionId` / `workspaceId` 只用于**诊断日志**，
///   让人能从 logcat 看出"当时在哪个会话、现在在哪个"。
///
/// 光比 sessionId 是不够的：首次发消息时 `_activeSessionId` 是 `null`
/// （由 Kotlin 自动建会话），只比 id 会漏掉若干路径。
class _RunOrigin {
  const _RunOrigin({
    required this.runSeq,
    required this.ctxGen,
    required this.sessionId,
    required this.workspaceId,
  });

  /// **这次运行的唯一序号**（自增）。
  ///
  /// 用来回答"这条事件订阅/这个结果**属于哪一次运行**"。
  ///
  /// 2026-10-11（t11 的 #3）引入：切回一个**仍在运行**的会话时，
  /// 我们会**重连事件订阅**（`_reconnectLive`）。重连**复用同一个
  /// `_RunOrigin` 对象**，所以：
  ///
  /// - `finally` 里判断"这条订阅是不是我的"必须用 **`runSeq` 比较**，
  ///   而不能用对象 `identical` —— 重连后 `_liveOrigin` 仍是同一个对象
  ///   时 `identical` 恰好成立，但一旦将来有人改成"重连时新建 origin"，
  ///   `identical` 就会失效 → **漏取消 → 悬挂订阅**。
  ///   用 `runSeq` 表达的是意图（"哪一次运行"），不依赖对象身份。
  /// - 注意：`runSeq` 是**运行的**序号，与 `ctxGen`（**上下文**代号）不同。
  ///   一次运行期间用户可以来回切会话很多次，`ctxGen` 会变，
  ///   但 `runSeq` 不变 —— 这正是"切回原会话时结果仍该渲染"的依据。
  final int runSeq;

  /// 会话上下文代号（见 `_ChatScreenState._ctxGen`）。
  ///
  /// ⚠️ 只在 `sessionId == null`（自动建会话）时用于判"用户有没有动过" ——
  /// 见 `_isViewingRun` 的说明。
  final int ctxGen;

  /// 发起时的会话 id；`null` = 由 Kotlin 自动新建
  final String? sessionId;

  /// 发起时的工作区 id
  final String workspaceId;
}
