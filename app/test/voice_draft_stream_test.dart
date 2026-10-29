import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/widgets/voice_draft.dart';

/// **语音流式草稿纯逻辑层单测**（task-6 阶段 1，2026-10-29）。
///
/// 只测逻辑，不 pump widget（阶段 2 才接 input_bar / chat_screen）。
/// 断言的语义不变量：
/// · 录音中全文 = 原文[0..anchor] + 草稿 + 原文[anchor..]
///   —— **每次只替换草稿段**，用户的前缀/后缀一字不动；
/// · applyPartial 返回 [TextEditingValue]，**不把光标拽到末尾**：
///   光标在草稿段外保持原位、在草稿段后随长度差平移、在草稿内随长度差调整；
/// · commitFinal：草稿转正式文本，光标落在插入段末尾；
/// · cancel：恢复原文与起始选区；
/// · 录音中用户手打 ⇒ 先把草稿提交为正式文本，迟到 partial 不得覆盖；
/// · 空草稿 / 重复 partial / 重复 final / 重复 cancel 幂等；
/// · 无流式能力时不假造 partial（如实降级）。
void main() {
  TextEditingValue at(String text, int offset) =>
      TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));

  group('partial 序列：只替换草稿段', () {
    test('锚点在中间：三次累积 partial 都插在锚点，前后缀一字不动', () {
      final d = VoiceDraft();
      final start = d.start('你好，世界', 3);
      expect(start.text, '你好，世界');
      expect(start.selection, const TextSelection.collapsed(offset: 3));

      var v = d.applyPartial('今天');
      expect(v.text, '你好，今天世界');

      v = d.applyPartial('今天天气');
      expect(v.text, '你好，今天天气世界');

      v = d.applyPartial('今天天气不错');
      expect(v.text, '你好，今天天气不错世界');

      // 前后缀逐字等于原文对应段（不是重新拼的近似串）。
      expect(v.text.substring(0, 3), '你好，');
      expect(v.text.substring(v.text.length - 2), '世界');
      expect(d.draft, '今天天气不错');
      expect(d.anchor, 3);
      expect(d.originalText, '你好，世界');
    });

    test('前后缀含 emoji/空格/全角标点/换行：逐字保留', () {
      const original = 'A😀 B，C\nD';
      final anchor = original.indexOf('，');
      final d = VoiceDraft();
      d.start(original, anchor);
      final v = d.applyPartial('语音草稿');
      expect(
        v.text,
        '${original.substring(0, anchor)}语音草稿${original.substring(anchor)}',
      );
      expect(v.text.startsWith(original.substring(0, anchor)), isTrue);
      expect(v.text.endsWith(original.substring(anchor)), isTrue);
    });

    test('锚点在开头 / 末尾 / 越界（clamp）都只动草稿段', () {
      var d = VoiceDraft();
      d.start('abc', 0);
      expect(d.applyPartial('X').text, 'Xabc');

      d = VoiceDraft();
      d.start('abc', 3);
      expect(d.applyPartial('X').text, 'abcX');

      d = VoiceDraft();
      d.start('abc', 99);
      expect(d.anchor, 3);
      expect(d.applyPartial('X').text, 'abcX');

      d = VoiceDraft();
      d.start('abc', -5);
      expect(d.anchor, 0);
      expect(d.applyPartial('X').text, 'Xabc');
    });

    test('空原文：直接从锚点 0 开始写草稿', () {
      final d = VoiceDraft();
      d.start('', 0);
      expect(d.applyPartial('你好').text, '你好');
      expect(d.applyPartial('你好世界').text, '你好世界');
      expect(d.originalText, '');
    });
  });

  group('光标不被拽走', () {
    test('光标在草稿段之前：保持原位', () {
      final d = VoiceDraft();
      d.start('abcdef', 4, selection: const TextSelection.collapsed(offset: 1));
      final v = d.applyPartial('XY');
      expect(v.text, 'abcdXYef');
      expect(v.selection, const TextSelection.collapsed(offset: 1));
    });

    test('光标在草稿段之后：随长度差平移（不回锚点、不拽到末尾）', () {
      final d = VoiceDraft();
      d.start('abcdef', 2, selection: const TextSelection.collapsed(offset: 5));
      var v = d.applyPartial('XY');
      expect(v.text, 'abXYcdef');
      expect(v.selection.extentOffset, 7); // 5 + (2-0)

      v = d.applyPartial('XYZ'); // 长度差 +1
      expect(v.text, 'abXYZcdef');
      expect(v.selection.extentOffset, 8); // 7 + 1
    });

    test('光标在草稿段内：随长度差调整，不被拽到末尾', () {
      final d = VoiceDraft();
      d.start('abcdef', 2);
      var v = d.applyPartial('XY'); // 草稿 'XY' 在 [2,4)
      expect(v.selection.extentOffset, 2); // 起始光标 = 锚点，保持

      v = d.applyPartial('XYZ', selection: const TextSelection.collapsed(offset: 3));
      expect(v.text, 'abXYZcdef');
      // 光标在旧草稿内（offset 3）→ 3 + 1 = 4，仍在草稿段内，而不是末尾。
      expect(v.selection.extentOffset, 4);
    });

    test('非折叠选区：base/extent 分别平移，选区方向保留', () {
      final d = VoiceDraft();
      d.start(
        'abcdef',
        2,
        selection: const TextSelection(baseOffset: 4, extentOffset: 1),
      );
      final v = d.applyPartial('XY');
      // base 在草稿段后（4+2）、extent 在草稿段前（不动），方向（反向）保留。
      expect(
        v.selection,
        const TextSelection(baseOffset: 6, extentOffset: 1),
      );
      expect(v.selection.baseOffset, greaterThan(v.selection.extentOffset));
    });
  });

  group('commitFinal：草稿转正式文本', () {
    test('光标落在插入段末尾，草稿清空、状态关闭', () {
      final d = VoiceDraft();
      d.start('你好，世界', 3);
      d.applyPartial('今天天气');
      final v = d.commitFinal('今天天气不错');
      expect(v.text, '你好，今天天气不错世界');
      expect(v.selection, const TextSelection.collapsed(offset: 3 + 6));
      expect(d.active, isFalse);
      expect(d.draft, isEmpty);
      expect(d.text, '你好，今天天气不错世界');
    });

    test('final 与最后一次 partial 不同：以 final 为准，不残留 partial', () {
      final d = VoiceDraft();
      d.start('ab', 1);
      d.applyPartial('中间识别');
      final v = d.commitFinal('中间识别。');
      expect(v.text, 'a中间识别。b');
    });

    test('重复 commitFinal 幂等（不重复插入）', () {
      final d = VoiceDraft();
      d.start('abcdef', 2);
      d.applyPartial('XY');
      final once = d.commitFinal('XY');
      final twice = d.commitFinal('XY');
      expect(once.text, 'abXYcdef');
      expect(twice, once);
    });
  });

  group('cancel：恢复原文与起始选区', () {
    test('恢复原文 + 起始折叠选区', () {
      final d = VoiceDraft();
      d.start('abcdefg', 3, selection: const TextSelection.collapsed(offset: 3));
      d.applyPartial('XY');
      d.applyPartial('XYZ');
      final v = d.cancel();
      expect(v.text, 'abcdefg');
      expect(v.selection, const TextSelection.collapsed(offset: 3));
      expect(d.active, isFalse);
      expect(d.draft, isEmpty);
    });

    test('起始是非折叠选区：原样恢复（方向也保留）', () {
      final d = VoiceDraft();
      const initial = TextSelection(baseOffset: 1, extentOffset: 4);
      d.start('abcdefg', 4, selection: initial);
      d.applyPartial('XY');
      final v = d.cancel();
      expect(v.text, 'abcdefg');
      expect(v.selection, initial);
    });

    test('重复 cancel 幂等', () {
      final d = VoiceDraft();
      d.start('abc', 1);
      d.applyPartial('X');
      final c1 = d.cancel();
      final c2 = d.cancel();
      expect(c2, c1);
    });
  });

  group('录音中用户手打提交', () {
    test('先把当前草稿提交为正式文本，迟到 partial 不得覆盖用户输入', () {
      final d = VoiceDraft();
      d.start('你好，世界', 3);
      final partial = d.applyPartial('今天');
      expect(partial.text, '你好，今天世界');

      // 用户在输入框里手打（内容基于当前显示，可能改了字）。
      final typed = at('你好，今天天。世界', 6);
      final v = d.applyUserEdit(typed);
      expect(v, typed); // 用户手打内容原样生效
      expect(d.active, isFalse);

      // 语音迟到的 partial 不得覆盖用户手打内容。
      final late = d.applyPartial('今天天气不错');
      expect(late.text, typed.text);
    });

    test('手打后 commitFinal / applyEvent 也不得二次插入', () {
      final d = VoiceDraft();
      d.start('ab', 1);
      d.applyPartial('X');
      d.applyUserEdit(at('aXYb', 4));
      expect(d.commitFinal('ZZZ').text, 'aXYb');
      expect(
        d.applyEvent(
          const VoicePartial(sessionId: 's1', text: 'ZZZ', isFinal: true),
        ).text,
        'aXYb',
      );
    });
  });

  group('幂等 / 降级', () {
    test('重复 partial 与空草稿幂等', () {
      final d = VoiceDraft();
      d.start('abc', 1);
      final a = d.applyPartial('XY');
      final b = d.applyPartial('XY');
      expect(b, a);
      expect(b.text, 'aXYbc');

      final empty = d.applyPartial('');
      expect(empty.text, 'abc');
      expect(empty.selection, const TextSelection.collapsed(offset: 1));
    });

    test('无流式能力：applyPartial 不假造草稿，commitFinal 仍可用', () {
      final d = VoiceDraft();
      d.start('abc', 1, streaming: false);
      final v = d.applyPartial('XY');
      expect(v.text, 'abc');
      expect(d.draft, isEmpty);
      final done = d.commitFinal('你好');
      expect(done.text, 'a你好bc');
    });
  });

  group('VoicePartial 事件', () {
    test('final 走 commitFinal，非 final 走 applyPartial', () {
      final d = VoiceDraft();
      d.start('甲', 1, sessionId: 's1');
      final mid = d.applyEvent(
        const VoicePartial(sessionId: 's1', text: '乙'),
      );
      expect(mid.text, '甲乙');
      final done = d.applyEvent(
        const VoicePartial(sessionId: 's1', text: '乙丙', isFinal: true),
      );
      expect(done.text, '甲乙丙');
      expect(done.selection, const TextSelection.collapsed(offset: 3));
    });

    test('旧会话/非本次会话的 partial 被丢弃（不串台）', () {
      final d = VoiceDraft();
      d.start('甲', 1, sessionId: 's2');
      final stale = d.applyEvent(
        const VoicePartial(sessionId: 's1', text: '旧会话结果'),
      );
      expect(stale.text, '甲');
      final fresh = d.applyEvent(
        const VoicePartial(sessionId: 's2', text: '新'),
      );
      expect(fresh.text, '甲新');
    });

    test('VoicePartial 值语义（sessionId/text/isFinal 全比较）', () {
      const a = VoicePartial(sessionId: 's', text: '你好');
      const b = VoicePartial(sessionId: 's', text: '你好');
      const c = VoicePartial(sessionId: 's', text: '你好', isFinal: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
