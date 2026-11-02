// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 沙箱环境区**（2026-11-02，对应 #3/T0）—— 真实 API + 诚实降级。
//
// 钉住：成功/失败/未校验版本、container 档位未实现、高风险文案原样、
// 通道未实现降级、项目认不出。断言抓缺陷（不是"有文字就算过"）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/services/sandbox_service.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/sandbox_env_section.dart';

class _FakeSandbox extends SandboxService {
  _FakeSandbox({
    required this.profile,
    this.throwOnProfile = false,
    this.installResults = const <String, SandboxEnvInstallResult>{},
  });

  SandboxEnvProfile profile;
  final bool throwOnProfile;
  final Map<String, SandboxEnvInstallResult> installResults;

  @override
  Future<SandboxEnvProfile> envProfile() async {
    if (throwOnProfile) {
      throw Exception('未知方法 envProfile');
    }
    return profile;
  }

  @override
  Future<SandboxEnvInstallResult> installEnv(String name) async {
    final r = installResults[name];
    if (r != null && r.ok) {
      profile = SandboxEnvProfile(
        isolationTier: profile.isolationTier,
        tierImplemented: profile.tierImplemented,
        tierNote: profile.tierNote,
        whitelistOnly: profile.whitelistOnly,
        allowAllOutbound: profile.allowAllOutbound,
        riskLevel: profile.riskLevel,
        riskNote: profile.riskNote,
        hosts: profile.hosts,
        proxy: profile.proxy,
        envs: <String>[...profile.envs, name],
      );
    }
    return r ?? const SandboxEnvInstallResult(ok: false, error: '未配置结果');
  }

  @override
  Future<SandboxEnvInstallResult> uninstallEnv(String name) async {
    profile = SandboxEnvProfile(
      isolationTier: profile.isolationTier,
      tierImplemented: profile.tierImplemented,
      tierNote: profile.tierNote,
      whitelistOnly: profile.whitelistOnly,
      allowAllOutbound: profile.allowAllOutbound,
      riskLevel: profile.riskLevel,
      riskNote: profile.riskNote,
      hosts: profile.hosts,
      proxy: profile.proxy,
      envs: profile.envs.where((e) => e != name).toList(),
    );
    return const SandboxEnvInstallResult(ok: true, name: 'x');
  }

  @override
  Future<List<String>> detectProjectEnv(List<String> fileNames) async =>
      const <String>[];
}

