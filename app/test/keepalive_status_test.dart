// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **保活引导后端配套的 Dart 契约**（2026-11-02，`docs/INTERFACE.md` §N18）：
// · `keepaliveStatus`：聚合真实状态（前台服务 / 电池优化 / MIUI 口径 note / 自启动路径），
//   **缺的不编** —— 宿主没给的字段必须保持 null；
// · `oemGuide(kind)`：MIUI 保活三件套（自启动 / 后台弹出界面 / 锁屏显示），
//   未知 kind 在 **Dart 侧先行拒绝**（不调通道）。
//
// ⚠️ 这两个方法都**只读**：不拉系统页、不改设置 —— 读失败就如实说"不可用"。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/services/agent_bridge.dart';

const _cmdChannel = MethodChannel('heracles/command');

void main() {
  // 纯 Dart 单测也要绑定：装通道 mock 需要 messenger
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 装 handler：返回 `Map` = 通道回包；返回 `Exception` = 抛出；
  /// 返回 null = 该方法没有实现（→ invokeMethod 抛 MissingPluginException）。
  void install(
      Object? Function(String method, Map<Object?, Object?> args)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cmdChannel, (call) async {
      if (handler == null) return null;
      final r = handler(
          call.method, (call.arguments as Map<Object?, Object?>?) ?? {});
      if (r is Exception) throw r;
      return r;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cmdChannel, null));
  }

  group('keepaliveStatus — 聚合真实状态（缺的不编）', () {
    test('★★★ 全有 ⇒ 四个字段原样透传（一个不编、一个不丢）', () async {
      install((m, args) => m == 'keepaliveStatus'
          ? {
              'ok': true,
              'foregroundServiceRunning': true,
              'batteryIgnored': true,
              'batteryNote': 'MIUI 口径提醒：无限制 ≠ 白名单',
              'autostart': {'brand': '小米/Redmi', 'path': '设置 → … → 自启动'},
            }
          : null);

      final s = await AgentBridge().keepaliveStatus();
      expect(s, isNotNull);
      expect(s!.foregroundServiceRunning, isTrue);
      expect(s.batteryIgnored, isTrue);
      expect(s.batteryNote, contains('无限制'));
      expect(s.autostart!.brand, '小米/Redmi');
      expect(s.autostart!.path, isNotEmpty);
    });

    test('★★★ 部分缺 ⇒ 缺的字段保持 null（不许补 false/空串假装查到了）', () async {
      install((m, args) => m == 'keepaliveStatus'
          ? {
              'ok': true,
              'batteryIgnored': true,
              // 前台服务、note、autostart 都没给
            }
          : null);

      final s = await AgentBridge().keepaliveStatus();
      expect(s, isNotNull);
      expect(s!.batteryIgnored, isTrue);
      expect(s.foregroundServiceRunning, isNull,
          reason: '宿主没查到就是 null —— 编成 false 是假信息');
      expect(s.batteryNote, isNull);
      expect(s.autostart, isNull);
    });

    test('★★ 全缺（宿主只回 ok:true）⇒ 全部字段 null，对象仍可用', () async {
      install((m, args) => m == 'keepaliveStatus' ? {'ok': true} : null);

      final s = await AgentBridge().keepaliveStatus();
      expect(s, isNotNull);
      expect(s!.foregroundServiceRunning, isNull);
      expect(s.batteryIgnored, isNull);
      expect(s.batteryNote, isNull);
      expect(s.autostart, isNull);
    });

    test('★★★ 通道缺失（MissingPluginException）⇒ 整体 null（不可用，不编默认值）', () async {
      install((m, args) =>
          m == 'keepaliveStatus' ? MissingPluginException('旧宿主') : null);

      final s = await AgentBridge().keepaliveStatus();
      expect(s, isNull,
          reason: '状态不可用就回 null —— 编一个全 false 的状态是假信息');
    });

    test('★ PlatformException ⇒ null（读失败 = 不可用，与"值是 false"必须区分）', () async {
      install((m, args) =>
          m == 'keepaliveStatus' ? PlatformException(code: 'error') : null);

      expect(await AgentBridge().keepaliveStatus(), isNull);
    });
  });

  group('oemGuide(kind) — MIUI 保活三件套', () {
    test('★★★ 三类 kind 原样传给通道并解析 {brand, path}', () async {
      final seenKinds = <String>[];
      install((m, args) {
        if (m == 'oemGuide') {
          seenKinds.add((args['kind'] as String?) ?? '<null>');
          return {'ok': true, 'brand': '小米/Redmi', 'path': '设置 → …'};
        }
        return null;
      });

      final b = AgentBridge();
      for (final kind in ['autostart', 'backgroundPopup', 'lockScreenShow']) {
        final g = await b.oemGuide(kind);
        expect(g, isNotNull, reason: 'kind=$kind 应有返回');
        expect(g!.path, isNotEmpty);
      }
      expect(seenKinds, ['autostart', 'backgroundPopup', 'lockScreenShow'],
          reason: 'kind 必须原样透传（宿主按它查品牌路径）');
    });

    test('★★★ 未知 kind ⇒ ArgumentError 拒绝，且通道零调用', () async {
      var calls = 0;
      install((m, args) {
        if (m == 'oemGuide') {
          calls++;
          return {'ok': true, 'brand': 'x', 'path': 'y'};
        }
        return null;
      });

      await expectLater(
        AgentBridge().oemGuide('batterySaver'),
        throwsArgumentError,
        reason: '未知 kind 必须在 Dart 侧拦下 —— 不许把噪音打到宿主',
      );
      expect(calls, 0, reason: '客户端校验先行：通道一个调用都不该有');
    });

    test('★★ 宿主回 ok:false ⇒ null，不编路径', () async {
      install((m, args) =>
          m == 'oemGuide' ? {'ok': false, 'error': '未知 kind'} : null);

      expect(await AgentBridge().oemGuide('backgroundPopup'), isNull);
    });

    test('★ brand/path 缺失或空 ⇒ null（半截数据当没有）', () async {
      install((m, args) =>
          m == 'oemGuide' ? {'ok': true, 'brand': '小米', 'path': ''} : null);

      expect(await AgentBridge().oemGuide('lockScreenShow'), isNull);
    });

    test('★★ 既有 autostartGuide 仍是 oemGuide(autostart) 的薄封装（旧调用方不变）', () async {
      install((m, args) => m == 'oemGuide'
          ? {'ok': true, 'brand': '小米/Redmi', 'path': '设置 → …'}
          : null);

      final g = await AgentBridge().autostartGuide();
      expect(g, isNotNull);
      expect(g!.brand, '小米/Redmi');
    });
  });
}
