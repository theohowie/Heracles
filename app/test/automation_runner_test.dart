/// **automation pending 消费闭环测试**（F2，2026-11-02）。
///
/// ## 这个文件在钉死什么
///
/// 宿主（`AutomationScheduler.kt`）到点只做两件事：发通知 + 把 taskId 写进
/// `pending`。真正"到点跑任务"必须在 Dart 侧发生 —— 但
/// `AgentBridge.consumePendingAutomation()` 此前**零调用方**，于是闹钟响了
/// 一辈子，任务一次都没跑。`AutomationRunner` 就是那个缺失的消费者。
///
/// ## 为什么全是注入、不碰 MethodChannel
///
/// 通道和"真跑一次 agent"都不可注入就会逼出 `TestDefaultBinaryMessenger`
/// 与 widget 泵 —— 仓库里已有太多那种测试在真机上炸。这里只验**消费语义**：
/// 谁是 pending、写不写历史、挡不挡重复、失败怎么记账。执行器本身由
/// `main.dart` 注入，它的正确性属于集成测试的范畴。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/automation_runner.dart';
import 'package:heracles_backend/heracles_backend.dart';

/// 固定时间戳（2023-11-14T22:13:20Z）：可读、可心算，避免依赖真实时钟。
const int _t0 = 1700000000000;

/// 假宿主：任务清单就是一个 JSON 字符串，pending 由测试预置。
///
/// 特意**不**在 `consumePending` 里自动清空 —— 真实宿主是"取即清"，但这里
/// 要能模拟"同一批 id 被消费两次"（AlarmManager 抖动 + 启动/回前台双消费），
/// 那才是幂等闸要挡的真实场景。
class _FakeHost {
  _FakeHost({List<Map<String, Object?>> tasks = const []})
      : tasksJson = jsonEncode(tasks);

  String tasksJson;
  List<String> pending = <String>[];

  /// `false` ⇒ 模拟宿主保存失败（SharedPreferences 写不进去）。
  bool saveOk = true;

  int saveCalls = 0;
  int consumeCalls = 0;

  Future<List<String>> consume() async {
    consumeCalls++;
    return List<String>.of(pending);
  }

  Future<String> load() async => tasksJson;

  Future<bool> save(String json) async {
    saveCalls++;
    if (!saveOk) return false;
    tasksJson = json;
    return true;
  }

  /// 解码后按 id 取任务对象（断言用）。
  Map<String, Object?> task(String id) {
    final list = (jsonDecode(tasksJson) as List).cast<Map<String, Object?>>();
    return list.firstWhere((t) => t['id'] == id);
  }
}

