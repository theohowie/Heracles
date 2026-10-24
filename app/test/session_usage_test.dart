import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/session_usage.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/usage_sidebar.dart';

/// **会话用量累计的测试**（2026-10-11，t13；需求 `docs/24`）。
///
/// ## 本文件防的核心是这一条
///
/// > `cachedTokens == null` **不是 0**（契约 `02-契约规范.md` §3.4）
///
/// 这个坑本团队**踩过两次**（t2 把缺失的 `ok` 默认成 false；
/// t8 把"未执行"当成"成功"）。两次都是同一个病根：
/// **把"没有这个数据"当成了一个具体的值**。
///
/// 所以这里的断言是**行为性**的：
/// 未上报的轮次**不得**进入命中率的分子或分母，
/// 且必须被单独计数（UI 据此刻画"共 N 轮，M 轮未上报"）。
///
/// ## 另外两条
///
/// - 命中率按 **`:core` 的定义**：`Σcached / Σ(cached + prompt)`
///   （不是 `Σcached / Σprompt` —— 那会 >100%，见 `session_usage.dart` 的说明）
/// - 上下文分项是**估算**，UI 必须标 `~`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================================================================
  // 1. 累计核心：null 不参与
  // ==================================================================

  group('SessionUsage 累计', () {
    test('★ 单轮：已上报 → 进分子分母', () {
      final u = SessionUsage.ofTurn(
        // ★ 2026-10-23 语义：`promptTokens` = **整段**（含命中部分），
        //   所以 900 必须 ⊆ 1000。旧用例写的是 `prompt: 100`（= 未命中部分），
        //   那是 2026-10-23 之前的口径，已随 backend 规范化退场。
        cachedTokens: 900,
        promptTokens: 1000,
        outputTokens: 20,
        wallMs: 1000,
      );
      expect(u.reportedTurns, 1);
      expect(u.unreportedTurns, 0);
      expect(u.cachedTokens, 900);
      expect(u.reportedPromptTokens, 1000);
      expect(u.hasCacheData, isTrue);
      // 900 / 1000 = 90%（**分母是整段，不再加一次 cached**）
      expect(u.hitRate, closeTo(0.9, 1e-9));
    });

    test('★★ 单轮：cachedTokens == null → **绝不**当 0，且单独计数', () {
      final u = SessionUsage.ofTurn(
        cachedTokens: null, // provider 未上报
        promptTokens: 500,
        outputTokens: 20,
        wallMs: 1000,
      );

      expect(u.unreportedTurns, 1, reason: '未上报轮次必须被单独计数');
      expect(u.reportedTurns, 0);
      // ★★ 关键：不能把 null 累成 0
      expect(u.cachedTokens, 0);
      expect(u.reportedPromptTokens, 0,
          reason: '未上报轮次的 prompt 不能进分母 —— 那会稀释命中率');
      // 但要如实记下"这些输入确实花了"
      expect(u.unreportedPromptTokens, 500);

      expect(u.hasCacheData, isFalse);
      // ★★ 没有可用的缓存数据 → 命中率必须是 null（"不可用"），**不是 0.0**
      expect(u.hitRate, isNull,
          reason: '把不可用显示成 0% 会让用户以为缓存坏了（契约 §3.4）');
    });

    test('★★ 混合：未上报轮次**不稀释**命中率（分子分母都只用已上报的）', () {
      // 3 轮：2 轮上报（各 90%），1 轮未上报
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 900, promptTokens: 1000, outputTokens: 10, wallMs: 100));
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 900, promptTokens: 1000, outputTokens: 10, wallMs: 100));
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: null, promptTokens: 5000, outputTokens: 10, wallMs: 100));

      expect(u.turns, 3);
      expect(u.reportedTurns, 2);
      expect(u.unreportedTurns, 1);
      expect(u.hasUnreported, isTrue);

      // 3600 / 4000 = 90%（分子分母都只用**已上报**的两轮；分母是整段）
      //
      // 若错误地把未上报轮次的 5000 prompt 也算进分母，会得到
      // 3600/(4000+5000) = 40% —— **用户会以为缓存坏了**。
      expect(u.hitRate, closeTo(0.9, 1e-9),
          reason: '未上报轮次不得稀释命中率');

      // 而"输入量"要如实包含那 5000（那是真花掉的）
      //
      // 报告口径（2026-10-23 修正）：`totalInputTokens` = 已上报整段 + 未上报
      //   = (1000 + 1000) + 5000 = 7000。
      // ⚠️ 数值与旧口径（cached + prompt + unreported = 1800+200+5000）**恰好相同**，
      //    所以这条断言以前"看起来是对的"—— 但那是巧合，两套语义不同。
      expect(u.totalInputTokens, 1000 + 1000 + 5000);
      // 未命中 = 整段 − 命中（这才是侧栏「· 未命中」该显示的数）
      expect(u.uncachedInputTokens, 7000 - 1800);
    });

    test('★ 全部未上报 → hitRate 为 null（不是 0）', () {
      var u = SessionUsage.empty;
      for (var i = 0; i < 3; i++) {
        u = u.add(SessionUsage.ofTurn(
            cachedTokens: null,
            promptTokens: 100,
            outputTokens: 5,
            wallMs: 50));
      }
      expect(u.turns, 3);
      expect(u.unreportedTurns, 3);
      expect(u.hasCacheData, isFalse);
      expect(u.hitRate, isNull);
      expect(u.totalInputTokens, 300);
    });

    test('★ 命中率是**加权**的：大轮次权重大', () {
      // 小轮 100% 命中（1000 token 里命中 1000），大轮 0% 命中（100000 token）
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 1000, promptTokens: 1000, outputTokens: 0, wallMs: 0));
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 0, promptTokens: 100000, outputTokens: 0, wallMs: 0));

      // 加权：1000 / 101000 ≈ 0.99%
      expect(u.hitRate, closeTo(1000 / 101000, 1e-9));
      // 若按"各轮命中率取平均"会得到 50% —— 与"整体省了多少"的直觉不符
      expect(u.hitRate, isNot(closeTo(0.5, 0.01)));
    });

    test('★★ 回归：用户那组真机数字必须自洽（16128 / 16690 ⇒ 97%）', () {
      // 用户原话：「未命中缓存16690，命中缓存16128，结果缓存命中率有97%？？」
      //
      // 他按**侧栏标签**算是 49%，是对的算术、错的标签：
      // 16,690 是**整段输入**（已含命中的 16,128），真正的未命中是 562。
      //
      // 这组数来自真机侧栏（设备 e35e48c6，2026-10-23 14:08）。
      final u = SessionUsage(
        turns: 3,
        reportedTurns: 3,
        cachedTokens: 16128,
        reportedPromptTokens: 16690,
        outputTokens: 339,
      );

      // 命中率按**整段**做分母 ⇒ 96.6% ⇒ 显示 97%（与侧栏主标题一致）
      expect(u.hitRate, closeTo(16128 / 16690, 1e-9));
      expect((u.hitRate! * 100).round(), 97);

      // 三项必须能**加回来**（这是这组回归的核心：数字自洽）
      expect(u.uncachedInputTokens, 562, reason: '16690 − 16128');
      expect(
        u.cachedTokens + u.uncachedInputTokens,
        u.totalInputTokens,
        reason: '命中 + 未命中 必须等于整段输入',
      );
      expect(u.totalInputTokens, 16690,
          reason: '★ 不能是 cached + prompt（那会得到 32818，虚高一倍）');
    });

    test('★ 步数只统计"请求了工具"的轮次', () {
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 1,
          promptTokens: 1,
          outputTokens: 1,
          wallMs: 1,
          requestedTool: true));
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 1,
          promptTokens: 1,
          outputTokens: 1,
          wallMs: 1,
          requestedTool: false)); // 纯最终回答那一轮
      expect(u.turns, 2);
      expect(u.steps, 1);
    });

    test('★ 输出速度由 Σout / Σwall 推出；无墙钟时为 null', () {
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 0, promptTokens: 0, outputTokens: 250, wallMs: 1000));
      expect(u.outputTokensPerSecond, closeTo(250.0, 1e-9));

      // 没有墙钟 → null（而不是 Infinity）
      final zero = SessionUsage.ofTurn(
          cachedTokens: 0, promptTokens: 0, outputTokens: 100, wallMs: 0);
      expect(zero.outputTokensPerSecond, isNull);
    });

    test('★ copyRuns 只改 runs（逐轮累加与"每次运行+1"粒度不同）', () {
      final t = SessionUsage.ofTurn(
          cachedTokens: 1, promptTokens: 1, outputTokens: 1, wallMs: 1);
      final withRun = t.add(const SessionUsage().copyRuns(1));
      expect(withRun.runs, 1);
      expect(withRun.turns, 1, reason: 'copyRuns 不该动 turns');
      expect(withRun.cachedTokens, 1);
    });
  });

  // ==================================================================
  // 2. 上下文占用
  // ==================================================================

  group('ContextUsage', () {
    test('★ 合计与比例', () {
      const c = ContextUsage(frozenTokens: 5200, conversationTokens: 383000, limit: 1000000);
      expect(c.used, 388200);
      expect(c.ratio, closeTo(0.3882, 1e-9));
      expect(c.overLimit, isFalse);
    });

    test('★ 上限未知 → ratio 为 null（不画假进度条）', () {
      const c = ContextUsage(frozenTokens: 100, conversationTokens: 200, limit: -1);
      expect(c.ratio, isNull);
      expect(c.overLimit, isFalse, reason: '上限未知时不能说"超限"');
    });

    test('★ 超出上限能被识别（UI 据此示警）', () {
      const c = ContextUsage(frozenTokens: 5000, conversationTokens: 9000, limit: 10000);
      expect(c.used, 14000);
      expect(c.overLimit, isTrue);
      expect(c.ratio, greaterThan(1.0));
    });
  });

  // ==================================================================
  // 3. 估算与格式化（与 TextMath 同系数）
  // ==================================================================

  group('估算与格式化', () {
    test('★ 中文按 0.7 token/字（与 TextMath 系数一致）', () {
      // 10 个 CJK 字 → 10*7~/10 = 7
      expect(estimateTokens('你好世界一二三四五六'), 7);
    });

    test('★ 空串 → 0', () {
      expect(estimateTokens(''), 0);
    });

    test('★ 紧凑格式（参考图是 ~516K 这种写法）', () {
      expect(formatTokensCompact(0), '0');
      expect(formatTokensCompact(999), '999');
      expect(formatTokensCompact(1000), '1.0K');
      expect(formatTokensCompact(516000), '516.0K');
      expect(formatTokensCompact(1200000), '1.2M');
    });

    test('★ 精确格式带千分位', () {
      expect(formatTokensFull(0), '0');
      expect(formatTokensFull(999), '999');
      expect(formatTokensFull(1000), '1,000');
      expect(formatTokensFull(770982124), '770,982,124');
    });
  });

  // ==================================================================
  // 4. UI：null 必须显示「不可用」，且标注未上报轮次
  // ==================================================================

  group('UI 呈现', () {
    /// 把测试视口调成**足够高** —— 边栏正文是 `ListView`（**惰性构建**），
    /// 默认 800×600 装不下三组内容，底部的会话统计根本不会被创建。
    ///
    /// ⚠️ 这与 t11 踩过的是**同一个坑**：断言前必须保证目标在视口内，
    /// 否则得到的是"测试的假失败"，不是产品缺陷。
    /// 真机高度约 900dp，这里给足冗余。
    Future<void> tallViewport(WidgetTester tester) async {
      tester.view.physicalSize = const Size(440, 1800);
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

    testWidgets('★★ cachedTokens 全为 null → 显示「不可用」，**不显示 0%**',
        (tester) async {
      await tallViewport(tester);
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: null, promptTokens: 500, outputTokens: 20, wallMs: 100));

      await tester.pumpWidget(wrap(UsageSidebar(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 100, conversationTokens: 200, limit: 4096),
      )));
      await tester.pump();

      expect(find.text('不可用'), findsOneWidget);
      // ★★ 核心：绝不能出现「0%」—— 那会让用户以为缓存坏了
      expect(find.text('0%'), findsNothing,
          reason: '把 null 显示成 0% 正是契约 §3.4 明令禁止的');
      expect(find.textContaining('不是 0%'), findsOneWidget);
    });

    testWidgets('★★ 有未上报轮次 → 必须标注分母（共 N 轮 / M 轮未上报）',
        (tester) async {
      await tallViewport(tester);
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 900, promptTokens: 1000, outputTokens: 10, wallMs: 100));
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: null, promptTokens: 500, outputTokens: 10, wallMs: 100));

      await tester.pumpWidget(wrap(UsageSidebar(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 100, conversationTokens: 200, limit: 4096),
      )));
      await tester.pump();

      // 命中率按已上报的算：900/1000 = 90%
      expect(find.text('90%'), findsOneWidget);
      // ★★ 必须说明分母，否则用户以为被少算了
      expect(find.textContaining('共 2 轮'), findsOneWidget);
      expect(find.textContaining('1 轮未上报'), findsOneWidget);
    });

    testWidgets('★ 上下文分项标 `~`（估算，不是真实 tokenizer）', (tester) async {
      await tallViewport(tester);
      await tester.pumpWidget(wrap(const UsageSidebar(
        usage: SessionUsage.empty,
        contextUsage: ContextUsage(
            frozenTokens: 5200, conversationTokens: 383000, limit: 1000000),
      )));
      await tester.pump();

      expect(find.text('上下文已用'), findsOneWidget);
      // 总量与两个分项都必须带 `~`
      expect(find.textContaining('~388.2K'), findsOneWidget);
      expect(find.text('~5.2K'), findsOneWidget);
      expect(find.text('~383.0K'), findsOneWidget);
      // ★ 2026-10-23：这里原来断言界面上有「估算值」三个字 —— **已过期**。
      //   2026-10-22 用户明确要求删掉这类解释性小字：
      //   「那些公式给我去掉，不是写给用户看的！！！」
      //   ⇒ 估算的标记方式就是数字前的 `~`（下面这条断言把它钉住），
      //     而不是再写一句"这是估算"。口径说明留在 `usage_sidebar.dart` 的 KDoc。
      expect(
        find.textContaining('~'),
        findsWidgets,
        reason: '★ `~` 是"估算值"的唯一界面标记（解释性文字已被用户要求删除）',
      );
      expect(find.textContaining('估算值'), findsNothing,
          reason: '用户要求：不要把这些口径说明画到界面上');
      // 进度条存在
      //
      // ★ 2026-10-23：这条原来断言 `LinearProgressIndicator` —— **已过期**。
      //   Material → Cupertino 迁移后，进度条换成了自绘的
      //   `CupertinoLinearActivityIndicator`（`theme/cupertino_kit.dart`），
      //   Material 控件在这个 App 里已经一个都不剩。
      expect(find.byType(CupertinoLinearActivityIndicator), findsOneWidget);
    });

    testWidgets('★ 三组标题都在（Token 用量 / 上下文已用 / 会话统计）',
        (tester) async {
      await tallViewport(tester);
      await tester.pumpWidget(wrap(const UsageSidebar(
        usage: SessionUsage.empty,
        contextUsage: ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
      )));
      await tester.pump();

      // 「Token 用量」出现两次：组标题 + 第一行（"Token 用量 123"）——
      // 与参考图一致（`docs/24` §2.2 第一行也叫 Token 用量），
      // 所以这里断 `findsWidgets` 而不是 `findsOneWidget`。
      expect(find.text('Token 用量'), findsWidgets);
      expect(find.text('上下文已用'), findsOneWidget);
      expect(find.text('会话统计'), findsOneWidget);
    });

    testWidgets('★ 开发者用的「待二期埋点」说明已删除（用户界面不留开发笔记）',
        (tester) async {
      await tallViewport(tester);
      await tester.pumpWidget(wrap(const UsageSidebar(
        usage: SessionUsage.empty,
        contextUsage: ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
      )));
      await tester.pump();

      // 用户要求（2026-10-19）：删掉给开发者看的小字
      expect(find.text('待二期埋点'), findsNothing,
          reason: '「待二期埋点」是开发计划，不该出现在用户界面');
      expect(find.textContaining('TTFT'), findsNothing);
      expect(find.textContaining('本期不做'), findsNothing);
    });

    testWidgets('★ 超出上限时明确示警（不只是把进度条画满）', (tester) async {
      await tallViewport(tester);
      await tester.pumpWidget(wrap(const UsageSidebar(
        usage: SessionUsage.empty,
        contextUsage: ContextUsage(
            frozenTokens: 5000, conversationTokens: 9000, limit: 10000),
      )));
      await tester.pump();

      expect(find.textContaining('已超出上下文上限'), findsOneWidget);
    });
  });

  // ==================================================================
  // 5. 标题栏指示器
  // ==================================================================

  group('UsageIndicator', () {
    Widget wrap(Widget child) => MaterialApp(
          theme: buildHeraclesTheme(),
          builder: (context, inner) => HueScope(
            hue: Hue.darkHue,
            child: inner ?? const SizedBox.shrink(),
          ),
          home: Scaffold(appBar: AppBar(actions: [child])),
        );

    testWidgets('★★ 命中率**常驻可见**（上限已知时也要在）', (tester) async {
      // ★ 这条防的是我自己第一版的错：当时"占比优先"，于是**上限已知时
      //   命中率就消失了** —— 而用户原话第一句就是要在固定位置看到命中率。
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 900, promptTokens: 1000, outputTokens: 10, wallMs: 100));

      await tester.pumpWidget(wrap(UsageIndicator(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 520000, limit: 1000000),
        onTap: () {},
      )));
      await tester.pump();

      // 两个数**同时**在：命中率 90% 与上下文占比 52%
      expect(find.text('90%'), findsOneWidget, reason: '命中率必须常驻');
      expect(find.text('52%'), findsOneWidget, reason: '上下文占比也要在');
    });

    testWidgets('★ 无上限时命中率仍在', (tester) async {
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: 900, promptTokens: 1000, outputTokens: 10, wallMs: 100));
      await tester.pumpWidget(wrap(UsageIndicator(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: -1),
        onTap: () {},
      )));
      await tester.pump();
      expect(find.text('90%'), findsOneWidget);
      // 上限未知 → 上下文那格显示 —（而不是假数）
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('★★ 命中率不可用时显示 —，绝不显示 0%', (tester) async {
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: null, promptTokens: 500, outputTokens: 10, wallMs: 100));
      await tester.pumpWidget(wrap(UsageIndicator(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
        onTap: () {},
      )));
      await tester.pump();

      // ⚠️ 不能笼统地 `find.text('0%') findsNothing` —— 指示器有**两个**数，
      //    上下文那格显示 `0%` 是**如实的**（确实一点没用）。
      //    要禁的是**命中率**那格显示 0%。所以按槽位断言。
      final nums = tester
          .widgetList<Text>(find.descendant(
            of: find.byType(UsageIndicator),
            matching: find.byType(Text),
          ))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => s.endsWith('%') || s == '—')
          .toList();

      expect(nums.first, '—',
          reason: '命中率不可用必须显示 —（null 不是 0 —— 契约 §3.4）');
      expect(nums.first, isNot('0%'));
      expect(nums.last, '0%', reason: '上下文确实 0% 已用 —— 这个 0 是如实的');
    });

    testWidgets('★ 有未上报轮次时带 `*` 标记', (tester) async {
      var u = SessionUsage.empty;
      u = u.add(SessionUsage.ofTurn(
          cachedTokens: null, promptTokens: 500, outputTokens: 10, wallMs: 100));
      await tester.pumpWidget(wrap(UsageIndicator(
        usage: u,
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
        onTap: () {},
      )));
      await tester.pump();
      expect(find.text('*'), findsOneWidget);
    });

    testWidgets('★ 点击会触发回调（打开边栏）', (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(UsageIndicator(
        usage: SessionUsage.empty,
        contextUsage: const ContextUsage(
            frozenTokens: 0, conversationTokens: 0, limit: 4096),
        onTap: () => tapped = true,
      )));
      await tester.pump();
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  // 保留：确保设置控制器在测试环境可加载（与本文件其它断言无关，
  // 只是防止 `shared_preferences` 未初始化的偶发失败）
  test('设置控制器可加载（测试环境前置）', () async {
    SharedPreferences.setMockInitialValues({});
    final c = await SettingsController.load();
    expect(c.value.stepDetail, isNotNull);
  });
}
