/// **automation pending 消费者**（F2，2026-11-02；契约见 `docs/INTERFACE.md` §N16.3）。
///
/// ## 这个类存在的唯一理由
///
/// 宿主（`AutomationScheduler.kt`）用 AlarmManager 做**真实定时**，到点只做两件事：
/// ① 发通知；② 把 taskId 写进 SharedPreferences 的 `pending`。真正"跑 agent"必须在
/// Dart 侧 —— 但 `AgentBridge.consumePendingAutomation()` 一直没有调用方，于是闹钟
/// 准时响、通知准时弹，**任务一次都没跑过**。这里补的就是那个消费者：
///
/// ```
/// consumePending（宿主取即清）→ 解析任务 JSON → 逐个执行 → 写回 lastRun/runHistory
/// ```
///
/// ## 为什么全依赖注入
///
/// 通道（MethodChannel）与"真跑一次 agent"都不能在单测里跑：前者要假二进制信使，
/// 后者要网络 + 模型配置。把它们抽成函数后，本类只负责**消费语义**（幂等、记账、
/// 失败不吞），执行器的正确性归集成测试。生产装配在 `main.dart`，注入的是：
/// `AgentBridge.consumePendingAutomation` / `loadAutomationTasks` /
/// `saveAutomationTasks` / 一个"跑 `task.prompt`"的闭包。
///
/// ## 幂等三闸
///
/// 1. **宿主**：`automationConsumePending` 取即清（原子），跨进程有效；
/// 2. **本类**：`_running` 集合 —— 同一进程内同一任务不并发执行；
/// 3. **本类**：`lastRun.ts` 距现在 < 间隔 × [ContractAutomation.dedupeRatio] ⇒ 判
///    重复触发，跳过且**不写历史**（跳过不是一次运行）。
///
/// 为什么需要 ②③ 而不是只信任宿主：AlarmManager 的 `setInexactRepeating` 有抖动，
/// 且"冷启动"与"回前台"可能各消费一次；只靠宿主清空挡不住"同一 id 两次入队"。
///
/// ## 记账口径：优先复用 backend `AutomationStore`
///
/// `lastRun` / `lastError` / `nextRunAt` / 历史裁剪（[ContractAutomation.historyKeep]）
/// 全部由 [AutomationStore] 计算，本类**不另写一套** —— 两套裁剪逻辑迟早对不齐。
/// 回写 JSON 时用的是**原始 map**，只覆盖那四个键：任务对象里别人的新键（前端将来
/// 可能加 `createdAt` / `notifyOnly` 之类）不会因为过一遍本类就消失。
///
/// ## 前提缺失怎么办
///
/// 无工作区 / 无模型配置 **不是**"静默跳过"的理由 —— 那会让用户以为任务在跑。
/// 这类判断属于执行器（它才知道工作区和 provider 的状态），执行器必须返回
/// `ok:false` + 人话原因，本类原样记进历史。执行器抛异常时本类兜底成 `ok:false`，
/// 异常消息截断到 [ContractAutomation.maxErrorChars]。
library;

import 'dart:async';
import 'dart:convert';

import 'package:heracles_backend/heracles_backend.dart';

/// 一次执行的**真实**结果（由注入的 `execute` 产出）。
///
/// `ok:false` 必须带人话 [error]（"为什么没跑成"），空字符串和 null 都算没解释 ——
/// 用户看到的 `lastError` 会直接是它。
class AutomationExecOutcome {
  const AutomationExecOutcome({
    required this.ok,
    this.error,
    this.durationMs = 0,
  });

  final bool ok;

  /// 失败原因（人话）。`ok:true` 时通常为 null。
  final String? error;

  /// 本次执行耗时（毫秒，执行器自报；抛异常时由本类用墙钟补算）。
  final int durationMs;
}

/// 单个 pending id 的处理结果（全部跳过也逐条给，便于 UI/日志解释"为什么没跑"）。
enum AutomationRunStatus {
  /// 真的执行了一次（无论成功失败）。
  executed,

  /// 没执行：任务不存在 / 已停用 / 判为重复触发。
  skipped,
}

/// 一个 pending id 的处理报告。
class AutomationRunReport {
  const AutomationRunReport({
    required this.taskId,
    required this.status,
    required this.ok,
    this.title,
    this.reason,
    this.durationMs = 0,
    this.saved = true,
  });

