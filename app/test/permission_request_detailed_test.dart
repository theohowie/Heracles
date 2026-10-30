// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **B2（P0）：通知权限永久拒绝后跳系统设置 —— Dart 侧契约回归**（2026-10-30）。
//
// 规格（task-17）：
//   · 宿主 `requestPermission` 返回**只增**结构
//     `{ok, action:"requested"|"settings_opened"|"already_granted", granted:bool}`；
//   · AgentBridge 新增 `requestPermissionDetailed`，旧 `requestPermission`
//     语义保留（只看 ok，现有调用点零改动）；
//   · 旧宿主没回 action ⇒ 如实标 `unknown`，不猜；
//   · 通道不可用（测试/旧宿主）⇒ `notSupported`（ok=false），不假装成功。
//
// 通道用 MethodChannel mock（与 permission_switch_test.dart 同款写法），
// 不碰真机、不发真网络。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/services/agent_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/command');
  late List<String> requestKinds;

  void mockHost(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    requestKinds = <String>[];
    mockHost((call) async {
      switch (call.method) {
        case 'requestPermission':
          requestKinds.add((call.arguments as Map)['kind'] as String);
          return <String, dynamic>{
            'ok': true,
            'action': 'requested',
            'granted': false,
          };
        case 'devicePermissions':
          return <String, dynamic>{
            'notifications': 'denied',
            'microphone': 'granted',
          };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('PermissionLaunchResult / action 解析（只增契约）', () {
    test('wireName 稳定（落盘/日志不许改名）', () {
      expect(PermissionAction.requested.wireName, 'requested');
      expect(PermissionAction.settingsOpened.wireName, 'settings_opened');
      expect(PermissionAction.alreadyGranted.wireName, 'already_granted');
      expect(PermissionAction.unknown.wireName, 'unknown');
      expect(PermissionAction.parse('requested'), PermissionAction.requested);
      expect(
        PermissionAction.parse('settings_opened'),
        PermissionAction.settingsOpened,
      );
      expect(
        PermissionAction.parse('already_granted'),
        PermissionAction.alreadyGranted,
      );
      expect(PermissionAction.parse('nonsense'), PermissionAction.unknown);
      expect(PermissionAction.parse(null), PermissionAction.unknown);
    });

    test('toString 带 action/granted（可诊断，不含敏感信息）', () {
      const r = PermissionLaunchResult(
        ok: true,
        action: PermissionAction.settingsOpened,
        granted: false,
      );
      expect(r.toString(), contains('settings_opened'));
      expect(r.toString(), contains('granted: false'));
    });
  });

  group('requestPermissionDetailed：通知权限的三种去向', () {
    test('action=requested（系统弹框已拉起，granted=false）', () async {
      final bridge = AgentBridge();
      final r = await bridge.requestPermissionDetailed('notifications');
      expect(r.ok, isTrue);
      expect(r.action, PermissionAction.requested);
      expect(r.granted, isFalse);
      expect(r.error, isNull);
      expect(requestKinds, ['notifications'], reason: 'kind 必须原样透传到宿主');
    });

    test('action=settings_opened（永久拒绝 ⇒ 开了通知设置页）', () async {
      mockHost((call) async => <String, dynamic>{
        'ok': true,
        'action': 'settings_opened',
        'granted': false,
      });
      final r = await AgentBridge().requestPermissionDetailed('notifications');
      expect(r.ok, isTrue);
      expect(r.action, PermissionAction.settingsOpened);
      expect(r.granted, isFalse);
    });

    test('action=already_granted（本来就可用，不上系统界面）', () async {
      mockHost((call) async => <String, dynamic>{
        'ok': true,
        'action': 'already_granted',
        'granted': true,
      });
      final r = await AgentBridge().requestPermissionDetailed('notifications');
      expect(r.action, PermissionAction.alreadyGranted);
      expect(r.granted, isTrue);
    });

    test('legacy 宿主只回 ok（没有 action/granted）⇒ unknown，不猜', () async {
      mockHost((call) async => <String, dynamic>{'ok': true});
      final r = await AgentBridge().requestPermissionDetailed('notifications');
      expect(r.ok, isTrue);
      expect(r.action, PermissionAction.unknown);
      expect(r.granted, isFalse);
    });

    test('ok=false + error ⇒ 人话原因保留（automation 这类接口预留）', () async {
      mockHost((call) async => <String, dynamic>{
        'ok': false,
        'error': '厂商专属权限，暂无统一申请方式（接口预留）',
      });
      final r = await AgentBridge().requestPermissionDetailed('automation');
      expect(r.ok, isFalse);
      expect(r.action, PermissionAction.unknown);
      expect(r.error, contains('厂商专属权限'));
    });

    test('宿主未实现（通道无 handler）⇒ notSupported，不假装成功', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final r = await AgentBridge().requestPermissionDetailed('notifications');
      expect(r.ok, isFalse);
      expect(r.action, PermissionAction.unknown);
      expect(r.granted, isFalse);
    });

    test('PlatformException ⇒ notSupported 并带宿主 message', () async {
      mockHost((call) async =>
          throw PlatformException(code: 'boom', message: '宿主炸了'));
      final r = await AgentBridge().requestPermissionDetailed('notifications');
      expect(r.ok, isFalse);
      expect(r.error, contains('宿主炸了'));
    });
  });

  group('旧 requestPermission 语义保留（现有调用点零改动）', () {
    test('ok=true ⇒ true；ok=false ⇒ false', () async {
      final bridge = AgentBridge();
      expect(await bridge.requestPermission('notifications'), isTrue);
      mockHost((call) async => <String, dynamic>{'ok': false});
      expect(await bridge.requestPermission('notifications'), isFalse);
    });

    test('通道不可用 ⇒ false（旧行为不变）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await AgentBridge().requestPermission('notifications'), isFalse);
    });
  });

  group('devicePermissions 透传（notifications 双条件在宿主侧）', () {
    test('原样返回宿主字典', () async {
      final perms = await AgentBridge().devicePermissions();
      expect(perms['notifications'], 'denied');
      expect(perms['microphone'], 'granted');
    });
  });
}
