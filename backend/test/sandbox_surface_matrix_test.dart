// Copyright (C) 2026 The Heracles Authors
//
// **B4（2026-10-30）沙箱优先 —— 执行面测试矩阵（决策层）**。
//
// ============================================================================
// 产品语义（用户拍板）
// ============================================================================
// · 沙箱就绪时：**除「必须动 Android 本身」的命令外，一律走沙箱**（默认面）；
// · 例外只有两类：Android 专有命令前缀（`pm`/`am`/…）与真实设备路径
//   （`/sdcard/Download` 等）—— 都在 `sandbox_capability.dart` 的白名单里，
//   **不允许模型自由发挥**；
// · 沙箱**未就绪**时：surface 仍是 `sandbox` + `sandboxNotReady=true`，
//   调用方必须**明确报错**，**绝不静默回落手机**（那会让 agent 在用户不知情下
//   操作真实文件系统 —— 正是沙箱要避免的事）。
//
// 本文件只测 `decideSurface`（纯函数）；"执行层真的不回落"见
// `sandbox_surface_exec_test.dart`。
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  SurfaceDecision d(String cmd, {bool ready = true}) =>
      decideSurface(cmd, sandboxReady: ready);

  group('B4 五类执行面矩阵（surface / matchedRule / reason）', () {
    test('① 普通命令 → sandbox（默认面）', () {
      final r = d('ls -la');
      expect(r.surface, ExecutionSurface.sandbox);
      expect(r.matchedRule, 'default');
      expect(r.reason, contains('默认走沙箱'));
      expect(r.sandboxNotReady, isFalse);
    });

    test('② 含 @挂载点 → sandbox（挂载点只在沙箱内可见）', () {
      final r = d('cat @workspace/dist/app.tar');
      expect(r.surface, ExecutionSurface.sandbox,
          reason: '★ 引用 @name 的命令必须留在沙箱（手机上根本没有这个挂载点）');
      expect(r.matchedRule, 'mount-ref');
      expect(r.reason, contains('挂载点'));
      expect(r.sandboxNotReady, isFalse);
    });

    test('③ 含真实设备路径 → device（matchedRule/reason 都要指向 path）', () {
      final r = d('cp a.txt /sdcard/Download/a.txt');
      expect(r.surface, ExecutionSurface.device);
      expect(r.matchedRule, 'path:/sdcard/Download',
          reason: '★ 命中哪条路径规则要可排障（reason 里也要带同一个前缀）');
      expect(r.reason, contains('真实设备路径'));
      expect(r.reason, contains('/sdcard/Download'));

      // 同类：/storage/ 与 /data/data/ 也走手机
      expect(d('ls /storage/emulated/0').matchedRule, 'path:/storage/');
      expect(d('cat /data/data/com.x/db').matchedRule, 'path:/data/data/');
    });

    test('④ 含 Android 专有命令 → device（matchedRule/reason 指向 command）', () {
      final r = d('pm list packages');
      expect(r.surface, ExecutionSurface.device);
      expect(r.matchedRule, 'command:pm');
      expect(r.reason, contains('Android'));
      expect(r.reason, contains('包管理'),
          reason: 'reason 要说清"为什么沙箱做不了"，而不是只丢一个规则名');
    });

    test('⑤ 沙箱未就绪 → surface 仍是 sandbox + sandboxNotReady=true（不可回落）', () {
      for (final cmd in <String>['ls', 'cat @workspace/a.txt', 'pm list packages']) {
        final r = d(cmd, ready: false);
        expect(r.surface, ExecutionSurface.sandbox,
            reason: '★ surface 不能变成 device —— 那等于静默改在手机上跑：$cmd');
        expect(r.sandboxNotReady, isTrue,
            reason: '★ 调用方靠这个布尔字段拒绝执行（不认 matchedRule 字符串）');
        expect(r.matchedRule, 'sandbox-not-ready');
        expect(r.reason, contains('拒绝执行'));
        expect(r.reason, contains('不会改在手机'));
      }
    });
  });

  group('B4 构建类任务优先沙箱（T2 语义）', () {
    test('构建/包管理/编译命令都在沙箱里跑（设备工具链只作显式回退）', () {
      for (final cmd in <String>[
        './gradlew assembleDebug',
        'make -j4',
        'flutter build apk --debug',
        'apk add --no-cache gcc',
        'cmake -B build && cmake --build build',
        'dart pub get',
      ]) {
        final r = d(cmd);
        expect(r.surface, ExecutionSurface.sandbox, reason: cmd);
        expect(r.matchedRule, 'default', reason: cmd);
      }
    });

    test('沙箱自己绑定的 App 外部目录不能被误判成"真实设备路径"', () {
      // 依据：`kDeviceOnlyPathPrefixes` 的 KDoc —— 沙箱 bind 了
      // `/sdcard/Android/data/<本App>`，所以**不能**把通用 `/sdcard/` 整体判 device
      // （否则本 App 自己的外部目录会被赶去手机）。表里只枚举"其余子目录"。
      final r = d('ls /sdcard/Android/data/com.theohowie.heracles/files');
      expect(r.surface, ExecutionSurface.sandbox,
          reason: '沙箱绑定了本 App 的外部目录，通用 /sdcard/ 不是设备路径规则');
      expect(r.matchedRule, 'default');
    });
  });

  group('B4 边界（规则顺序即语义）', () {
    test('@挂载点 优先于路径规则（同一条命令两个特征时）', () {
      final r = d('cp @workspace/a.txt /sdcard/Download/');
      expect(r.surface, ExecutionSurface.sandbox);
      expect(r.matchedRule, 'mount-ref');
    });

    test('命令词优先于路径规则', () {
      expect(d('pm install /sdcard/a.apk').matchedRule, 'command:pm');
    });

    test('空命令不崩、也不算"未就绪拒绝"', () {
      final r = d('   ', ready: false);
      expect(r.surface, ExecutionSurface.sandbox);
      expect(r.sandboxNotReady, isFalse,
          reason: '空命令没有实际执行，不必让调用方报"请激活沙箱"');
    });

    test('沙箱能力根本没接入时不出 decideSurface 的"未就绪"决策（由调用方处理）', () {
      // decideSurface 只回答"假设有沙箱，这条该在哪跑"；
      // "宿主没接沙箱"是 shell_tools 另一条分支（保持旧行为走手机）。
      // 本测试钉住：ready=true 时普通命令永远是 sandbox。
      expect(d('ls', ready: true).surface, ExecutionSurface.sandbox);
    });
  });
}