  final String taskId;

  /// 任务标题（任务不存在时为 null）。
  final String? title;

  final AutomationRunStatus status;

  /// **是否成功执行**。`skipped` 时恒为 false —— 用 [skipped] 判断"是跳过还是失败"，
  /// 别把"跳过"当成"跑失败"（跳过不会写进历史）。
  final bool ok;

  /// 跳过原因 / 失败原因（人话）。跳过时必有值。
  final String? reason;

  final int durationMs;

  /// 本次改动是否**已落盘**。
  ///
  /// `false` 只出现在"有改动但 `saveTasks` 返回失败"时 —— 历史已经算了、任务也真跑了，
  /// 但下次打开读不到，可能重复跑一次。没有改动时恒为 true（没有待落盘内容）。
  final bool saved;

  bool get skipped => status == AutomationRunStatus.skipped;

  AutomationRunReport _withSaved(bool value) => AutomationRunReport(
        taskId: taskId,
        title: title,
        status: status,
        ok: ok,
        reason: reason,
        durationMs: durationMs,
        saved: value,
      );

  @override
  String toString() =>
      'AutomationRunReport($taskId, $status, ok=$ok, saved=$saved'
      '${reason == null ? '' : ', reason=$reason'})';
}

/// pending 消费器（无状态持久化，任务清单始终以宿主为准）。
class AutomationRunner {
  AutomationRunner({
    required Future<List<String>> Function() consumePending,
    required Future<String> Function() loadTasks,
    required Future<bool> Function(String tasksJson) saveTasks,
    required Future<AutomationExecOutcome> Function(AutomationTask task) execute,
    int Function()? now,
    void Function(String message)? log,
  })  : _consume = consumePending,
        _load = loadTasks,
        _save = saveTasks,
        _executeTask = execute,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _logLine = log;

  final Future<List<String>> Function() _consume;
  final Future<String> Function() _load;
  final Future<bool> Function(String tasksJson) _save;
  final Future<AutomationExecOutcome> Function(AutomationTask task) _executeTask;
  final int Function() _now;
  final void Function(String message)? _logLine;

  /// 正在执行的任务 id（闸②：同进程不并发同任务）。
  ///
  /// 真实触发场景：一批 pending 里同一个 id 出现两次（闹钟抖动 + 用户没点开，
  /// 下一轮又写了一次）。若不在执行期间占位，第二次会读到还没落盘的旧 `lastRun`
  /// 而放行，同一轮就烧两遍 token。
  final Set<String> _running = <String>{};

  /// 串行化的队尾。
  ///
  /// 为什么还要一个全局锁：`consumeAndRun` 是"读整份清单 → 改 → 写整份清单"，
  /// 两个并发调用各自持有一份快照时，后写的那份会把前一份的历史**覆盖掉**（丢账）。
  /// 闸②管"同一个任务"，这个锁管"同一份文件"。
  Future<void> _tail = Future<void>.value();

