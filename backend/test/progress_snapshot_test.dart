// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **ProgressSnapshot 测试**（V0.4）：无进展判据 / 测试数解析 / 错误签名。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | 文件签名：同集合顺序无关、不同集合不同 | 集合顺序导致误判"有进展" |
// | ② | progressedFrom：首帧算有进展；文件变/测试升/错误变算进展 | 打转被判成有进展（该停不停） |
// | ③ | 同一错误重复 ⇒ 无进展（归一化去时间戳/路径） | 每次签名不同 ⇒ 永远"有进展" |
// | ④ | pytest/jest/go/gradle 解析 | 解析不到时编数（0 通过） |
// | ⑤ | 解析不到 ⇒ null（**不是 0**） | 把"看不到输出"当"全挂" |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  group('文件签名', () {
    test('① 同集合顺序无关；不同集合不同；空集合稳定', () {
      final a = filesSignatureOf(['lib/a.dart', 'lib/b.dart']);
      final b = filesSignatureOf(['lib/b.dart', 'lib/a.dart']);
      expect(a, b, reason: '排序后应完全一致（否则同一次改动两次签名不同）');
      final c = filesSignatureOf(['lib/a.dart']);
      expect(c, isNot(a));
      expect(filesSignatureOf([]), filesSignatureOf([]));
      expect(filesSignatureOf([' lib/a.dart ']), filesSignatureOf(['lib/a.dart']),
          reason: 'trim 后应一致');
    });
  });

  group('有无进展', () {
    test('② 首帧算有进展（没得比，不误停）', () {
      const s = ProgressSnapshot(filesSignature: 'x', changedFiles: []);
      expect(s.progressedFrom(null), isTrue);
    });

    test('②b 文件变 / 测试通过数上升 / 错误消失 ⇒ 有进展', () {
      const prev = ProgressSnapshot(
        filesSignature: 'a',
        changedFiles: ['x'],
        testsPassed: 3,
        testsTotal: 10,
        errorSignature: 'e1',
      );
      expect(
        const ProgressSnapshot(filesSignature: 'b', changedFiles: ['y'])
            .progressedFrom(prev),
        isTrue,
      );
      expect(
        const ProgressSnapshot(
          filesSignature: 'a',
          changedFiles: ['x'],
          testsPassed: 5,
          testsTotal: 10,
          errorSignature: 'e1',
        ).progressedFrom(prev),
        isTrue,
        reason: '测试从 3 通过升到 5 通过 = 有进展',
      );
      expect(
        const ProgressSnapshot(filesSignature: 'a', changedFiles: ['x'])
            .progressedFrom(prev),
        isTrue,
        reason: '错误签名消失（修好了）= 有进展',
      );
    });

    test('②c 完全相同 ⇒ 无进展（连续 2 轮就该停）', () {
      const s = ProgressSnapshot(
        filesSignature: 'same',
        changedFiles: ['x'],
        testsPassed: 3,
        testsTotal: 10,
        errorSignature: 'e',
      );
      expect(s.progressedFrom(s), isFalse);
    });
  });

  group('错误签名归一化', () {
    test('③ 同一错误（时间戳/耗时/路径不同）⇒ 同签名', () {
      final a = errorSignatureOf('Error: build failed after 0.52s at /home/u/app/lib/x.dart:12');
      final b = errorSignatureOf('Error: build failed after 1.30s at C:\\ws\\app\\lib\\x.dart:12');
      expect(a, isNotNull);
      expect(a, b, reason: '★ 归一化必须去掉时间/路径，否则同一错误每轮签名都不同');
    });

    test('③b 不同错误 ⇒ 不同签名；空/null ⇒ null', () {
      final a = errorSignatureOf('Undefined name foo');
      final b = errorSignatureOf('Type mismatch bar');
      expect(a, isNot(b));
      expect(errorSignatureOf(null), isNull);
      expect(errorSignatureOf('   '), isNull);
    });
  });

  group('测试通过数解析（只认 4 个框架，解析不到返回 null）', () {
    test('④ pytest / jest / go / gradle', () {
      final pytest = parseTestCounts('= 12 passed, 3 failed in 0.52s =');
      expect(pytest?.passed, 12);
      expect(pytest?.total, 15);

      final jest = parseTestCounts(
          'Tests:       2 failed, 10 passed, 12 total');
      expect(jest?.passed, 10);
      expect(jest?.total, 12);

      final go = parseTestCounts('--- PASS: TestA\n--- PASS: TestB\n--- FAIL: TestC');
      expect(go?.passed, 2);
      expect(go?.total, 3);

      final gradle = parseTestCounts('7 tests passed');
      expect(gradle?.passed, 7);
      expect(gradle?.total, 7);
    });

    test('⑤ 解析不到 ⇒ null（绝不编 0）', () {
      expect(parseTestCounts('BUILD SUCCESSFUL in 12s'), isNull,
          reason: '★ gradle 成功但没有数字 ⇒ 不编数');
      expect(parseTestCounts('hello world'), isNull);
      expect(parseTestCounts(''), isNull);
    });
  });

  group('序列化（写 checkpoint / 读回）', () {
    test('toJson/fromJson 往返；缺字段容忍', () {
      const s = ProgressSnapshot(
        filesSignature: 'sig',
        changedFiles: ['a', 'b'],
        testsPassed: 4,
        testsTotal: 9,
        errorSignature: 'err',
      );
      final back = ProgressSnapshot.fromJson(s.toJson());
      expect(back?.filesSignature, 'sig');
      expect(back?.changedFiles, hasLength(2));
      expect(back?.testsPassed, 4);
      expect(back?.testsTotal, 9);
      expect(back?.errorSignature, 'err');
      // 缺 filesSignature ⇒ null（不猜）
      expect(ProgressSnapshot.fromJson({'changedFiles': []}), isNull);
      expect(ProgressSnapshot.fromJson(null), isNull);
      // testsPassed 缺失 ⇒ null（不是 0）
      final sparse = ProgressSnapshot.fromJson(
          {'filesSignature': 's', 'changedFiles': []});
      expect(sparse?.testsPassed, isNull);
      expect(sparse?.testsTotal, isNull);
    });
  });
}
