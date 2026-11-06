/// **压缩流水线**（2026-11-06）—— 一次压缩事件内的固定顺序：
///
/// ```
/// A 阶段1 MicroCompact（本地清老工具输出/大媒体块，零 API）
/// B 阶段2 SessionMemory（本地规则渲染摘要视图，零 API）
/// C 阶段3 API 结构化摘要（仅当 B 不可用 / 用户给了 focus）
/// D 兜底 确定性强制重置（不依赖任何模型）
/// E 兜底 90% 硬顶升级循环（继续压到物理下限，不许报错、不许停）
/// ```
///
/// ## 三条不许违反的纪律
///
/// 1. **每层都要验证"真的省了 token"**，否则回滚 —— 曾出现过
///    "插了摘要视图反而比原历史更大"（摘要有项目指令、约束、文件清单）。
///    压完更大等于没压，还会让下一轮立刻再触发一次（缓存遭殃）。
/// 2. **达标即停**：投影占用（`估算 × bias`）落到 0.85 线以下就结束，
///    不再往下砍（多砍一刀都是白丢信息）。
/// 3. **失败不改历史**：阶段 3 失败 ⇒ 一条消息都不动，把原因交出去，
///    由 D/E 用"确定性 + 如实说明"的方式腾空间。
///
/// ## 为什么"达标"用投影而不是服务端真值
///
/// `state.usages.last.promptTokens` 反映的是**上一次请求**——它还是压缩前的
/// 历史，压完之后那个数**必然是旧的**。所以判"压够了没有"只能拿估算，
/// 再按 `bias = 真值/估算` 投影回真实量级（真机实测 bias 2.4~2.7，
/// 只看估算会误判"还差得远"或"早就够了"）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../contract/contract.dart';
import 'compaction_config.dart';
import 'compaction_event.dart';
import 'message_scan.dart';
import 'micro_compactor.dart';
import 'reload_context.dart';
import 'send_view.dart';
import 'session_memory.dart';
import 'structured_summarizer.dart';
import 'summary_view.dart';
import 'token_estimation.dart';

/// 确定性兜底的实现（由 `WindowRatioCompressor` 提供；单测可打桩）。
///
/// 为什么抽成接口：D/E 两层需要"按 token 目标裁剪历史"的能力，
/// 那套代码（`_trimToFit` / `_forceReset` / 估算口径）本来就在压缩器里。
/// 用接口把它注入进来，流水线就能在**不启动整个 agent** 的情况下单独被测。
abstract interface class CompactionFallback {
  /// 决策口径占用（`max(服务端真值, 字符估算)`）。
  int decisionUsage(AgentState state);

  /// 纯估算口径占用。
  int estimateUsage(AgentState state);

  /// 投影占用（估算 × bias）：判断"压够了没有"与"离 90% 硬顶多远"。
  int projectedUsage(AgentState state);

  /// 整批丢弃老轮次 + 插如实说明；返回丢弃条数（0 = 没有可丢的）。
  int forceReset(AgentState state);

  /// 按估算目标继续裁剪（清大工具结果 → 丢更早消息 → 截断最大一条）。
  /// 返回是否真的动过历史。
  bool trimToFit(AgentState state, {required int targetEstimateTokens});
}

/// 一次压缩事件的编排器。
class CompactionPipeline {
  CompactionPipeline({
    required this.client,
    required this.modelConfig,
    required this.fallback,
    this.config = const CompactionConfig(),
    this.readProjectFile,
    this.readRecentFile,
    this.sessionMemory,
    this.sessionMemoryProvider,
    this.nowMs,
  }) : _memory = sessionMemory;

  final LLMClient client;
  final ModelConfig modelConfig;
  final CompactionFallback fallback;
  final CompactionConfig config;

  /// 项目指令读取器（宿主注入；null = 不重载，记 note）。
  final ProjectInstructionsReader? readProjectFile;

  /// 工作区文件读取器（宿主注入；null = 只列路径）。
  final RecentFileReader? readRecentFile;

  /// 外部注入的会话记忆（宿主持久化/上一轮留下的）。
  final SessionMemory? sessionMemory;

  /// 会话记忆的更新器（可选）。
  ///
  /// 不注入 ⇒ 用本地规则现抽（`SessionMemoryBuilder`，零 IO、微秒级）。
  /// 注入 ⇒ 由宿主实现"增量更新"，本类负责**超时与失败降级**。
  final Future<SessionMemory> Function(SessionMemory? previous)?
      sessionMemoryProvider;