  /// 取走宿主的 pending 并逐条执行，返回每个 id 的处理报告。
  ///
  /// 不抛：执行器的异常在这里被吞成 `ok:false` 记账；宿主读写异常同样降级成
  /// 跳过 + 日志（本方法是 UI 生命周期回调，抛出去没人接）。
  Future<List<AutomationRunReport>> consumeAndRun() {
    final completer = Completer<List<AutomationRunReport>>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await _consumeAndRunOnce());
      } catch (e, st) {
        // 兜底：单体任务已经逐个 try/catch 了，走到这里说明是宿主读写或解析炸了。
        _logLine?.call('automation 消费失败：$e\n$st');
        completer.complete(const <AutomationRunReport>[]);
      }
    });
    return completer.future;
  }

  Future<List<AutomationRunReport>> _consumeAndRunOnce() async {
    final pending = await _consume();
    if (pending.isEmpty) return const <AutomationRunReport>[];

    final raw = await _load();
    final tasks = _decodeTasks(raw);
    if (tasks == null) {
      // 解析失败 ⇒ 立刻返回，**绝不回写**：用空清单覆盖等于把用户的定时任务全删了。
      _logLine?.call('automation 任务清单无法解析，本次不执行也不覆盖：${_clip(raw, 200)}');
      return const <AutomationRunReport>[];
    }

    final store = AutomationStore(tasks.byId.values);
    final reports = <AutomationRunReport>[];
    var dirty = false;

    for (final id in pending) {
      final key = id.trim();
      if (key.isEmpty) continue;

      final task = tasks[key];
      final rawTask = tasks.rawOf(key);
      if (task == null || rawTask == null) {
        reports.add(AutomationRunReport(
          taskId: key,
          status: AutomationRunStatus.skipped,
          ok: false,
          reason: '任务不存在（可能已被删除）',
        ));
        continue;
      }
      if (!task.enabled) {
        reports.add(AutomationRunReport(
          taskId: key,
          title: task.title,
          status: AutomationRunStatus.skipped,
          ok: false,
          reason: '任务已停用，不执行',
        ));
        continue;
      }

      // 闸②：同一进程内同一任务正在跑 ⇒ 跳过（不写历史）。
      if (!_running.add(key)) {
        reports.add(AutomationRunReport(
          taskId: key,
          title: task.title,
          status: AutomationRunStatus.skipped,
          ok: false,
          reason: '同一任务正在执行，本次跳过',
        ));
        continue;
      }

      try {
        // 闸③：距上次运行不足"间隔 × dedupeRatio" ⇒ 判重复触发。
        final duplicate = _isDuplicate(task, store.lastRun(key));
        if (duplicate != null) {
          reports.add(AutomationRunReport(
            taskId: key,
            title: task.title,
            status: AutomationRunStatus.skipped,
            ok: false,
            reason: duplicate,
          ));
          continue;
        }

        final run = await _runOnce(task);
        store.recordRun(key, run, keep: ContractAutomation.historyKeep);
        _writeBack(rawTask, store, key);
        dirty = true;

        reports.add(AutomationRunReport(
          taskId: key,
          title: task.title,
          status: AutomationRunStatus.executed,
          ok: run.ok,
          reason: run.error,
          durationMs: run.durationMs,
        ));
      } finally {
        _running.remove(key);
      }
    }

    if (!dirty) {
      // 全是跳过 ⇒ 清单一个字节都没变，回写只会给宿主制造一次无意义的重注册。
      return List<AutomationRunReport>.unmodifiable(reports);
    }

    bool saved;
    try {
      saved = await _save(jsonEncode(tasks.raws));
    } catch (e) {
      // 宿主保存抛异常等同于保存失败：不许假装成功。
      _logLine?.call('automation 保存任务清单失败：$e');
      saved = false;
    }
    if (!saved) {
      _logLine?.call('automation 保存任务清单失败（宿主返回 false）：历史下次打开会丢');
      return List<AutomationRunReport>.unmodifiable(
        [for (final r in reports) r._withSaved(false)],
      );
    }
    return List<AutomationRunReport>.unmodifiable(reports);
  }

  /// 执行一次，并把"异常"也翻译成一次**真实的失败**。
  ///
  /// 为什么异常耗时用墙钟补算：执行器抛异常时自报的 durationMs 不存在，写 0 会让
  /// "跑了 5 分钟然后崩"看起来像瞬时失败。
  Future<AutomationRun> _runOnce(AutomationTask task) async {
    final started = _now();
    try {
      final out = await _executeTask(task);
      return AutomationRun(
        ts: started,
        ok: out.ok,
        error: out.ok ? null : _clip(out.error ?? '执行失败（执行器未给出原因）'),
        durationMs: out.durationMs > 0 ? out.durationMs : _now() - started,
      );
    } catch (e) {
      return AutomationRun(
        ts: started,
        ok: false,
        error: _clip('执行时异常：$e'),
        durationMs: _now() - started,
      );
    }
  }

  /// 闸③实现：返回跳过原因；`null` = 放行。
  ///
  /// 算不出间隔（cron / intervalMinutes<=0）时**不挡**：本就没有"间隔一半"这个概念，
  /// 编一个阈值只会误杀。cron 任务宿主根本不会注册闹钟，能走到这里说明是手动塞的 id。
  String? _isDuplicate(AutomationTask task, AutomationRun? last) {
    if (last == null) return null;
    if (task.schedule != 'interval' || task.intervalMinutes <= 0) return null;
    final intervalMs = task.intervalMinutes * 60 * 1000;
    final gateMs = (intervalMs * ContractAutomation.dedupeRatio).round();
    final elapsed = _now() - last.ts;
    if (elapsed >= gateMs) return null;
    return '距上次运行不足间隔一半（${elapsed}ms < ${gateMs}ms），判为重复触发';
  }

  /// 从原始 map 里算出四个记账键并写回（**只覆盖这四个键**）。
  void _writeBack(
    Map<String, Object?> rawTask,
    AutomationStore store,
    String id,
  ) {
    final task = store.all.firstWhere((t) => t.id == id);
    rawTask['runHistory'] = [for (final r in task.runHistory) r.toJson()];

    final last = store.lastRun(id);
    if (last == null) {
      rawTask.remove('lastRun');
    } else {
      rawTask['lastRun'] = last.toJson();
    }
    rawTask['nextRunAt'] = store.nextRunAt(id);
    rawTask['lastError'] = store.lastError(id);
  }

  /// 解析任务清单。返回 `null` = 整份不可用（不是"没有任务"）。
  ///
  /// 容忍三种形状：`[...]`（宿主当前写法）、`{"tasks": [...]}`（将来可能包的壳）、
  /// 以及空串/`null` 文本（视作空清单 —— 那是"还没建过任务"，不是损坏）。
  _TaskMap? _decodeTasks(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return _TaskMap(<String, AutomationTask>{}, <Map<String, Object?>>[]);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (e) {
      return null;
    }
    final List<Object?> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map && decoded['tasks'] is List) {
      list = decoded['tasks']! as List;
    } else {
      return null;
    }

    final byId = <String, AutomationTask>{};
    final raws = <Map<String, Object?>>[];
    for (final item in list) {
      if (item is! Map) continue;
      final map = <String, Object?>{};
      item.forEach((k, v) => map['$k'] = v);
      raws.add(map);
      final task = _taskFrom(map);
      if (task == null) continue;
      byId[task.id] = task;
    }
    return _TaskMap(byId, raws);
  }

  /// 单个任务对象 → backend `AutomationTask`（缺字段按宿主默认值补，不抛）。
  AutomationTask? _taskFrom(Map<String, Object?> map) {
    // 用 toString 兜底：宿主/前端某天把 id 写成数字也不该让整份清单解析失败。
    final id = _asString(map['id']).trim();
    if (id.isEmpty) return null; // 没有 id 的任务无法与 pending 配对，跳过
    return AutomationTask(
      id: id,
      title: _asString(map['title']),
      prompt: _asString(map['prompt']),
      // 宿主对缺失 schedule 的默认就是 interval（见 AutomationScheduler.kt）。
      schedule: _asString(map['schedule'], fallback: 'interval'),
      intervalMinutes: _asInt(map['intervalMinutes']),
      cron: _asString(map['cron']),
      enabled: map['enabled'] != false,
      runHistory: _historyFrom(map['runHistory']),
    );
  }

  List<AutomationRun> _historyFrom(Object? value) {
    if (value is! List) return const <AutomationRun>[];
    final out = <AutomationRun>[];
    for (final item in value) {
      if (item is! Map) continue;
      final ts = _asInt(item['ts']);
      out.add(AutomationRun(
        ts: ts,
        ok: item['ok'] == true,
        error: item['error'] is String ? item['error']! as String : null,
        durationMs: _asInt(item['durationMs']),
      ));
    }
    return out;
  }

  int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  String _asString(Object? v, {String fallback = ''}) {
    if (v == null) return fallback;
    if (v is String) return v;
    return v.toString();
  }

  String _clip(String message, [int max = ContractAutomation.maxErrorChars]) {
    final text = message.trim();
    if (text.length <= max) return text;
    // 明确的截断标记：用户要能看出"后面还有内容被省了"，而不是以为错误就这么短。
    return '${text.substring(0, max - 1)}…';
  }
}

/// 解析结果：按 id 建索引 + 保持原始顺序的 map 列表（回写时顺序不能变）。
class _TaskMap {
  _TaskMap(this.byId, this.raws);
  final Map<String, AutomationTask> byId;
  final List<Map<String, Object?>> raws;

  AutomationTask? operator [](String id) => byId[id];
  Map<String, Object?>? rawOf(String id) {
    for (final m in raws) {
      if (m['id'] == id) return m;
    }
    return null;
  }
}
