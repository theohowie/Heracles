import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/screens/jev_settings_screen.dart';
import 'package:heracles/services/jev_service.dart';
import 'package:heracles/theme/app_theme.dart';

import 'support/secure_storage_mock.dart';

/// **JEV 设置页诊断展示回归测试**（task-5 第 7 条，2026-10-29）。
///
/// 只测 UI 侧展示（消费后端 B8 的 [JevDiagnostics] / [JevDecisionResult]）：
/// · 地址框下方**实时**「将请求：POST …」（值来自 `resolveEndpoint`，
///   页面不自己拼；裸域名上屏服务层 hint）；
/// · 结果区默认**一行结论**，「详情」折叠展开：请求 URL / HTTP 码 / 耗时 /
///   code / message / traceId / 原始响应体（>2KB 截断）+ 复制详情；
/// · traceId 始终展示（折叠态也看得到，缺失标「（无）」）；
/// · 422 / B8 hint 分三类文案（参数形状 / 上游限制 / 模型权限），
///   422 无 body 时三类都列出来；401/403/413/429 各自人话，不假装成功；
/// · 模型字段不是 `NeoHorse-Jev-4B` ⇒ 黄字；`modelCorrected` ⇒
///   「已按固定 ID 发送」；
/// · 「获取可用模型」成功但目录没有固定模型 ⇒ 提示可能没模型权限。
///
/// 注入点：页面的 `decideProbe` / `modelsProbe`（生产为 null，走
/// `JevCloudClient`；UI 自己不发 HTTP）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JevController jev;

  setUp(() async {
    installSecureStorageMock();
    SharedPreferences.setMockInitialValues({});
    jev = JevController.shared();
    jev.config = const JevConfig();
    jev.history = const [];
    jev.profile = null;
    jev.loaded = true;
    jev.busy = false;
    jev.lastError = null;
  });

  tearDown(removeSecureStorageMock);

  Widget wrap(Widget child) => MaterialApp(
    theme: buildHeraclesTheme(),
    builder: (context, inner) => HueScope(
      hue: Hue.darkHue,
      child: inner ?? const SizedBox.shrink(),
    ),
    home: child,
  );

  /// 诊断对象构造器 —— 形状**就是** B8 的 [JevDiagnostics]（编译器把关）。
  JevDiagnostics mkDiag({
    int? httpStatus,
    String resolvedEndpoint = 'https://tokenrhythm.studio/v1/decision',
    String? serverCode,
    String? serverMessage,
    String? traceId,
    String rawBody = '',
    int elapsedMs = 420,
    bool modelCorrected = false,
    String? hint,
    String? transportError,
  }) => JevDiagnostics(
    resolvedEndpoint: resolvedEndpoint,
    httpStatus: httpStatus,
    serverCode: serverCode,
    serverMessage: serverMessage,
    traceId: traceId,
    rawBody: rawBody,
    elapsedMs: elapsedMs,
    modelCorrected: modelCorrected,
    hint: hint,
    transportError: transportError,
  );

  JevDecideProbe failingProbe(JevDiagnostics d, {String? message}) => ({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String question,
  }) async {
    throw JevException(
      message ??
          '决策服务出错（HTTP ${d.httpStatus ?? '—'}）：'
              '${d.serverMessage ?? '平台拒绝'}',
      diagnostics: d,
    );
  };

  JevDecideProbe successProbe({
    double yesProb = 0.78,
    JevDiagnostics? diagnostics,
  }) => ({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String question,
  }) async => JevDecisionResult(
    yesProb: yesProb,
    thought: null,
    model: kJevDefaultModel,
    diagnostics: diagnostics ?? mkDiag(httpStatus: 200),
  );

  /// 高一点的测试窗口：结果区（尤其是展开后的详情）在首屏就能量到，
  /// 不用滚动 —— 断言的仍是同一棵树里的控件。
  Future<void> pumpScreen(
    WidgetTester tester, {
    JevDecideProbe? decide,
    JevModelsProbe? models,
  }) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      wrap(JevSettingsScreen(jev: jev, decideProbe: decide, modelsProbe: models)),
    );
    await tester.pump();
  }

  /// 点「测试连接」并等 probe 的结果渲染出来。
  Future<void> runTestConnection(WidgetTester tester) async {
    await tester.tap(find.text('测试连接'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> expandDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('jev-detail-toggle')));
    await tester.pump();
  }

  /// 排空毛玻璃 toast 的 2.2s 定时器（否则用例结束会报 pending timer）。
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  Text headlineText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('jev-outcome-headline')));

  group('地址框实时预览', () {
    testWidgets('「将请求：POST …」随输入实时变，值来自 resolveEndpoint', (tester) async {
      await pumpScreen(tester);
      // 预置地址：一进页就显示真实请求端点。
      expect(
        find.textContaining('将请求：POST https://tokenrhythm.studio/v1/decision'),
        findsOneWidget,
      );

      // 只填到 /v1 ⇒ 应用自动补推荐端点 /decision。
      await tester.enterText(
        find.byKey(const ValueKey('jev-url-field')),
        'https://tokenrhythm.studio/v1',
      );
      await tester.pump();
      expect(
        find.textContaining(
          '将请求：POST '
          '${JevCloudClient.resolveEndpoint('https://tokenrhythm.studio/v1').url}',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('将请求：POST https://tokenrhythm.studio/v1/decision'),
        findsOneWidget,
      );

      // 完整端点原样使用（不再补段）。
      await tester.enterText(
        find.byKey(const ValueKey('jev-url-field')),
        'https://tokenrhythm.studio/v1/decision',
      );
      await tester.pump();
      expect(
        find.textContaining('将请求：POST https://tokenrhythm.studio/v1/decision'),
        findsOneWidget,
      );

      // 裸域名 ⇒ 由服务层归一化（补推荐端点 + hint），页面只负责原样展示。
      // ⚠️ 2026-10-29 晚后端把「裸域名」规则从补 `/systemone` 改成按实测口径
      // 补 `/v1/decision`；这里不再硬编码历史端点，而是断言 **UI == 服务层结论**
      // （页面「不自己拼」这条不变量反而钉得更死）。
      final bare = JevCloudClient.resolveEndpoint('https://x.example');
      await tester.enterText(
        find.byKey(const ValueKey('jev-url-field')),
        'https://x.example',
      );
      await tester.pump();
      expect(
        find.textContaining('将请求：POST ${bare.url}'),
        findsOneWidget,
      );
      final bareHint = (bare.hint ?? '').trim();
      if (bareHint.isNotEmpty) {
        expect(
          find.textContaining(bareHint),
          findsOneWidget,
          reason: '服务层给了 hint，页面必须原样上屏（不静默）',
        );
      }

      // 清空 ⇒ 提示先填地址（不显示假的端点）。
      await tester.enterText(find.byKey(const ValueKey('jev-url-field')), '');
      await tester.pump();
      expect(find.textContaining('将请求：POST （先填接口地址）'), findsOneWidget);
    });

    testWidgets('帮助文案写清两种填法（完整端点 / 只填到 /v1）', (tester) async {
      await pumpScreen(tester);
      expect(find.textContaining('① 完整端点'), findsOneWidget);
      expect(find.textContaining('② 只填到'), findsOneWidget);
      expect(find.textContaining('自动补 /decision'), findsOneWidget);
    });
  });

  group('结果区：一行结论 + 可折叠详情', () {
    testWidgets('422（有 body）：默认一行结论，详情折叠后才出现技术字段', (tester) async {
      final d = mkDiag(
        httpStatus: 422,
        serverCode: 'invalid_questions',
        serverMessage: '参数形状不对：questions 必须是对象',
        traceId: 'tr-422-1',
        rawBody:
            '{"code":"invalid_questions","message":"参数形状不对",'
            '"traceId":"tr-422-1"}',
      );
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);

      // 默认只有一行结论（失败不画成成功，红字）。
      final head = headlineText(tester);
      expect(head.data, contains('连接失败（HTTP 422）'));
      expect(head.data, contains('参数形状不符合平台要求'));
      expect(head.style?.color, HColors.errorOn(true));
      expect(find.textContaining('连接成功'), findsNothing);

      // traceId 始终展示（折叠态也看得到）。
      expect(find.textContaining('traceId：tr-422-1'), findsOneWidget);

      // 详情默认折叠：技术字段都不在屏幕上。
      expect(find.textContaining('请求 URL：'), findsNothing);
      expect(find.textContaining('原始响应体：'), findsNothing);

      await expandDetails(tester);
      expect(
        find.textContaining(
          '请求 URL：https://tokenrhythm.studio/v1/decision',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('HTTP 码：422'), findsOneWidget);
      expect(find.textContaining('耗时：0.4 秒'), findsOneWidget);
      expect(find.textContaining('code：invalid_questions'), findsOneWidget);
      expect(find.textContaining('message：参数形状不对'), findsOneWidget);
      expect(find.textContaining('traceId：tr-422-1'), findsWidgets);
      expect(find.textContaining('原始响应体：'), findsOneWidget);
    });

    testWidgets('422（无 body）：三类原因都列出来，按参数形状兜底，traceId 标（无）不编造',
        (tester) async {
      // 真的「无 body」：serverCode/serverMessage/rawBody 全空 —— 平台文档里
      // 422 默认口径是参数/上游限制，无更具体证据时按参数形状兜底。
      final d = mkDiag(httpStatus: 422, rawBody: '');
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);

      // 一行结论也要落到具体分类，而不是只写「连接失败」。
      expect(headlineText(tester).data, contains('参数形状不符合平台要求'));
      expect(find.textContaining('参数形状不对：请求体要按文档'), findsOneWidget);

      // 三类文案（用户要求分三类，不能把 422 说成单一原因）。
      expect(find.byKey(const ValueKey('jev-422-categories')), findsOneWidget);
      expect(find.textContaining('① 参数形状'), findsOneWidget);
      expect(find.textContaining('② 上游限制'), findsOneWidget);
      expect(find.textContaining('③ 模型权限'), findsOneWidget);

      // traceId 没有就如实标「（无）」，也不编 HTTP 细节。
      expect(find.text('traceId：（无）'), findsOneWidget);

      await expandDetails(tester);
      expect(find.text('HTTP 码：422'), findsOneWidget);
      expect(find.text('原始响应体：（无）'), findsOneWidget);
      expect(find.text('traceId：（无）'), findsWidgets);
    });

    testWidgets('422 平台 message 指向上游 ⇒ 文案落在「上游限制」', (tester) async {
      final d = mkDiag(
        httpStatus: 422,
        serverCode: 'upstream_overloaded',
        serverMessage: '上游模型超时，请稍后重试',
        traceId: 'tr-up',
      );
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);
      expect(headlineText(tester).data, contains('上游限制'));
      expect(find.textContaining('上游限制：平台侧限流'), findsOneWidget);
      expect(find.textContaining('traceId：tr-up'), findsOneWidget);
    });

    testWidgets('422 平台 message 指向模型权限 ⇒ 文案落在「模型权限」', (tester) async {
      final d = mkDiag(
        httpStatus: 422,
        serverMessage: '账号没有该模型的权限',
        traceId: 'tr-perm',
      );
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);
      expect(headlineText(tester).data, contains('模型权限不足'));
      expect(
        find.textContaining('模型权限：账号可能没有 $kJevDefaultModel'),
        findsOneWidget,
      );
    });

    testWidgets('成功也显示 URL 与耗时（绿字，不误报失败）', (tester) async {
      final d = mkDiag(httpStatus: 200, elapsedMs: 1234);
      await pumpScreen(tester, decide: successProbe(diagnostics: d));
      await runTestConnection(tester);

      final head = headlineText(tester);
      expect(head.data, contains('连接成功'));
      expect(head.data, contains('置信度 78%'));
      expect(head.data, contains('耗时 1.2 秒'));
      expect(head.style?.color, HColors.successOn(true));

      await expandDetails(tester);
      expect(
        find.textContaining('请求 URL：https://tokenrhythm.studio/v1/decision'),
        findsOneWidget,
      );
      expect(find.textContaining('耗时：1.2 秒'), findsOneWidget);
      expect(find.textContaining('HTTP 码：200'), findsOneWidget);
    });

    testWidgets('401/403/413/429 各自人话，绝不假装成功', (tester) async {
      const cases = <int, String>{
        401: '密钥无效或未授权',
        403: '模型权限不足',
        413: '上游限制',
        429: '上游限制',
      };
      for (final entry in cases.entries) {
        final d = mkDiag(
          httpStatus: entry.key,
          traceId: 'tr-${entry.key}',
        );
        await pumpScreen(tester, decide: failingProbe(d));
        await runTestConnection(tester);
        final head = headlineText(tester);
        expect(
          head.data,
          contains('连接失败（HTTP ${entry.key}）'),
          reason: 'HTTP ${entry.key} 的结论行要带状态码',
        );
        expect(
          head.data,
          contains(entry.value),
          reason: 'HTTP ${entry.key} 要落到对应分类文案',
        );
        expect(head.style?.color, HColors.errorOn(true));
        expect(find.textContaining('连接成功'), findsNothing);
        expect(find.textContaining('traceId：tr-${entry.key}'), findsOneWidget);
      }
    });

    testWidgets('请求没发出（本地前置错误）不编 HTTP 码', (tester) async {
      await pumpScreen(tester);
      await tester.enterText(find.byKey(const ValueKey('jev-url-field')), '');
      await tester.pump();
      await tester.tap(find.text('测试连接'));
      await tester.pump();
      expect(find.byKey(const ValueKey('jev-test-preflight')), findsOneWidget);
      expect(find.byKey(const ValueKey('jev-outcome-headline')), findsNothing);
    });
  });

  group('模型固定 ID 与目录权限提示', () {
    testWidgets('模型不是 NeoHorse-Jev-4B ⇒ 黄字提示固定 ID', (tester) async {
      await pumpScreen(tester);
      // 初始是固定 ID：不提示。
      expect(find.byKey(const ValueKey('jev-model-fixed-warning')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('jev-model-field')),
        'gpt-4o',
      );
      await tester.pump();
      final warn = tester.widget<Text>(
        find.byKey(const ValueKey('jev-model-fixed-warning')),
      );
      expect(warn.data, contains('模型 ID 固定为 $kJevDefaultModel'));
      expect(warn.style?.color, HColors.warnOn(true));

      // 改回固定 ID ⇒ 提示消失。
      await tester.enterText(
        find.byKey(const ValueKey('jev-model-field')),
        kJevDefaultModel,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('jev-model-fixed-warning')), findsNothing);
    });

    testWidgets('B8 modelCorrected ⇒ 显示「已按固定 ID 发送」', (tester) async {
      final d = mkDiag(
        httpStatus: 422,
        serverMessage: '报文被拒绝',
        traceId: 'tr-corrected',
        modelCorrected: true,
      );
      await pumpScreen(tester, decide: failingProbe(d));
      await tester.enterText(
        find.byKey(const ValueKey('jev-model-field')),
        'some-other-model',
      );
      await tester.pump();
      await runTestConnection(tester);
      expect(find.text('已按固定 ID 发送'), findsOneWidget);
    });

    testWidgets('获取可用模型成功但目录没有固定模型 ⇒ 提示可能没模型权限', (tester) async {
      await pumpScreen(
        tester,
        models: ({
          required String baseUrl,
          required String apiKey,
        }) async => ['gpt-4o-mini', 'chat-model-x'],
      );
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();
      await drainToast(tester);

      final hint = tester.widget<Text>(
        find.byKey(const ValueKey('jev-catalog-hint')),
      );
      expect(hint.data, contains('目录里没有 $kJevDefaultModel'));
      expect(hint.data, contains('权限'));
      expect(hint.style?.color, HColors.warnOn(true));
      // 目录本身照实展示（不把「没有固定模型」说成空）。
      expect(find.text('chat-model-x'), findsOneWidget);
    });

    testWidgets('目录里有固定模型 ⇒ 不出现「没权限」提示', (tester) async {
      await pumpScreen(
        tester,
        models: ({
          required String baseUrl,
          required String apiKey,
        }) async => [kJevDefaultModel, 'chat-model-x'],
      );
      await tester.tap(find.text('获取可用模型'));
      await tester.pumpAndSettle();
      await drainToast(tester);
      expect(find.byKey(const ValueKey('jev-catalog-hint')), findsNothing);
      // 固定模型在目录里（chip 与模型输入框都带这个字符串）。
      expect(find.text(kJevDefaultModel), findsWidgets);
    });
  });

  group('原始响应体与复制详情', () {
    testWidgets('>2KB 原始响应体截断并显式标注（不把整段倒上屏）', (tester) async {
      final longBody = 'x' * 3000;
      final d = mkDiag(
        httpStatus: 422,
        serverMessage: '报文被拒绝',
        traceId: 'tr-long',
        rawBody: longBody,
      );
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);
      await expandDetails(tester);

      final trunc = tester.widget<Text>(
        find.byKey(const ValueKey('jev-raw-body-truncated')),
      );
      expect(trunc.data, contains('已截断'));
      expect(trunc.data, contains('3000'));
      final body = tester.widget<Text>(find.byKey(const ValueKey('jev-raw-body')));
      expect(body.data!.length, kJevRawBodyLimit);
      expect(body.data!.length, lessThan(longBody.length));
    });

    testWidgets('复制详情：拷到的是整份诊断（URL / traceId / 截断标记）', (tester) async {
      final longBody = 'x' * 3000;
      final d = mkDiag(
        httpStatus: 422,
        serverMessage: '报文被拒绝',
        traceId: 'tr-long',
        rawBody: longBody,
      );
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);
      await expandDetails(tester);

      // 走系统剪贴板（拦截平台通道）。
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.tap(find.byKey(const ValueKey('jev-copy-details')));
      await tester.pumpAndSettle();
      await drainToast(tester);

      expect(copied, isNotNull);
      expect(copied!, contains('请求 URL：'));
      expect(copied!, contains('traceId：tr-long'));
      expect(copied!, contains('已截断'));
      expect(copied!, contains('结论：连接失败（HTTP 422）'));
    });

    testWidgets('没有 body 时详情如实写「（无）」，不编内容', (tester) async {
      final d = mkDiag(httpStatus: 401, traceId: 'tr-no-body');
      await pumpScreen(tester, decide: failingProbe(d));
      await runTestConnection(tester);
      await expandDetails(tester);
      expect(find.text('原始响应体：（无）'), findsOneWidget);
    });
  });
}
