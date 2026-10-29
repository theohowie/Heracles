// Copyright (C) 2026 The Heracles Authors
//
// 执行面路由规则的单测。
//
// 前端 2026-10-28 的定调：**例外判定后端要给明确规则，不要让模型自由发挥**。
// 所以这张表必须有测试锁住 —— 规则被误改会让命令跑到错误的执行面：
//   · 该进沙箱的跑到手机 → 污染用户真实文件系统
//   · 该进手机的跑到沙箱 → 静默失败或读到错误内容

import 'package:test/test.dart';
import 'package:heracles_backend/heracles_backend.dart';

void main() {
  SurfaceDecision d(String cmd, {bool ready = true}) =>
      decideSurface(cmd, sandboxReady: ready);

  group('默认走沙箱', () {
    test('普通构建/文件命令 → sandbox', () {
      for (final cmd in <String>[
        'ls -la',
        './gradlew assembleDebug',
        'make -j4',
        'git status',
        'cat build.gradle.kts',
        'python3 build.py',
        'echo hello > out.txt',
      ]) {
        expect(d(cmd).surface, ExecutionSurface.sandbox, reason: cmd);
        expect(d(cmd).matchedRule, 'default', reason: cmd);
      }
    });

    test('引用了 @挂载点 → 必须 sandbox（挂载点只在沙箱内可见）', () {
      for (final cmd in <String>[
        'cat @workspace/a.txt',
        'cp @workspace/out.apk @pc_shared/',
        'ls @libs',
        'aapt2 dump badging @workspace/app.apk',
      ]) {
        final r = d(cmd);
        expect(r.surface, ExecutionSurface.sandbox, reason: cmd);
        expect(r.matchedRule, 'mount-ref', reason: cmd);
      }
    });
  });

  group('需要动 Android 本身的 → 手机 shell', () {
    test('包/Activity/系统服务类命令', () {
      final cases = <String, String>{
        'pm list packages': 'pm',
        'pm install /sdcard/a.apk': 'pm',
        'am start -n com.x/.Main': 'am',
        'dumpsys battery': 'dumpsys',
        'settings get system brightness': 'settings',
        'wm size': 'wm',
        'svc wifi enable': 'svc',
        'content query --uri content://x': 'content',
        'appops get com.x': 'appops',
        'getprop ro.product.model': 'getprop',
        'input tap 100 200': 'input',
        'screencap -p /sdcard/s.png': 'screencap',
        'su -c id': 'su',
      };
      cases.forEach((cmd, word) {
        final r = d(cmd);
        expect(r.surface, ExecutionSurface.device, reason: cmd);
        expect(r.matchedRule, 'command:$word', reason: cmd);
        expect(r.reason, contains('Android'), reason: cmd);
      });
    });

    test('带路径前缀的命令词也能识别（/system/bin/pm 视为 pm）', () {
      final r = d('/system/bin/pm list packages');
      expect(r.surface, ExecutionSurface.device);
      expect(r.matchedRule, 'command:pm');
    });

    test('前面有环境变量赋值或 sudo/env 包装仍能识别', () {
      expect(d('ANDROID_SERIAL=x pm list packages').matchedRule, 'command:pm');
      expect(d('sudo am start -n a/.B').matchedRule, 'command:am');
      expect(d('env FOO=1 dumpsys battery').matchedRule, 'command:dumpsys');
    });

    test('真实设备路径 → 手机（沙箱里没有或指向错位置）', () {
      final cases = <String>[
        'cp a.txt /sdcard/Download/a.txt',
        'ls /storage/emulated/0/DCIM',
        'cat /data/data/com.other.app/databases/x',
        'cp x /system/lib64/',
      ];
      for (final cmd in cases) {
        final r = d(cmd);
        expect(r.surface, ExecutionSurface.device, reason: cmd);
        expect(r.matchedRule, startsWith('path:'), reason: cmd);
        expect(r.reason, contains('真实设备路径'), reason: cmd);
      }
    });
  });

  group('沙箱未就绪时拒绝执行（不回落手机，2026-10-29 用户裁定）', () {
    test('未激活 → 拒绝并提示激活，绝不静默改走手机', () {
      for (final cmd in <String>[
        'ls',
        'cat @workspace/a.txt',
        'pm list packages',
      ]) {
        final r = d(cmd, ready: false);
        // ★ 面仍是 sandbox（不是 device）—— 调用方看到 matchedRule 就知道要拒绝
        expect(r.surface, ExecutionSurface.sandbox, reason: cmd);
        expect(r.matchedRule, 'sandbox-not-ready', reason: cmd);
        expect(r.reason, contains('沙箱未激活'), reason: cmd);
        expect(r.reason, contains('拒绝执行'), reason: cmd);
        expect(r.reason, isNot(contains('回落')), reason: cmd);
      }
    });
  });

  group('优先级（顺序即语义）', () {
    test('同时命中「挂载点引用」与「手机路径」时，挂载点优先走沙箱', () {
      // 这种写法本身有毛病（沙箱里读不到 /sdcard/Download），
      // 但规则必须可预测：@引用优先，且 reason 说清原因。
      final r = d('cp @workspace/a.txt /sdcard/Download/');
      expect(r.surface, ExecutionSurface.sandbox);
      expect(r.matchedRule, 'mount-ref');
    });

    test('手机命令词优先于路径规则（reason 指向命令而非路径）', () {
      final r = d('pm install /sdcard/a.apk');
      expect(r.matchedRule, 'command:pm');
    });
  });

  group('边界', () {
    test('空命令不崩', () {
      final r = d('   ');
      expect(r.surface, ExecutionSurface.sandbox);
    });

    test('邮箱/普通含 @ 文本不会被当成挂载点', () {
      final r = d('echo someone@example.com');
      expect(r.surface, ExecutionSurface.sandbox);
      expect(r.matchedRule, 'default');
    });

    test('surface 的 wire 字符串是前端契约的一部分，不能改', () {
      expect(ExecutionSurface.sandbox.wire, 'sandbox');
      expect(ExecutionSurface.device.wire, 'device');
    });
  });
}
