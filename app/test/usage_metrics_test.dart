import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/session_usage.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/usage_sidebar.dart';

/// **用量指标口径的回归测试**（2026-10-21，BUG-5）。
///
/// ## 本文件钉住的是用户那三句质疑
///
/// > 「耗时才 5172ms，改成秒为单位，这个是从开始执行任务到结束任务的耗时，
/// >  你觉得会这么短？输出才 476token，这更不可能了。」
///
/// > 「会话标题右边的第一个圆圈显示缓存命中率 94%，但是下方的显示 96%」
///
/// 三件事 → 三组断言：
///
/// | 质疑 | 根因 | 本文件钉什么 |
/// |---|---|---|
/// | 5172ms 不可能是任务耗时 | `wallMs` 只量模型往返（不含工具/审批/压缩） | `taskWallMs >= wallMs`、两个字段**分别**累计、显示是**秒** |
/// | 94% vs 96% 两个命中率 | 累计·加权 vs 单轮，**同名** | 两个口径的数**确实不同**、标签**不同名** |
/// | 输出 476 token | provider 上报口径（未变） | 累计不被聚合逻辑吃掉、UI 标注来源 |
///
/// ⚠️ 这里**不测** provider 上报是不是少了（那要真 Key / 真机）。
/// 能在这里钉住的是"我们这边有没有把它算漏/算错"。
///
/// ## ★ 2026-10-23 口径变更（本文件已按新口径重算，**旧公式已废**）
///
/// `promptTokens` 的语义从「**未命中部分**」改成「**整段**（含命中）」，
/// 因为真机 provider 回的 `prompt_tokens` 本来就含缓存命中：
///
/// ```
/// prompt_tokens: 5468, prompt_tokens_details: {cached_tokens: 5376}  ⇒ 真值 98.3%
/// ```
///
/// | 口径 | 旧（已废） | 新 |
/// |---|---|---|
/// | 单轮 | `cached / (cached + prompt)` | `cached / prompt` |
/// | 累计·加权 | `Σcached / (Σcached + Σprompt)` | `Σcached / Σprompt` |
/// | 总输入 | `cached + prompt + unreported` | `prompt + unreported`（**不再加 cached**） |
///
/// 旧公式把命中的那部分**加了两次**：上面这组真机数会被算成
/// `5376/(5376+5468) = 49.6%`，侧栏长期显示 ~50%，用户报"命中缓存率太低"。
///
/// ⇒ **凡是继续断言 `cached + prompt` 当分母/总输入的用例，都是在锁错误契约**，
///   必须改成新口径（本文件下面的注释逐条标了"旧口径已废"）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================================================================
  // 1. 任务总耗时（taskWallMs）
  // ==================================================================

  group('任务总耗时 taskWallMs', () {
    test('★ 单次运行：copyRuns 把它记进累计', () {
      final u = SessionUsage.empty
          .add(const SessionUsage().copyRuns(1, taskWallMs: 42000));
      expect(u.runs, 1);
      expect(u.taskWallMs, 42000);
      expect(u.wallMs, 0, reason: '模型用时是另一本账，不该被任务耗时污染');
    });

    test('★ 多次运行：任务耗时逐次累加（不是覆盖）', () {
      var u = SessionUsage.empty;
      u = u.add(const SessionUsage().copyRuns(1, taskWallMs: 30000));
      u = u.add(const SessionUsage().copyRuns(1, taskWallMs: 12000));
      expect(u.runs, 2);
      expect(u.taskWallMs, 42000);
    });

    test('★★ 核心不变量：taskWallMs >= wallMs（用户质疑的那条）', () {
      // 一次真实的 run：3 轮模型往返各 1.7 秒（Σ≈5.2 秒 = 用户看到的 5172ms），
      // 但工具执行 + 审批等待把真实墙钟拉到 48 秒。
      //
      // 旧实现把 5172ms 当"任务耗时"显示 —— 那就是用户说的"你觉得会这么短？"。
      var u = SessionUsage.empty;
      for (var i = 0; i < 3; i++) {
        u = u.add(SessionUsage.ofTurn(
          // 2026-10-23 新口径：prompt 是**整段**（含命中）⇒ 900 ⊆ 1000，
          // 单轮命中率 90%（旧用例写 prompt:100 是"未命中部分"的旧口径）。
          cachedTokens: 900,
          promptTokens: 1000,
          outputTokens: 160,
          wallMs: 1724,
          requestedTool: i < 2,
        ));
      }
      // 运行级数据（真实墙钟）在循环外单独记
      u = u.add(const SessionUsage().copyRuns(1, taskWallMs: 48000));

      expect(u.turns, 3);
      expect(u.wallMs, 5172, reason: 'ΣTurnRecord.wallMs = 模型往返');
      expect(u.taskWallMs, 48000, reason: '任务总耗时是 run 级真实墙钟');
      // ★★ 这条就是用户的质疑被钉死的地方
      expect(u.taskWallMs, greaterThanOrEqualTo(u.wallMs),
          reason: '任务总耗时必须 ≥ 模型用时（后者是前者的子集）');
      // 若拿 wallMs 冒充任务耗时，会差一个数量级 —— 这正是用户察觉的"假"
      expect(u.wallMs * 5, lessThan(u.taskWallMs));
    });

    test('★ 没有 taskWallMs 的旧数据 → 0（UI 显示 —，不显示 0 秒）', () {
      final u = SessionUsage.ofTurn(
          cachedTokens: 1, promptTokens: 1, outputTokens: 1, wallMs: 1000);
      expect(u.taskWallMs, 0, reason: 'ofTurn 是逐轮的，拿不到运行级数据');
    });
  });

  // ==================================================================
  // 2. 三个命中率口径
  // ==================================================================

  group('命中率口径', () {
    /// 构造一组"三处都出现、且三个数互不相等"的样本。
    ///
    /// 口径说明（2026-10-23）：`prompt` = **整段**（含命中）⇒
    /// 单轮 = `cached / prompt`；累计加权 = `Σcached / Σprompt`。
    /// 下面的数字已按新口径取（旧口径 `cached/(cached+prompt)` 会把命中算两遍）。
    ///
    /// 关键：**同一个 run** 里
    /// · 单轮（第 2 轮）= 96%
    /// · 累计·加权（全部轮次）= 34%
    /// · 稳态·轮次平均（drop(1)）= 58%（只有一轮时它就是那一轮，看不出口径差异）
    /// ⇒ 为了证明"口径不同"，必须让 drop(1) 有**多轮**。
    test('★★ 累计加权 ≠ 单轮 ≠ 稳态轮次平均（三个口径，三个数）', () {
      // run 有 3 轮：
      //   轮1（冷启动）：cached=0,    prompt=1000  → 单轮 0%
      //   轮2：          cached=960,  prompt=1000  → 单轮 96%（整段口径）
      //   轮3：          cached=400,  prompt=2000  → 单轮 20%
      final turns = [
        const AgentTurn(
            index: 1, verdict: '', wallMs: 1000,
            cachedTokens: 0, promptTokens: 1000, outputTokens: 100),
        const AgentTurn(
            index: 2, verdict: '', wallMs: 1000,
            cachedTokens: 960, promptTokens: 1000, outputTokens: 100),
        const AgentTurn(
            index: 3, verdict: '', wallMs: 1000,
            cachedTokens: 400, promptTokens: 2000, outputTokens: 100),
      ];

      // ① 单轮口径（消息卡片那个）—— 第 2 轮
      final single = turns[1].metrics.hitRate!;
      expect(single, closeTo(0.96, 1e-9),
          reason: '单轮 = 960/1000（新口径：分母是整段输入，含命中）');

      // ② 累计·加权（标题圆圈 / 侧栏主标题）
      var acc = SessionUsage.empty;
      for (final t in turns) {
        acc = acc.add(SessionUsage.ofTurn(
          cachedTokens: t.cachedTokens,
          promptTokens: t.promptTokens,
          outputTokens: t.outputTokens,
          wallMs: t.wallMs,
        ));
      }
      // Σcached=1360, Σprompt=1000+1000+2000=4000 → 34%
      // （旧口径会算 1360/(1360+4000)=25.4% —— 分母把命中加了两遍，已废）
      expect(acc.hitRate, closeTo(0.34, 1e-9),
          reason: '累计加权只按 token 汇总，不认"各轮平均"');

      // ③ 稳态·轮次平均（跳过首轮）—— (96% + 20%) / 2 = 58%
      final steady = (0.96 + 0.20) / 2;
      expect(steady, closeTo(0.58, 1e-9));

      // ★★ 三个数**互不相等** —— 同名混淆的根源就在这里
      expect(single, isNot(closeTo(acc.hitRate!, 1e-6)),
          reason: '单轮 96% 与累计加权 34% 不是同一个数（用户看到 94 vs 96 就是这类差）');
      expect(steady, isNot(closeTo(acc.hitRate!, 1e-6)));
      expect(single, isNot(closeTo(steady, 1e-6)));
    });

    test('★ 标题圆圈用的就是累计·加权（不是单轮，也不是平均）', () {
      // 两轮：100% 与 0%（新口径：单轮 = cached/prompt），
      // 但把 token 量做成悬殊，加权就会被小轮拉走、与"各轮平均"拉开距离
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 1000, promptTokens: 1000, outputTokens: 0, wallMs: 0));
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 0, promptTokens: 100000, outputTokens: 0, wallMs: 0));
      // 加权：Σcached/Σprompt = 1000/101000 ≈ 0.99%；
      // 而"各轮命中率平均"是 (100% + 0%) / 2 = 50% —— 两个口径必须能分辨。
      expect(u.hitRate, closeTo(1000 / 101000, 1e-9));
      expect(u.hitRate, isNot(closeTo(0.5, 0.01)));
    });

    test('★★ 回归（2026-10-23 新口径）：真机 16128 / 16690 ⇒ 97%，且三项能加回来', () {
      // 用户原话：「未命中缓存16690，命中缓存16128，结果缓存命中率有97%？？」
      // 他按**侧栏标签**算是 49%，算术没错 —— 错的是旧标签：
      // 16,690 是**整段输入**（已含命中的 16,128），真正的未命中只有 562。
      //
      // 这组数来自真机侧栏（设备 e35e48c6，2026-10-23 14:08）。
      final u = SessionUsage(
        turns: 3,
        reportedTurns: 3,
        cachedTokens: 16128,
        reportedPromptTokens: 16690,
        outputTokens: 339,
      );

      // 命中率 = cached/整段输入 = 96.6% ⇒ 显示 97%（与侧栏主标题一致）
      expect(u.hitRate, closeTo(16128 / 16690, 1e-9));
      expect((u.hitRate! * 100).round(), 97);

      // ★ 旧口径已废：总输入 = cached + prompt 会把命中算两遍（32,818，虚高一倍）
      expect(u.totalInputTokens, 16690,
          reason: '整段输入就是 16,690，不是 cached + prompt');
      expect(u.totalInputTokens, isNot(16128 + 16690));
      // 未命中 = 整段 − 命中 = 562（这才是「· 未命中」那一行该显示的数）
      expect(u.uncachedInputTokens, 562);
      // ★ 用户能自己在侧栏上验算的等式：命中 + 未命中 == 整段输入
      expect(u.cachedTokens + u.uncachedInputTokens, u.totalInputTokens,
          reason: '三项必须自洽，否则用户一算就发现"标签在撒谎"');
    });

    test('★★ steadyHitRate 累计：只保留最近一次（比率不可相加）', () {
      var u = SessionUsage.empty;
      u = u.add(const SessionUsage().copyRuns(1, steadyHitRate: 0.91));
      expect(u.steadyHitRate, closeTo(0.91, 1e-9));
      // 第二次换成 0.86 —— 累加会算出 0.885（既不是加权也不是平均 ⇒ 假数）
      u = u.add(const SessionUsage().copyRuns(1, steadyHitRate: 0.86));
      expect(u.steadyHitRate, closeTo(0.86, 1e-9),
          reason: '比率不可相加，取最近一次');
      // 没有新值时保持原值（切会话不该丢已知的稳态数）
      u = u.add(const SessionUsage().copyRuns(1));
      expect(u.steadyHitRate, closeTo(0.86, 1e-9));
    });
  });

  // ==================================================================
  // 3. taskWallMs 在 AgentRunResult 里的解析
  // ==================================================================

  group('AgentRunResult.taskWallMs 解析', () {
    test('★ 新后端给了 → 解析出来', () {
      final r = AgentRunResult.fromMap(const {
        'stopReason': '已给出最终回答',
        'finalText': '好',
        'taskWallMs': 48321,
        'steadyHitRate': 0.94,
        'turns': [],
      });
      expect(r.taskWallMs, 48321);
      expect(r.steadyHitRate, closeTo(0.94, 1e-9));
    });

    test('★ 老后端没给 → 0（不是伪造一个数）', () {
      final r = AgentRunResult.fromMap(const {
        'stopReason': '已给出最终回答',
        'finalText': '好',
        'turns': [],
      });
      expect(r.taskWallMs, 0, reason: '缺失 ≠ 0 秒；UI 据 0 显示 —');
    });
  });

  // ==================================================================
  // 4. UI：口径标签 + 秒级格式
  // ==================================================================

  group('UI 口径与格式', () {
    Future<void> tallViewport(WidgetTester tester) async {
      tester.view.physicalSize = const Size(440, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Widget wrap(Widget child) => MaterialApp(
          theme: buildHeraclesTheme(),
          builder: (context, inner) => HueScope(
            hue: Hue.darkHue,
            child: inner ?? const SizedBox.shrink(),
          ),
          home: Scaffold(body: child),
        );

    /// 造一份"跑过一次"的用量：模型用时 5172ms、任务总耗时 48 秒。
    ///
    /// 口径（2026-10-23）：`promptTokens` = **整段**（含命中）⇒ 900/1000 = 90%。
    /// 稳态命中率刻意取 **86%**，与累计加权 **不同** —— 若两个数一样，
    /// 就证明不了"口径不同"，也测不出标签是否分开。
    SessionUsage oneRun() {
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
        cachedTokens: 900,
        promptTokens: 1000,
        outputTokens: 476,
        wallMs: 5172,
        requestedTool: true,
      ));
      return u.add(const SessionUsage()
          .copyRuns(1, taskWallMs: 48000, steadyHitRate: 0.86));
    }

    testWidgets('★★ 面板同时有「模型用时（不含工具）」与「任务总耗时」，且都是秒',
        (tester) async {
      await tallViewport(tester);
      await tester.pumpWidget(wrap(UsageSidebar(
        usage: oneRun(),
        contextUsage: const ContextUsage(
            frozenTokens: 100, conversationTokens: 200, limit: 1000000),
      )));
      await tester.pump();

      // ★ 旧标签「模型用时」改名 —— 用户正是把它当成任务总耗时质疑的
      expect(find.text('模型用时（不含工具）'), findsOneWidget);
      expect(find.text('任务总耗时'), findsOneWidget);
      // 5172ms → 5秒（不是 5172 ms，更不是 5172）
      expect(find.text('5秒'), findsOneWidget,
          reason: '模型用时 5172ms 必须显示为秒，用户明确要求');
      // 48000ms → 48秒
      expect(find.text('48秒'), findsOneWidget);
      // ★ 绝不能还有毫秒字样
      expect(find.textContaining('5172 ms'), findsNothing);
      expect(find.textContaining('5172毫秒'), findsNothing);
    });

    testWidgets('★★ 「任务总耗时」≥「模型用时」—— 界面上不能倒挂', (tester) async {
      await tallViewport(tester);
      final u = oneRun();
      expect(u.taskWallMs, greaterThan(u.wallMs),
          reason: '前提：数据本身就是 48s > 5.172s');
      await tester.pumpWidget(wrap(UsageSidebar(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 100, conversationTokens: 200, limit: 1000000),
      )));
      await tester.pump();

      // 两个数都在（同一屏能看到 ⇒ 用户能自己核对不会倒挂）
      expect(find.text('5秒'), findsOneWidget);
      expect(find.text('48秒'), findsOneWidget);
    });

    testWidgets('★★ 两个命中率各自带口径标签，不再都叫「缓存命中」', (tester) async {
      await tallViewport(tester);
      await tester.pumpWidget(wrap(UsageSidebar(
        usage: oneRun(),
        contextUsage: const ContextUsage(
            frozenTokens: 100, conversationTokens: 200, limit: 1000000),
      )));
      await tester.pump();

      // 主标题：累计·加权
      expect(find.text('缓存命中（累计·加权）'), findsOneWidget);
      // 新增一行：稳态（并写明是"最近一次·轮次平均"）
      expect(find.text('稳态命中率（最近一次·轮次平均）'), findsOneWidget);
      // ★★ 两个数**同时**在且**不相等** —— 用户看到的 94% vs 96% 正是这类差
      expect(find.text('90%'), findsOneWidget,
          reason: '累计·加权 = 900/1000（新口径：分母是整段输入）');
      expect(find.text('86%'), findsOneWidget, reason: '稳态·轮次平均（另一个口径）');
      expect(find.text('90%'), isNot(find.text('86%')));
      // ★ 2026-10-23：这条原来断言界面上有一段「口径不同」的说明文字 ——
      //   **已过期**：用户 2026-10-22 明确要求删掉这类解释性文字
      //   （「那些公式给我去掉，不是写给用户看的！！！」）。
      //   现在"口径"写在**标签本身**里（上面两条 label 断言钉住），
      //   不再单独画一段说明；README/KDoc 里才有口径细节。
      expect(find.textContaining('口径不同'), findsNothing,
          reason: '口径写在标签里即可，界面上不再放解释性小字');
    });

    testWidgets('★★ 侧栏五行自洽：输入（含缓存）= 命中 + 未命中；Token 用量 = 输入 + 输出',
        (tester) async {
      // 用户 2026-10-23 就是**自己按侧栏三个数算了一遍**才发现标签在撒谎：
      // 「未缓存输入 16690、缓存读取 16128 ⇒ 命中率 49%，怎么会显示 97%？」
      // ⇒ 新口径下 命中 + 未命中 必须等于整段输入，用户能当场验算；
      //   旧的「未缓存输入」「缓存读取」两行已删除（它们正是重复计数的来源）。
      await tallViewport(tester);
      await tester.pumpWidget(wrap(UsageSidebar(
        usage: oneRun(),
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
      )));
      await tester.pump();

      expect(find.text('输入（含缓存）'), findsOneWidget);
      expect(find.text('· 命中缓存'), findsOneWidget);
      expect(find.text('· 未命中'), findsOneWidget);
      // oneRun = cached 900 / prompt(整段) 1000 / output 476
      expect(find.text('1,000'), findsOneWidget, reason: '整段输入');
      expect(find.text('900'), findsOneWidget, reason: '命中缓存');
      expect(find.text('100'), findsOneWidget, reason: '未命中 = 1000 − 900');
      expect(find.text('476'), findsOneWidget, reason: '输出');
      expect(find.text('1,476'), findsOneWidget, reason: 'Token 用量 = 1000 + 476');
      // ★ 旧行名已删（2026-10-23）—— 它们把"整段输入"标成了"未缓存输入"
      expect(find.text('未缓存输入'), findsNothing);
      expect(find.text('缓存读取'), findsNothing);
    });

    testWidgets('★ 没有任务耗时数据时显示 —（不是「0秒」）', (tester) async {
      await tallViewport(tester);
      // 只有逐轮数据（旧后端 / 老 .jsonl）
      final u = SessionUsage.ofTurn(
          cachedTokens: 1, promptTokens: 1, outputTokens: 1, wallMs: 5172);
      await tester.pumpWidget(wrap(UsageSidebar(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
      )));
      await tester.pump();

      expect(find.text('任务总耗时'), findsOneWidget);
      expect(find.text('0秒'), findsNothing,
          reason: '没有数据 ≠ 0 秒（那会让人以为任务瞬间完成）');
    });

    testWidgets('★ 消息卡片：本轮耗时是秒 + 标「模型」+ 单轮命中率标「本轮」',
        (tester) async {
      await tester.pumpWidget(wrap(Scaffold(
        body: MessageRow(
          message: const HAssistantMessage(id: 'a1', text: '回答'),
          metrics: const TurnMetrics(
            cachedTokens: 960,
            // 2026-10-23 新口径：prompt = **整段**（含命中）⇒ 960/1000 = 96%。
            // （旧用例写 prompt:40 是"未命中部分"的旧口径 ⇒ 会算出 2400%）
            promptTokens: 1000,
            outputTokens: 476,
            wallMs: 5172,
          ),
        ),
      )));
      await tester.pump();
      // ★ 2026-10-23：图标名换成本项目真实存在的那个 ——
      //   Material `Icons.data_usage_rounded` 随 Cupertino 迁移已不存在，
      //   `AppIcons.usage` = `CupertinoIcons.chart_bar`（见 cupertino_kit.dart）。
      await tester.tap(find.byIcon(AppIcons.usage));
      await tester.pump();

      // ★ 秒级（用户要求）+ 「不含工具」口径
      expect(find.textContaining('模型耗时（不含工具）：5.2 秒'), findsOneWidget);
      expect(find.textContaining('5172 ms'), findsNothing);
      // ★ 单轮口径写明「本轮」—— 与侧栏累计命中率不再同名
      expect(find.textContaining('本轮缓存命中：96%'), findsOneWidget);
      expect(find.textContaining('输出：476 tokens'), findsOneWidget);
    });
  });

  // ==================================================================
  // 5. 输出 token：累计不被"只取最后一块"吃掉
  // ==================================================================

  group('输出 token 累计', () {
    test('★ 多轮 outputTokens 逐轮相加（不是取最后一块）', () {
      var u = SessionUsage.empty;
      for (final o in [100, 200, 176]) {
        u = u.add(SessionUsage.ofTurn(
            cachedTokens: 1, promptTokens: 1, outputTokens: o, wallMs: 10));
      }
      expect(u.outputTokens, 476,
          reason: '若只留最后一块会得到 176 —— 那看起来就像"输出太少"');
    });

    test('★ 输出速度用 Σout / Σ模型用时（不是任务耗时）', () {
      // 250 token / 1 秒 = 250 tok/s
      final u = SessionUsage.ofTurn(
          cachedTokens: 0, promptTokens: 0, outputTokens: 250, wallMs: 1000);
      expect(u.outputTokensPerSecond, closeTo(250.0, 1e-9),
          reason: '速度必须按模型用时算；用任务耗时会算出荒谬的低速');
    });
  });

  // ==================================================================
  // 6. 格式化边界（秒级）
  // ==================================================================

  group('耗时格式化', () {
    testWidgets('★ 小于 1 秒 → 「不到 1 秒」，不是「0秒」', (tester) async {
      tester.view.physicalSize = const Size(440, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final u = SessionUsage.empty
          .add(const SessionUsage().copyRuns(1, taskWallMs: 800));
      await tester.pumpWidget(MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: UsageSidebar(
            usage: u,
            contextUsage: const ContextUsage(
                frozenTokens: 0, conversationTokens: 0, limit: 4096),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('不到 1 秒'), findsOneWidget);
      expect(find.text('0秒'), findsNothing);
    });
  });
}