Map<String, Object?> _task({
  String id = 'a',
  String title = '每日巡检',
  String prompt = '跑一遍测试',
  int intervalMinutes = 30,
  bool enabled = true,
  List<Map<String, Object?>>? history,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'prompt': prompt,
      'schedule': 'interval',
      'intervalMinutes': intervalMinutes,
      'cron': '',
      'enabled': enabled,
      'runHistory': history ?? <Map<String, Object?>>[],
    };

/// 组装 runner：默认"每次都成功、耗时 42ms"，各测试只覆盖自己关心的那一维。
AutomationRunner _runner(
  _FakeHost host, {
  Future<AutomationExecOutcome> Function(AutomationTask)? execute,
  int Function()? now,
  void Function(String)? log,
  List<String>? executed,
}) {
  return AutomationRunner(
    consumePending: host.consume,
    loadTasks: host.load,
    saveTasks: host.save,
    execute: execute ??
        (task) async {
          executed?.add(task.id);
          return const AutomationExecOutcome(ok: true, durationMs: 42);
        },
    now: now ?? () => _t0,
    log: log,
  );
}

void main() {
  group('★ 到点消费 → 真执行 → 记账', () {
    test('★★ pending 里的任务被执行，历史/下次时间/lastError 全部写对', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      final executed = <String>[];
      final runner = _runner(host, executed: executed);

      final reports = await runner.consumeAndRun();

      expect(executed, ['a'], reason: 'pending 里的任务必须真的执行一次');
      expect(reports, hasLength(1));
      expect(reports.single.taskId, 'a');
      expect(reports.single.status, AutomationRunStatus.executed);
      expect(reports.single.ok, isTrue);
      expect(reports.single.saved, isTrue);

      final t = host.task('a');
      final lastRun = t['lastRun']! as Map<String, Object?>;
      expect(lastRun['ts'], _t0);
      expect(lastRun['ok'], isTrue);
      expect(lastRun['durationMs'], 42);
      expect(lastRun.containsKey('error'), isFalse,
          reason: '成功不该带 error 键（不是 null，是压根没有）');

      expect(t['runHistory'], hasLength(1));
      final h0 = (t['runHistory']! as List).single as Map<String, Object?>;
      expect(h0['ts'], _t0);
      expect(h0['ok'], isTrue);
      expect(h0['durationMs'], 42);

      expect(t['nextRunAt'], _t0 + 30 * 60 * 1000,
          reason: 'interval 任务的 nextRunAt = 本次 ts + 间隔（与 backend AutomationStore 同口径）');
      expect(t['lastError'], isNull);
    });

    test('★ 执行时拿到的就是任务本体（prompt 即到点要跑的东西）', () async {
      final host = _FakeHost(tasks: [_task(prompt: '检查夜间构建')]);
      host.pending = ['a'];
      String? seen;
      final runner = _runner(host, execute: (task) async {
        seen = task.prompt;
        return const AutomationExecOutcome(ok: true, durationMs: 1);
      });

      await runner.consumeAndRun();

      expect(seen, '检查夜间构建');
    });

    test('★ 未定义的新键必须原样保留（只增不改：别把别人写的字段吃掉）', () async {
      final raw = _task()..['createdAt'] = 1690000000000;
      final host = _FakeHost(tasks: [raw]);
      host.pending = ['a'];
      final runner = _runner(host);

      await runner.consumeAndRun();

      expect(host.task('a')['createdAt'], 1690000000000);
      expect(host.task('a')['title'], '每日巡检');
      expect(host.task('a')['intervalMinutes'], 30);
    });
  });

  group('★ 失败不吞：如实记账', () {
    test('★★ execute 报失败 ⇒ ok:false + 人话原因进历史', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      final runner = _runner(
        host,
        execute: (_) async => const AutomationExecOutcome(
          ok: false,
          error: '工作区不存在：/storage/emulated/0/Heracles',
          durationMs: 7,
        ),
      );

      final reports = await runner.consumeAndRun();

      expect(reports.single.ok, isFalse);
      expect(reports.single.reason, contains('工作区不存在'));
      final t = host.task('a');
      final lastRun = t['lastRun']! as Map<String, Object?>;
      expect(lastRun['ok'], isFalse);
      expect(lastRun['error'], contains('工作区不存在'));
      expect(lastRun['durationMs'], 7);
      expect(t['lastError'], contains('工作区不存在'));
      expect(t['runHistory'], hasLength(1),
          reason: '失败也是一次真实结果，必须记历史（否则用户永远不知道没跑成）');
    });

    test('★★ 超长错误按 ContractAutomation.maxErrorChars 截断', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      final runner = _runner(
        host,
        execute: (_) async => AutomationExecOutcome(
          ok: false,
          error: 'x' * (ContractAutomation.maxErrorChars + 300),
          durationMs: 7,
        ),
      );

      await runner.consumeAndRun();

      final t = host.task('a');
      final err = (t['lastRun']! as Map<String, Object?>)['error']! as String;
      expect(err.length, ContractAutomation.maxErrorChars);
      expect((t['lastError']! as String).length, ContractAutomation.maxErrorChars);
      expect((t['runHistory']! as List).single, isA<Map<String, Object?>>());
    });

    test('★★ execute 抛异常 ⇒ 捕获成 ok:false，且不影响后面的任务', () async {
      final host = _FakeHost(tasks: [_task(id: 'a'), _task(id: 'b')]);
      host.pending = ['a', 'b'];
      final runner = _runner(host, execute: (task) async {
        if (task.id == 'a') throw StateError('provider 连不上');
        return const AutomationExecOutcome(ok: true, durationMs: 3);
      });

      final reports = await runner.consumeAndRun();

      expect(reports, hasLength(2));
      expect(reports[0].taskId, 'a');
      expect(reports[0].ok, isFalse);
      expect(reports[0].reason, contains('provider 连不上'));
      expect(reports[1].taskId, 'b');
      expect(reports[1].ok, isTrue);

      final a = host.task('a');
      expect((a['lastRun']! as Map<String, Object?>)['ok'], isFalse);
      expect(a['lastError'], contains('provider 连不上'));
      expect(host.task('b')['runHistory'], hasLength(1));
    });
  });

  group('★ 幂等三闸（宿主已原子取走，这里再挡两道）', () {
    test('★★ 同一批 pending 消费两次，只执行一次，重复那次不记历史', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      final executed = <String>[];
      final runner = _runner(host, executed: executed, now: () => _t0);

      await runner.consumeAndRun();
      // 模拟宿主没清干净 / AlarmManager 抖动导致同一 id 又进了一次 pending。
      host.pending = ['a'];
      final second = await runner.consumeAndRun();

      expect(executed, ['a'], reason: '同一轮不该跑两次 —— 每次 run 都要烧 token');
      expect(second.single.status, AutomationRunStatus.skipped);
      expect(second.single.reason, contains('重复'));
      expect(host.task('a')['runHistory'], hasLength(1),
          reason: '被去重闸挡下的跳过不算一次运行，不许进历史');
    });

    test('★ 同进程并发两次 consumeAndRun，也只执行一次', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      final executed = <String>[];
      final runner = _runner(host, executed: executed, now: () => _t0);

      await Future.wait([
        runner.consumeAndRun(),
        runner.consumeAndRun(),
      ]);

      expect(executed, ['a']);
      expect(host.task('a')['runHistory'], hasLength(1));
    });

    test('★ 距上次运行恰好一半间隔 ⇒ 可以跑；差 1ms 不到一半 ⇒ 跳过', () async {
      final half = 30 * 60 * 1000 ~/ 2;
      // 先跑一次，把 lastRun 写成 _t0。
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      await _runner(host, now: () => _t0).consumeAndRun();

      // 边界内（差 1ms）：跳过。
      host.pending = ['a'];
      final executed = <String>[];
      final skip = await _runner(
        host,
        executed: executed,
        now: () => _t0 + half - 1,
      ).consumeAndRun();
      expect(executed, isEmpty);
      expect(skip.single.status, AutomationRunStatus.skipped);

      // 边界上（恰好一半）：真跑。
      host.pending = ['a'];
      final run = await _runner(
        host,
        executed: executed,
        now: () => _t0 + half,
      ).consumeAndRun();
      expect(executed, ['a']);
      expect(run.single.status, AutomationRunStatus.executed);
    });
  });

  group('★ 跳过要讲原因，且不许写假历史', () {
    test('★★ 已停用的任务不执行、不记账', () async {
      final host = _FakeHost(tasks: [_task(enabled: false)]);
      host.pending = ['a'];
      final executed = <String>[];
      final runner = _runner(host, executed: executed);

      final reports = await runner.consumeAndRun();

      expect(executed, isEmpty);
      expect(reports.single.status, AutomationRunStatus.skipped);
      expect(reports.single.reason, contains('停用'));
      expect(host.task('a')['runHistory'], isEmpty);
      expect(host.task('a').containsKey('lastRun'), isFalse);
      expect(host.saveCalls, 0, reason: '没有任何改动就不该回写（免得把宿主的清单改坏）');
    });

    test('★★ 找不到的任务不执行、不写假历史、也不回写', () async {
      final host = _FakeHost(tasks: [_task(id: 'a')]);
      host.pending = ['ghost'];
      final executed = <String>[];
      final runner = _runner(host, executed: executed);

      final reports = await runner.consumeAndRun();

      expect(executed, isEmpty);
      expect(reports.single.taskId, 'ghost');
      expect(reports.single.status, AutomationRunStatus.skipped);
      expect(reports.single.reason, contains('不存在'));
      expect(host.saveCalls, 0);
      expect(host.task('a')['runHistory'], isEmpty);
    });

    test('★ 任务清单不是合法 JSON ⇒ 不执行、更不许用空清单覆盖掉用户数据', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.tasksJson = 'not a json at all';
      host.pending = ['a'];
      final executed = <String>[];
      final runner = _runner(host, executed: executed);

      final reports = await runner.consumeAndRun();

      expect(executed, isEmpty);
      expect(reports, isEmpty);
      expect(host.saveCalls, 0, reason: '解析失败就回写 = 把用户的任务全删了');
      expect(host.tasksJson, 'not a json at all');
    });
  });

  group('★ 历史只留最近 20 条（与 backend recordRun 同口径）', () {
    test('★★ 已有 20 条时再跑一次，最老那条被挤掉', () async {
      final old = <Map<String, Object?>>[
        for (var i = 0; i < ContractAutomation.historyKeep; i++)
          <String, Object?>{
            'ts': _t0 - 86400000 + i * 1000,
            'ok': true,
            'durationMs': 1,
          },
      ];
      // 最后一条历史是"昨天"⇒ 远超过一半间隔，不触发去重闸（要验的是裁剪，不是闸）。
      final host = _FakeHost(tasks: [_task(history: old)]);
      host.pending = ['a'];
      final runner = _runner(host);

      await runner.consumeAndRun();

      final hist = (host.task('a')['runHistory']! as List)
          .cast<Map<String, Object?>>();
      expect(hist, hasLength(ContractAutomation.historyKeep));
      expect(hist.last['ts'], _t0, reason: '最新一条必须是这次跑出来的');
      expect(hist.first['ts'], _t0 - 86400000 + 1000,
          reason: '最老那条被挤掉，第 2 老的顶上来');
    });
  });

  group('★ 落盘失败不许假装成功', () {
    test('★★ saveTasks 失败 ⇒ 报告 saved:false，但执行结果如实保留', () async {
      final host = _FakeHost(tasks: [_task()]);
      host.pending = ['a'];
      host.saveOk = false;
      final executed = <String>[];
      final runner = _runner(host, executed: executed);

      final reports = await runner.consumeAndRun();

      expect(executed, ['a'], reason: '跑是真跑了，不能因为落盘失败就说没跑');
      expect(reports.single.status, AutomationRunStatus.executed);
      expect(reports.single.ok, isTrue);
      expect(reports.single.saved, isFalse, reason: '落盘失败必须能反映出来');
      expect(host.tasksJson, isNot(contains('lastRun')),
          reason: '假宿主没真写进去，清单里当然不该有历史');
    });
  });
}
