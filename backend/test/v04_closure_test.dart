import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **V0.4 收口（F1/F2）后端回归** —— 2026-11-02。
///
/// 钉住三件此前**没有测试兜住**的事：
///
/// 1. **内置技能能被导出**（F1）：`builtinSkillEntries()` 与 `builtinSkills()`
///    必须一一对应。改文案忘改清单 ⇒ 这里红。
/// 2. **清单字段齐全且不带正文**：`SkillEntry.toJson()` 是**通道载荷**，
///    带 `body` 会让每次列技能都传几十 KB 正文过去。
/// 3. **Automation 的"最近一次/下次时间"没有编造分支**（F2）：
///    没跑过、已停用、cron 一律 `null`，不许填假的未来时间。
void main() {
  group('F1 builtinSkillEntries — 内置清单导出', () {
    test('★★★ 与 builtinSkills() 一一对应（名字、描述、正文逐字相同）', () {
      final framework = builtinSkills();
      final entries = builtinSkillEntries();

      expect(entries.length, framework.length);
      for (var i = 0; i < framework.length; i++) {
        expect(entries[i].name, framework[i].name);
        expect(entries[i].description, framework[i].description);
        // 正文就是注入系统提示的那段 —— 逐字相同才算"没有第二份真相"
        expect(entries[i].body, framework[i].systemPrompt);
      }
    });

    test('★★ 名字集合精确（多一条/少一条都红）', () {
      expect(
        builtinSkillEntries().map((e) => e.name).toSet(),
        {'verify-loop', 'root-cause-first', 'small-steps'},
      );
    });

    test('★★ 字段齐全：name/description/body 非空，source=builtin，默认启用', () {
      for (final e in builtinSkillEntries()) {
        expect(e.name.trim(), isNotEmpty, reason: '${e.name} 名字为空');
        expect(e.description.trim(), isNotEmpty, reason: '${e.name} 描述为空');
        expect(e.body.trim(), isNotEmpty, reason: '${e.name} 正文为空');
        expect(e.source, ContractSkills.sourceBuiltin);
        expect(e.enabled, isTrue, reason: '出厂默认必须是启用');
      }
    });

    test('★★★ toJson 是通道载荷：四个字段齐全、且不含 body', () {
      final json = builtinSkillEntries().first.toJson();

      expect(json.keys.toSet(), {'name', 'description', 'source', 'enabled'});
      // 正文不进清单（否则每次列技能都传几十 KB）
      expect(json.containsKey('body'), isFalse);
      expect(json['source'], 'builtin');
      expect(json['enabled'], isTrue);
    });

    test('★ 每次调用返回新列表（调用方改动不污染下一次）', () {
      final a = builtinSkillEntries();
      final b = builtinSkillEntries();
      expect(identical(a, b), isFalse);
      expect(a.length, b.length);
    });
  });

  group('F1 契约常量', () {
    test('技能目录与上限钉死', () {
      expect(ContractSkills.skillsDir, '.heracles/skills');
      expect(ContractSkills.maxSkillFileBytes, 512 * 1024);
      expect(ContractSkills.maxScanDepth, 4);
    });

    test('方法名与来源枚举钉死（Kotlin/Dart 两侧都按字符串对话）', () {
      expect(ContractSkills.listMethod, 'skillsList');
      expect(ContractSkills.setEnabledMethod, 'skillsSetEnabled');
      expect(ContractSkills.installMethod, 'skillsInstall');
      expect(ContractSkills.removeMethod, 'skillsRemove');
      expect(ContractSkills.sourceBuiltin, 'builtin');
      expect(ContractSkills.sourceUser, 'user');
    });

    test('错误码都是 E_ 前缀（UI 可按前缀统一处理）', () {
      for (final code in [
        ContractSkills.errNoWorkspace,
        ContractSkills.errSourceInvalid,
        ContractSkills.errSourceUnreachable,
        ContractSkills.errTooLarge,
        ContractSkills.errNotFound,
      ]) {
        expect(code.startsWith('E_'), isTrue, reason: code);
      }
    });
  });

  group('F3 契约常量', () {
    test('连接状态四态钉死（没有第五种“大概连上了”）', () {
      expect(
        {
          ContractMcp.statusNotConfigured,
          ContractMcp.statusUnsupported,
          ContractMcp.statusFailed,
          ContractMcp.statusConnected,
        },
        {'not_configured', 'unsupported', 'failed', 'connected'},
      );
    });

    test('stdio 不可用的文案必须说清原因（不是一句“不支持”）', () {
      expect(ContractMcp.stdioUnsupportedMessage, contains('stdio'));
      expect(ContractMcp.stdioUnsupportedMessage, contains('http'));
    });
  });

  group('F2 Automation 派生状态', () {
    AutomationTask task({
      String id = 'a1',
      String schedule = 'interval',
      int intervalMinutes = 30,
      bool enabled = true,
      List<AutomationRun> history = const <AutomationRun>[],
    }) =>
        AutomationTask(
          id: id,
          title: 't',
          prompt: 'p',
          schedule: schedule,
          intervalMinutes: intervalMinutes,
          enabled: enabled,
          runHistory: history,
        );

    test('★★★ 从未跑过 ⇒ lastRun/lastError/nextRunAt 全为 null（不编造）', () {
      final store = AutomationStore([task()]);
      expect(store.lastRun('a1'), isNull);
      expect(store.lastError('a1'), isNull);
      expect(store.nextRunAt('a1'), isNull);
    });

    test('★★★ nextRunAt = 上次成功时间 + 间隔', () {
      final store = AutomationStore([task()]);
      store.recordRun('a1', const AutomationRun(ts: 1000000, ok: true));

      expect(store.nextRunAt('a1'), 1000000 + 30 * 60 * 1000);
    });

    test('★★ 停用 ⇒ nextRunAt 为 null（停着的任务不该显示“下次运行”）', () {
      final store = AutomationStore([task(enabled: false)]);
      store.recordRun('a1', const AutomationRun(ts: 1000000, ok: true));

      expect(store.nextRunAt('a1'), isNull);
      // 但历史仍然要看得到（停用不等于抹掉记录）
      expect(store.lastRun('a1'), isNotNull);
    });

    test('★★★ cron ⇒ nextRunAt 为 null（cron 未实现，不假装算得出）', () {
      final store = AutomationStore([
        task(schedule: 'cron', intervalMinutes: 0),
      ]);
      store.recordRun('a1', const AutomationRun(ts: 1000000, ok: true));

      expect(store.nextRunAt('a1'), isNull);
    });

    test('★★★ lastError 取“最近一条失败”，不被后来的成功抹掉', () {
      final store = AutomationStore([task()]);
      store.recordRun('a1', const AutomationRun(ts: 1, ok: false, error: '网络超时'));
      store.recordRun('a1', const AutomationRun(ts: 2, ok: true));

      // 最后一轮成功了，但"上次为什么没跑成"仍然要看得到
      expect(store.lastError('a1'), '网络超时');
      expect(store.lastRun('a1')!.ok, isTrue);
    });

    test('★ 全成功 ⇒ lastError 为 null', () {
      final store = AutomationStore([task()]);
      store.recordRun('a1', const AutomationRun(ts: 1, ok: true));
      expect(store.lastError('a1'), isNull);
    });

    test('★★★ 历史只留最近 20 条（超了从头部丢）', () {
      final store = AutomationStore([task()]);
      for (var i = 0; i < 25; i++) {
        store.recordRun('a1', AutomationRun(ts: i, ok: true));
      }
      final hist = store.all.first.runHistory;
      expect(hist.length, ContractAutomation.historyKeep);
      expect(hist.first.ts, 5, reason: '最旧的 5 条应被丢掉');
      expect(hist.last.ts, 24);
    });

    test('★ 未知任务 ⇒ lastRun/lastError/nextRunAt 都是 null，recordRun 返回 false', () {
      final store = AutomationStore();
      expect(store.recordRun('nope', const AutomationRun(ts: 1, ok: true)),
          isFalse);
      expect(store.lastRun('nope'), isNull);
      expect(store.lastError('nope'), isNull);
      expect(store.nextRunAt('nope'), isNull);
    });

    test('幂等闸参数钉死', () {
      expect(ContractAutomation.historyKeep, 20);
      expect(ContractAutomation.dedupeRatio, 0.5);
      expect(ContractAutomation.maxErrorChars, 500);
    });
  });

  group('F4 契约常量', () {
    test('掩码规则钉死（short key 全掩，否则掩码自己就泄完了）', () {
      expect(ContractSearch.maskFullBelow, 8);
      expect(ContractSearch.maskVisibleTail, 4);
      expect(ContractSearch.endpointKey, 'heracles.search.endpoint');
      expect(ContractSearch.apiKeyKey, 'heracles.search.api_key');
    });
  });
}
