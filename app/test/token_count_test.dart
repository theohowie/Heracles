// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **token 输入单位解析的回归闸（2026-11-05 用户口径）**。
//
// 用户原话：「k 和 m 都是单位，大写的也算，如果没有单位，那就是数字，
// 32 就是 32，1 就是 1；1k 和 1K 一样，但和 1 不一样；1m 和 1M 一样，
// 但和 1k / 1 / 1K 不一样」。这个文件把每一条都钉住。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/token_count.dart';

void main() {
  group('parseTokenCount —— 用户口径逐条', () {
    test('没有单位 = 纯数字（32 就是 32，1 就是 1）', () {
      expect(parseTokenCount('32'), 32);
      expect(parseTokenCount('1'), 1);
      expect(parseTokenCount('1000000'), 1000000);
    });

    test('k 与 K 等价（1k == 1K == 1024），且与 1 不同', () {
      expect(parseTokenCount('1k'), 1024);
      expect(parseTokenCount('1K'), 1024);
      expect(parseTokenCount('1k'), parseTokenCount('1K'));
      expect(parseTokenCount('1k'), isNot(parseTokenCount('1')));
      expect(parseTokenCount('128K'), 131072);
      expect(parseTokenCount('32k'), 32768);
    });

    test('m 与 M 等价（1m == 1M == 1048576），且与 1k / 1 / 1K 都不同', () {
      expect(parseTokenCount('1m'), 1048576);
      expect(parseTokenCount('1M'), 1048576);
      expect(parseTokenCount('1M'), isNot(parseTokenCount('1k')));
      expect(parseTokenCount('1M'), isNot(parseTokenCount('1')));
      expect(parseTokenCount('1M'), isNot(parseTokenCount('1K')));
    });

    test('允许空格与小数', () {
      expect(parseTokenCount(' 128 k '), 131072);
      expect(parseTokenCount('1.5M'), 1572864);
      expect(parseTokenCount('0.5K'), 512);
    });

    test('空 / 非法 ⇒ null（不猜、不当 0）', () {
      expect(parseTokenCount(''), isNull);
      expect(parseTokenCount('   '), isNull);
      expect(parseTokenCount('abc'), isNull);
      expect(parseTokenCount('k'), isNull);
      expect(parseTokenCount('-1K'), isNull);
    });

    test('尾部 tokens 写法也认（用户可能照抄面板）', () {
      expect(parseTokenCount('128k tokens'), 131072);
      expect(parseTokenCount('32768token'), 32768);
    });
  });

  group('formatTokenCount —— 展示要能反解回去', () {
    test('整 M / 整 K / 纯数字', () {
      expect(formatTokenCount(1048576), '1M');
      expect(formatTokenCount(1572864), '1536K');
      expect(formatTokenCount(131072), '128K');
      expect(formatTokenCount(1000), '1000');
      expect(formatTokenCount(0), '');
    });

    test('往返一致：format 再 parse 回来必须等于原值', () {
      for (final v in [1024, 32768, 131072, 1048576, 1572864]) {
        expect(parseTokenCount(formatTokenCount(v)), v, reason: '往返丢失：$v');
      }
    });
  });
}