SandboxEnvProfile _profile({
  String tier = 'process',
  bool implemented = true,
  String? tierNote,
  bool allowAll = false,
  String risk = 'low',
  String riskNote = '强制力为策略级（代理环境变量 + 包管理器配置 + DNS 约束），非硬隔离',
  List<String> envs = const <String>[],
}) =>
    SandboxEnvProfile(
      isolationTier: tier,
      tierImplemented: implemented,
      tierNote: tierNote,
      whitelistOnly: !allowAll,
      allowAllOutbound: allowAll,
      riskLevel: risk,
      riskNote: riskNote,
      hosts: const <String>['registry.npmjs.org', 'pypi.org'],
      proxy: 'http://127.0.0.1:8899',
      envs: envs,
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: buildHeraclesTheme(),
      builder: (context, inner) => HueScope(
        hue: Hue.darkHue,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('★★ 安装成功：走真实结果 + 版本校验 + 重查清单', (tester) async {
    final fake = _FakeSandbox(
      profile: _profile(envs: const <String>['node']),
      installResults: const <String, SandboxEnvInstallResult>{
        'python3': SandboxEnvInstallResult(
          ok: true,
          name: 'python3',
          approxBytes: 60 * 1024 * 1024,
          verifiedVersion: '3.12.1',
        ),
      },
    );
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    expect(find.text('已实现（L1 进程级）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sandbox-env-python3-action')));
    await tester.pumpAndSettle();

    final note = tester.widget<Text>(
        find.byKey(const Key('sandbox-env-python3-note')));
    expect(note.data, contains('已安装'));
    expect(note.data, contains('版本 3.12.1'));
    expect(note.data, contains('60 MB'));
    // 重查后状态变已安装
    final status = tester.widget<Text>(
        find.byKey(const Key('sandbox-env-python3-status')));
    expect(status.data, '已安装');
  });

  testWidgets('★★ 安装失败：显示 error 人话，绝不显示成功', (tester) async {
    final fake = _FakeSandbox(
      profile: _profile(),
      installResults: const <String, SandboxEnvInstallResult>{
        'go': SandboxEnvInstallResult(
          ok: false,
          name: 'go',
          error: '下载失败：网络不可达（可重试）',
        ),
      },
    );
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sandbox-env-go-action')));
    await tester.pumpAndSettle();

    final note =
        tester.widget<Text>(find.byKey(const Key('sandbox-env-go-note')));
    expect(note.data, contains('安装失败'));
    expect(note.data, contains('网络不可达'));
    expect(note.data, isNot(contains('已安装')));
    final status =
        tester.widget<Text>(find.byKey(const Key('sandbox-env-go-status')));
    expect(status.data, '未安装', reason: '失败不许把状态改成已安装');
  });

  testWidgets('★★ verifiedVersion==null ⇒ 显示「未校验」，不编版本号', (tester) async {
    final fake = _FakeSandbox(
      profile: _profile(),
      installResults: const <String, SandboxEnvInstallResult>{
        'bun': SandboxEnvInstallResult(ok: true, name: 'bun'),
      },
    );
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sandbox-env-bun-action')));
    await tester.pumpAndSettle();

    final note =
        tester.widget<Text>(find.byKey(const Key('sandbox-env-bun-note')));
    expect(note.data, contains('版本未校验'));
    expect(note.data, isNot(contains('版本 1')));
  });

  testWidgets('★★ container 档位：显示未实现 + note，且不给安装按钮', (tester) async {
    final fake = _FakeSandbox(
      profile: _profile(
        tier: 'container',
        implemented: false,
        tierNote: 'L2 容器隔离尚未实现，当前仅提供 L1 进程级',
      ),
    );
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    final tier =
        tester.widget<Text>(find.byKey(const Key('sandbox-env-tier')));
    expect(tier.data, contains('未实现'));
    expect(find.byKey(const Key('sandbox-env-tier-note')), findsOneWidget);
    final btn = tester.widget<TextButton>(
        find.byKey(const Key('sandbox-env-node-action')));
    expect(btn.onPressed, isNull, reason: '未实现的隔离档不许给安装按钮');
  });

  testWidgets('★★ 自由出网 + high 风险：风险标 + riskNote 原样（含"策略级，非硬隔离"）',
      (tester) async {
    final fake = _FakeSandbox(
      profile: _profile(
        allowAll: true,
        risk: 'high',
        riskNote: '允许自由出网：Agent 可能被提示注入外带数据；强制力为策略级，非硬隔离',
      ),
    );
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sandbox-env-risk-badge')), findsOneWidget);
    final note = tester
        .widget<Text>(find.byKey(const Key('sandbox-env-risk-note')));
    expect(note.data, contains('策略级，非硬隔离'));
    final net =
        tester.widget<Text>(find.byKey(const Key('sandbox-env-network')));
    expect(net.data, contains('自由出网'));
  });

  testWidgets('★★ 通道未实现 ⇒ 「当前版本不支持环境管理」+ 原因（不画假开关）',
      (tester) async {
    final fake = _FakeSandbox(profile: _profile(), throwOnProfile: true);
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sandbox-env-degrade')), findsOneWidget);
    expect(find.textContaining('当前版本不支持环境管理'), findsWidgets);
    expect(find.byKey(const Key('sandbox-env-node-action')), findsNothing,
        reason: '降级时不许出现可点的安装/卸载假开关');
  });

  testWidgets('★ 项目认不出 ⇒ 显示「认不出项目类型」，不猜命令', (tester) async {
    final fake = _FakeSandbox(profile: _profile());
    await tester.pumpWidget(_wrap(SandboxEnvSection(service: fake)));
    await tester.pumpAndSettle();

    final project =
        tester.widget<Text>(find.byKey(const Key('sandbox-env-project')));
    expect(project.data, contains('认不出项目类型'));
  });
}