  /// 时钟（毫秒）；null = `DateTime.now()`。测试注入固定时钟避免 flaky。
  final int Function()? nowMs;

  /// 最近一次用来渲染视图的记忆（排障/UI 用）。
  SessionMemory? _memory;
  SessionMemory? get lastSessionMemory => _memory;

  int _now() => (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();

  /// **全流水线**：A → B → C → D → E。
  ///
  /// [focus] 非空 ⇒ 强制走 C（用户说"这次只保留 XX 相关"时，本地规则听不懂）。
  Future<CompactionEvent> run(
    AgentState state, {
    CompactionTrigger trigger = CompactionTrigger.threshold,
    String? focus,
  }) async {
    final stopwatch = Stopwatch()..start();
    final beforeTokens = fallback.decisionUsage(state);
    final beforeMessages = state.history.messages.length;
    final layers = <CompactionLayer>[];
    var insertedNotes = 0;
    var usedApi = false;
    var apiTokens = 0;
    String? failureReason;
    var injectedBlocks = 0;
    var clearedRefs = const <String, ClearedRef>{};

    /// 收尾（各层"达标即停"时共用；locals 由闭包按引用捕获）。
    CompactionEvent finish() {
      stopwatch.stop();
      final afterCount = state.history.messages.length;
      final kept = afterCount - insertedNotes;
      var dropped = beforeMessages - kept;
      if (dropped < 0) dropped = 0;
      return CompactionEvent(
        trigger: trigger,
        layersRun: List<CompactionLayer>.unmodifiable(layers),
        beforeTokens: beforeTokens,
        afterTokens: fallback.decisionUsage(state),
        elapsedMs: stopwatch.elapsedMilliseconds,
        usedApi: usedApi,
        keptNotes: kept < 0 ? 0 : kept,
        droppedNotes: dropped,
        failureReason: failureReason,
        apiTokens: apiTokens,
        injectedBlocks: injectedBlocks,
        clearedRefs: clearedRefs,
      );
    }

    /// **是否该早停**（达标即停）。
    ///
    /// ⚠️ 手动压缩（`/compact`）例外：用户的诉求是"现在就压一次"，
    /// 而不是"压到线下为止"。所以手动路径会把 A/B/C 都跑完，
    /// 再决定要不要动用兜底裁剪（只有仍**高于触发线**时才继续）。
    bool done() =>
        trigger == CompactionTrigger.manual ? false : _reached(state);

    // ---------------------------------------------------------------
    // A. MicroCompact（本地，一次性）
    // ---------------------------------------------------------------
    final micro = MicroCompactor(config: config)
        .compact(List<LLMMessage>.of(state.history.messages));
    if (micro.changed) {
      // ⚠️ 再量一次"视图 vs 当前历史"：micro 的结果一般是变小的
      //   （占位符远短于原文，且有 microMinChars 兜底），但异常形态下
      //   也绝不做"越压越大"的操作。
      final before = estimateMessagesTokens(state.history.messages);
      if (micro.view.estTokens < before) {
        state.history.messages = micro.view.messages;
        layers.add(CompactionLayer.micro);
        clearedRefs = micro.view.clearedRefs;
      }
    }
    if (done()) return finish();

    // ---------------------------------------------------------------
    // B. Session Memory（本地，零 API）
    // ---------------------------------------------------------------
    final memory = await _updateMemory(state);
    final focusGiven = focus != null && focus.trim().isNotEmpty;
    var memoryRendered = false;
    if (config.sessionMemoryEnabled && !focusGiven) {
      if (memory != null && memory.isUsableAt(_now())) {
        final reloaded = await _loadReloaded(state);
        final note = SummaryViewBuilder(config: config).build(
          source: SummarySource.sessionMemory,
          reloaded: reloaded,
          memory: memory,
          extraNotes: reloaded.notes,
        );
        if (_applySummaryView(state, note) != null) {
          layers.add(CompactionLayer.sessionMemory);
          memoryRendered = true;
          insertedNotes += 1;
          injectedBlocks = reloaded.injectedBlocks + 1;
        }
      }
    }
    if (done()) return finish();

    // ---------------------------------------------------------------
    // C. API 结构化摘要（兜底）
    // ---------------------------------------------------------------
    if (focusGiven || !memoryRendered) {
      final result = await _applyApiSummary(state, focus: focus);
      usedApi = result.usedApi;
      apiTokens += result.apiTokens;
      if (result.applied) {
        layers.add(CompactionLayer.apiSummary);
        insertedNotes += 1;
        injectedBlocks = result.injectedBlocks + 1;
      }
      if (result.failureReason != null) failureReason = result.failureReason;
    }
    if (done()) return finish();
    // 手动压缩：A/B/C 跑完就够；只有仍**高于触发线**才继续动用兜底裁剪。
    if (trigger == CompactionTrigger.manual && _reached(state)) {
      return finish();
    }

    // ---------------------------------------------------------------
    // D. 兜底：确定性强制重置（整批丢弃老轮次，不依赖任何模型）
    // ---------------------------------------------------------------
    final dropped = fallback.forceReset(state);
    if (dropped > 0) {
      layers.add(CompactionLayer.forceReset);
      insertedNotes += 1; // _forceReset 必插一条"如实说明"
    }

    // ---------------------------------------------------------------
    // E. 兜底：按 token 继续压，直到**低于触发线**或**动不了历史**
    // ---------------------------------------------------------------
    //
    // ## 为什么目标从"触发线"开始，而不是直接从 50%
    //
    // D 之后常见两种残局：
    // · 历史很短但**单条巨大**（一次 read_file 把整份文件读进历史）——
    //   `_forceReset` 因为"条数不够多"直接返回 0，占用仍在 85% 以上；
    // · 已经被 D 压过但还贴着线。
    // 两种残局都得靠"按 token 裁剪"解决：先以 0.85 线为目标（清大工具结果
    // 通常就够），不够再按 50% → 30% → 15% 收紧。
    //
    // ## 为什么"动不了就 break"而不是继续循环
    //
    // 动不了 = 已经到**压缩的物理下限**（只剩一两条超大消息）。
    // 此时按用户 2026-11-05 的裁定：**不许报错、不许停任务**，
    // 照常继续（把"压到多少了"如实写在事件里）。
    final targets = <double>[
      config.autoCompactThreshold,
      ...ContractCompaction.ceilingEscalationRatios,
    ];
    for (final ratio in targets) {
      if (_reached(state)) break; // 达标即停
      final targetReal = (config.contextWindow * ratio).floor();
      final est = fallback.estimateUsage(state);
      final projected = fallback.projectedUsage(state);
      // 真实目标 → 估算目标（估算/投影 = 1/bias）
      final scale = projected > 0 ? est / projected : 1.0;
      var targetEst = (targetReal * scale).floor();
      if (targetEst < 1) targetEst = 1;
      final acted = fallback.trimToFit(state, targetEstimateTokens: targetEst);
      if (!acted) break; // 已经压到物理下限
      layers.add(CompactionLayer.ceilingTrim);
      insertedNotes += 1; // _trimToFit 每次成功必插一条说明
    }

    return finish();
  }

  /// **只跑阶段 3，且绝不改动历史** —— 给"预演/单测/排障"用。
  ///
  /// 全流水线里的 C 层走 [_applyApiSummary]（成功才落历史）。
  /// 这个方法只回答一个问题："模型摘要会给出什么、会不会失败"。
  Future<ApiSummaryResult> apiSummaryOnly(
    AgentState state, {
    String? focus,
  }) async {
    final msgs = state.history.messages;
    final cut = _cutIndex(msgs);
    if (cut <= 0) {
      return const ApiSummaryResult(
        ok: false,
        usedApi: false,
        failureReason: '历史太短，没有可摘要的旧消息（保护窗内全部保留）',
      );
    }
    final head = msgs.sublist(0, cut);
    return StructuredSummarizer(
      client: client,
      modelConfig: modelConfig,
      config: config,
    ).summarize(head: head, focus: focus);
  }

  // ---------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------

  /// 投影占用是否已落到触发线以下（"达标"）。
  bool _reached(AgentState state) =>
      fallback.projectedUsage(state) < config.autoCompactLine;

  /// 更新会话记忆（失败/超时 ⇒ 保留旧记忆 + `stale`）。
  Future<SessionMemory?> _updateMemory(AgentState state) async {
    final previous = _memory;
    final provider = sessionMemoryProvider;
    try {
      if (provider != null) {
        final updated = await provider(previous).timeout(
          Duration(milliseconds: ContractCompaction.sessionMemoryUpdateTimeoutMs),
        );
        _memory = updated;
        return updated;
      }
      final built = SessionMemoryBuilder(config: config).build(
        state.history.messages,
        plan: state.plan,
        previous: previous,
        nowMs: _now(),
      );
      _memory = built;
      return built;
    } catch (_) {
      // 不阻塞任务：保留旧内容、标 stale（stale 的记忆不许渲染视图）
      final fallbackMemory = (previous ?? SessionMemory(updatedAtMs: _now()))
          .markStale();
      _memory = fallbackMemory;
      return fallbackMemory;
    }
  }

  Future<ReloadedContext> _loadReloaded(AgentState state) =>
      ContextReloader(
        config: config,
        readProjectFile: readProjectFile,
        readRecentFile: readRecentFile,
      ).load(messages: state.history.messages);

  /// 用 [note] 替换"保护窗之前的旧消息"；**真的变小才落地**。
  ///
  /// 返回 null = 没落地（省不下 token / 没东西可替 / note 为空）。
  String? _applySummaryView(AgentState state, String note) {
    if (note.trim().isEmpty) return null;
    final msgs = state.history.messages;
    final cut = _cutIndex(msgs);
    if (cut <= 0) return null; // 保护窗已经覆盖全部历史 ⇒ 没什么可摘要的
    final tail = msgs.sublist(cut);
    final candidate = <LLMMessage>[UserMessage.text(note), ...tail];
    final before = estimateMessagesTokens(msgs);
    final after = estimateMessagesTokens(candidate);
    if (after >= before) return null; // 插摘要反而更大 ⇒ 不做（见库 KDoc 纪律 1）
    state.history.messages = candidate;
    return note;
  }

  /// 阶段 3 的落地版本（成功才改历史）。
  Future<_ApiApplyResult> _applyApiSummary(
    AgentState state, {
    String? focus,
  }) async {
    final msgs = state.history.messages;
    final cut = _cutIndex(msgs);
    if (cut <= 0) {
      return _ApiApplyResult(
        usedApi: false,
        applied: false,
        failureReason: '历史太短，没有可摘要的旧消息（保护窗内全部保留）',
      );
    }
    final head = msgs.sublist(0, cut);
    final result = await StructuredSummarizer(
      client: client,
      modelConfig: modelConfig,
      config: config,
    ).summarize(head: head, focus: focus);
    if (!result.ok || result.summary == null) {
      return _ApiApplyResult(
        usedApi: result.usedApi,
        applied: false,
        apiTokens: result.apiTokens,
        failureReason: result.failureReason ?? '摘要失败（原因未知）',
      );
    }
    final reloaded = await _loadReloaded(state);
    final note = SummaryViewBuilder(config: config).build(
      source: SummarySource.apiSummary,
      reloaded: reloaded,
      api: result.summary,
      extraNotes: <String>[
        ...reloaded.notes,
        if (result.summary!.parsed == false)
          '注意：模型没有按标签块返回，本条摘要为退化格式',
      ],
    );
    final noteOk = _applySummaryView(state, note);
    if (noteOk == null) {
      // 摘要拿到了但落不下去（省不下 token）⇒ 视为未生效，但仍如实记账 API 花费
      return _ApiApplyResult(
        usedApi: result.usedApi,
        applied: false,
        apiTokens: result.apiTokens,
        failureReason: '摘要已生成但未能减少占用（未写入历史）',
      );
    }
    return _ApiApplyResult(
      usedApi: result.usedApi,
      applied: true,
      apiTokens: result.apiTokens,
      injectedBlocks: reloaded.injectedBlocks,
    );
  }

  /// 保护窗之前的切点（已调整到不拆批）。
  int _cutIndex(List<LLMMessage> msgs) {
    final raw = msgs.length - config.protectedRecentMessages;
    if (raw <= 0) return 0;
    return adjustCutToBatchBoundary(msgs, raw);
  }
}

/// 阶段 3 的内部结果。
class _ApiApplyResult {
  const _ApiApplyResult({
    required this.usedApi,
    required this.applied,
    this.apiTokens = 0,
    this.failureReason,
    this.injectedBlocks = 0,
  });

  final bool usedApi;
  final bool applied;
  final int apiTokens;
  final String? failureReason;
  final int injectedBlocks;
}
