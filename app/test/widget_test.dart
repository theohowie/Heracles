import 'dart:convert';
import 'package:flutter/cupertino.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';

import 'support/secure_storage_mock.dart';

Future<SettingsController> _freshController() async {
  SharedPreferences.setMockInitialValues({});
  return SettingsController.load();
}

Widget _wrap(SettingsController c, Widget child) => MaterialApp(
      theme: buildHeraclesTheme(),
      // HueScope 必须挂载 —— 组件通过它读主题语义色。
      // 生产环境由 MaterialApp.builder 注入（见 main.dart）。
      builder: (context, inner) => HueScope(
        hue: Hue.darkHue,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: child,
    );

void main() {
  // ★ 安全存储通道 mock（2026-10-18，F1c）——
  //   本文件里 `SettingsController.load()` 被大量使用（`_freshController()`），
  //   不装这个 handler 的话那些用例会**永久卡死**在本机（不是报错，
  //   是 Future 永不完成）。详见 `test/support/secure_storage_mock.dart`。
  //
  // ★★ 实测（2026-10-18）：装上它本文件由"卡在**第 1 个**用例"变成
  //    **15/15 全绿**，**包括**开头那几条"打开 ChatScreen"的用例 ——
  //    因为 `ChatScreen` 自己也会 `await SettingsController.load()`。
  //    对照实验：注释掉这两行后单跑 `首屏在无工作区时引导用户选择文件夹`
  //    → **卡死**。所以那条老坑在本文件里的触发点就是本 mock 修的东西。
  //    ⚠️ 但这**不代表**"所有 ChatScreen 卡首帧都归因于它" ——
  //    本机是否还有别的触发路径（`实测-03` 坑 35）**未验证**。
  setUp(installSecureStorageMock);
  tearDown(removeSecureStorageMock);

  // ---------------------------------------------------------- 主屏

  testWidgets('首屏在无工作区时引导用户选择文件夹', (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(_wrap(c, ChatScreen(settings: c)));
    // 不用 pumpAndSettle：测试里 loading 动画会一直转
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 测试环境没有 Kotlin 桥 → 工作区列表为空
    // 必须**引导用户去选文件夹**，而不是显示假数据或空白
    expect(find.textContaining('工作区'), findsWidgets);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('输入后出现用户消息（真实运行会因无工作区而报错）', (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(_wrap(c, ChatScreen(settings: c)));

    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(CupertinoTextField), '创建 hello.py');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(milliseconds: 100));

    // 用户消息立即可见 —— 这一步不依赖 Kotlin
    expect(find.text('创建 hello.py'), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('没有工作区时发送不会崩溃', (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(_wrap(c, ChatScreen(settings: c)));

    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(CupertinoTextField), '你好');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump(const Duration(milliseconds: 200));

    // 应用仍然活着
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  // ---------------------------------------------------------- 缓存指标

  test('缓存指标未上报时命中率为 null（不是 0）', () {
    const m = TurnMetrics(
      cachedTokens: null,
      promptTokens: 100,
      outputTokens: 10,
      wallMs: 500,
    );
    expect(m.hitRate, isNull,
        reason: '未上报必须为 null —— 0 会误报缓存坏了（02-契约规范.md 3.4）');
  });

  test('缓存指标正常计算命中率（2026-10-23 口径：promptTokens=整段）', () {
    // 口径：promptTokens 含命中部分（backend 2026-10-23 规范化），
    // hitRate = cached / prompt —— 不再把 cached 加进分母（那会双重计入）。
    const m = TurnMetrics(
      cachedTokens: 1024,
      promptTokens: 1247, // 整段 = 命中 1024 + 未命中 223
      outputTokens: 49,
      wallMs: 1001,
    );
    expect(m.hitRate, closeTo(1024 / 1247, 0.0001));
  });

  // ---------------------------------------------------------- 设置：功能而非界面

  test('默认权限是「工作区内修改」，不是完全访问', () {
    const s = AppSettings();
    expect(s.permission, PermissionMode.workspaceAuto);
    expect(s.permission.requiresElevation, isFalse);
  });

  test('只有「完全访问」需要 Shizuku 或 root', () {
    expect(PermissionMode.fullAccess.requiresElevation, isTrue);
    expect(PermissionMode.manual.requiresElevation, isFalse);
    expect(PermissionMode.workspaceAuto.requiresElevation, isFalse);
  });

  test('工作步骤展示影响参数与结果的可见性', () {
    expect(StepDetail.minimal.showArgs, isFalse);
    expect(StepDetail.standard.showArgs, isTrue);
    expect(StepDetail.standard.fullResult, isFalse);
    expect(StepDetail.detailed.fullResult, isTrue);
  });

  test('字号被限制在 12–20', () async {
    final c = await _freshController();
    await c.setFontSize(100);
    expect(c.value.fontSize, 20);
    await c.setFontSize(1);
    expect(c.value.fontSize, 12);
  });

  test('★ 设置必须持久化 —— 重启后不能回到默认值', () async {
    SharedPreferences.setMockInitialValues({});
    final c1 = await SettingsController.load();
    await c1.setPermission(PermissionMode.fullAccess);
    await c1.setAccentHex(0xFF22C55E);
    await c1.setFontSize(18);

    // 模拟重启：重新 load
    final c2 = await SettingsController.load();
    expect(c2.value.permission, PermissionMode.fullAccess);
    expect(c2.value.accentHex, 0xFF22C55E);
    expect(c2.value.fontSize, 18);
  });

  test('提供商配置会被保存并可读回', () async {
    final c = await _freshController();
    final p = c.value.providers.first;
    await c.updateProvider(p.copyWith(apiKey: 'sk-test', model: 'deepseek-chat'));

    final c2 = await SettingsController.load();
    final loaded = c2.value.providers.firstWhere((e) => e.id == p.id);
    expect(loaded.apiKey, 'sk-test');
    expect(loaded.isConfigured, isTrue);
    expect(loaded.enabled, isTrue, reason: '填了 Key 之后必须可用');
  });

  test('添加与删除提供商', () async {
    final c = await _freshController();
    final before = c.value.providers.length;

    await c.addProvider(const ModelProviderConfig(
      id: 'p-x',
      name: '自建',
      baseUrl: 'http://localhost:8000/v1',
      model: 'm',
    ));
    expect(c.value.providers.length, before + 1);

    await c.removeProvider('p-x');
    expect(c.value.providers.length, before);
  });

  test('设置存储损坏时回退到默认值，不让 App 起不来', () async {
    SharedPreferences.setMockInitialValues({'providers': '这不是 JSON'});
    final c = await SettingsController.load();
    expect(c.value.providers, isNotEmpty);
  });

  // ---------------------------------------------------------- 本地模型清理

  Map<String, dynamic> providerJson({
    required String id,
    required String name,
    required String baseUrl,
    required String model,
  }) =>
      {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        'enabled': true,
        'isDefault': false,
        'modelCatalog': <String>[],
        'protocol': 'openaiChat',
        'contextLength': 0,
        'modelCapabilities': <String, dynamic>{},
      };

  test('★★ 已废弃的本地模型 provider 在启动时被清掉（ADR-035 收尾）', () async {
    SharedPreferences.setMockInitialValues({
      'providers': jsonEncode([
        providerJson(
          id: 'local',
          name: '本地模型 (llama.cpp)',
          baseUrl: 'http://127.0.0.1:8080',
          model: 'qwen3.5-4b',
        ),
      ]),
      'activeProviderId': 'local',
    });

    final c = await SettingsController.load();

    expect(c.value.providers.any((p) => p.id == 'local'), isFalse,
        reason: '本地模型配置必须被清掉 —— 选中它只会撞「本地后端已删除」的装配期异常');
    expect(c.value.activeProviderId, isNull,
        reason: '指向已删 provider 的选择必须一起清掉，否则界面上是个悬空选择');
    expect(c.value.providers, isNotEmpty,
        reason: '清空之后要回落到默认 provider 列表（不能让用户没模型可用）');
  });

  test('★ 局域网自建端点不算「本地模型」—— 不得误删', () async {
    SharedPreferences.setMockInitialValues({
      'providers': jsonEncode([
        providerJson(
          id: 'p-lan',
          name: '电脑上的 llama.cpp',
          baseUrl: 'http://192.168.1.10:8090/v1',
          model: 'qwen-3.5-4B',
        ),
      ]),
    });

    final c = await SettingsController.load();

    expect(c.value.providers.any((p) => p.id == 'p-lan'), isTrue,
        reason: '局域网/自建端点不是手机本地模型，用户可能真的在用，删了就是误伤');
  });

  // ---------------------------------------------------------- 设置页

  testWidgets('设置页显示三个主要分类', (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(_wrap(c, SettingsScreen(controller: c)));

    expect(find.text('通用设置'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    // 「外观」在应用组 —— 滚到可见再断言（ListView 惰性构建，
    // 屏外条目不存在于树里）。
    await tester.scrollUntilVisible(find.text('外观'), 120);
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsOneWidget);
  });

  testWidgets('权限档位描述会被展示', (tester) async {
    final c = await _freshController();
    await tester.pumpWidget(_wrap(c, SettingsScreen(controller: c)));
    await tester.tap(find.text('通用设置'));
    await tester.pumpAndSettle();

    // 默认权限在通用页页尾的「权限」组（原型六行之后）—— 滚到可见再断言
    await tester.scrollUntilVisible(find.text('新会话的默认权限'), 120);
    await tester.pumpAndSettle();
    expect(find.text('新会话的默认权限'), findsOneWidget);
  });
}
