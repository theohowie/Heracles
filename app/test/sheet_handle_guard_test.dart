// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **抓手防回归（源码级）**（2026-10-31，T2-4）：
// 除共享组件 `lib/widgets/bw_approval.dart` 的 `BwSheetHandle` 外，
// 任何界面文件都不许再自绘抓手：
//   · 禁止本地 `_bwSheetHandle` 帮助函数；
//   · 禁止"width: 36 且 height: 5/4"的抓手常量组合（排除共享组件自身）。
//
// 这是一条**会红的门禁**：迁移没做完时它必须失败（而不是默默放过）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('★ 除 BwSheetHandle 外，lib/ 下不得再自绘抓手', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'flutter test 的工作目录应是 app/');

    final offenders = <String>[];
    for (final f in libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = f.path.replaceAll(r'\', '/');
      final lines = f.readAsLinesSync();
      // 共享组件自己的 BwSheetHandle 定义不算违规；但同一个文件里**别处**
      // 的自绘抓手仍要抓（bw_approval 有 6 个旧抽屉自绘了抓手）。
      var handleClassStart = -1;
      var handleClassEnd = -1;
      if (rel.endsWith('lib/widgets/bw_approval.dart')) {
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].startsWith('class BwSheetHandle')) {
            handleClassStart = i;
          } else if (handleClassStart >= 0 &&
              lines[i].startsWith('class ') &&
              i > handleClassStart) {
            handleClassEnd = i;
            break;
          }
        }
        if (handleClassEnd < 0) handleClassEnd = lines.length;
      }
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final inHandleClass = handleClassStart >= 0 &&
            i >= handleClassStart &&
            i < handleClassEnd;
        if (inHandleClass) continue;
        if (line.contains('_bwSheetHandle')) {
          offenders.add('$rel:${i + 1}: 本地抓手函数');
          continue;
        }
        // width: 36 附近（±4 行）出现 height: 4 / height: 5 ⇒ 自绘抓手
        if (line.contains('width: 36')) {
          final end = (i + 4).clamp(0, lines.length - 1);
          for (var j = i; j <= end; j++) {
            if (lines[j].contains('height: 4') ||
                lines[j].contains('height: 5')) {
              offenders.add('$rel:${j + 1}: 自绘抓手（width:36 + height:4/5）');
              break;
            }
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '所有抽屉抓手必须走 BwSheetShell 默认的 BwSheetHandle；'
          '迁移未完成的文件如下：\n${offenders.join('\n')}',
    );
  });
}
