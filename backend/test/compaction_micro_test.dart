// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **阶段 1：MicroCompact 的回归闸**（2026-11-06）。
//
// ## 本文件锁住的契约
//
// | # | 契约 | 抓的缺陷 |
// |---|---|---|
// | ① | 只清**白名单**里、**较旧**的工具输出，保留最近 N 条 | "把模型刚读的文件清了" ⇒ 模型重读、白烧一轮 |
// | ② | `clearedRefs` 能指回原 id + 原字符数，**原始记录不删** | 清了就查无实据、无法追溯/恢复 |
// | ③ | 旧媒体块超阈值 ⇒ `[media cleared]`；未超阈值的不动 | 大图白占上下文；或反过来把小图也清了 |
// | ④ | **不碰**非白名单工具（写类）的输出 | 写类结果里是"改了什么"的证据，清了拿不回来 |
//
// ⚠️ 关键：`MicroCompact` 是**纯函数**（返回新的 SendView，入参对象一个字段都不改）。
// 所以下面每条用例都同时断言"视图变了"与"原始对象没变" —— 只测前者的话，
// 一个"原地改历史"的实现也能全绿，而那正是会砸缓存的做法。
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

String _partsTextOf(List<UserContentPart> parts) =>
    parts.whereType<TextPart>().map((p) => p.text).join();

void main() {
  /// 造 [count] 条填充消息，把要测的消息挤出保护窗。
  List<LLMMessage> filler(int count) =>
      [for (var i = 0; i < count; i++) UserMessage.text('填充 $i')];

  group('① 工具输出：只清白名单里较旧的', () {
    test('★★★ 较旧的白名单结果被清成定稿占位符，最近 N 条原样保留', () {
      final big = '内' * 400; // 400 token（CJK 1 字/token）
      final msgs = <LLMMessage>[
        UserMessage.text('读几个文件'),
        for (var i = 0; i < 12; i++)
          FunctionExecutionResultMessage(results: [
            FunctionExecutionResult(
              id: 'read-$i',
              name: 'read_file',
              isError: false,
              arguments: '{"path":"f$i.txt"}',
              content: <UserContentPart>[TextPart(big)],
            ),
          ]),
        ...filler(30), // 保证所有工具结果都在保护窗（最近 24 条）之外
      ];

      final result = MicroCompactor().compact(msgs);

      expect(result.changed, isTrue);
      expect(result.clearedToolResults, 2,
          reason: '12 条里保留最近 10 条 ⇒ 只该清最旧 2 条');

      final kept = result.view.messages
          .whereType<FunctionExecutionResultMessage>()
          .toList();
      expect(kept, hasLength(12), reason: 'micro 不删消息，只换内容');
      expect(_partsTextOf(kept.first.results.single.content),
          ContractCompaction.clearedToolResultPlaceholder,
          reason: '最旧的 must 被清');
      expect(_partsTextOf(kept.last.results.single.content), big,
          reason: '最近的一条必须原样保留');
      expect(result.freedTokens, greaterThan(0), reason: '必须真的省下 token');
    });

    test('★★ 小结果（< microMinChars）不清 —— 换了纯亏', () {
      // ⚠️ 构造必须让"最旧的那条"**够格进入可清区**，否则这条断言测不到
      //    `microMinChars` 门槛（只要候选数 ≤ 保留配额，什么都没发生，用例就空跑）。
      //   这里：1 条小结果（最旧）+ 12 条大结果 ⇒ 可清区是"最旧 3 条"，
      //   其中最旧那条是小的 ⇒ 必须跳过，第 2、3 条（大的）必须被清。
      final msgs = <LLMMessage>[
        UserMessage.text('开始'),
        FunctionExecutionResultMessage(results: [
          FunctionExecutionResult(
            id: 'read-small',
            name: 'read_file',
            isError: false,
            arguments: '{}',
            content: <UserContentPart>[TextPart('ok')], // 2 字符 < 200
          ),
        ]),
        for (var i = 0; i < 12; i++)
          FunctionExecutionResultMessage(results: [
            FunctionExecutionResult(
              id: 'read-$i',
              name: 'read_file',
              isError: false,
              arguments: '{}',
              content: <UserContentPart>[TextPart('内' * 400)],
            ),
          ]),
        ...filler(40),
      ];

      final result = MicroCompactor().compact(msgs);

      expect(result.clearedToolResults, 2,
          reason: '13 条候选里保留最近 10 条 ⇒ 可清区 3 条，其中那条小的必须跳过');
      expect(result.view.clearedRefs.containsKey('read-small'), isFalse,
          reason: '★ 小结果不许清（占位符比原文还长，清了纯亏）');
      final kept = result.view.messages
          .whereType<FunctionExecutionResultMessage>()
          .toList();
      expect(_partsTextOf(kept.first.results.single.content), 'ok',
          reason: '小结果必须原样保留');
      expect(
        kept.where((m) => m.results.any((r) =>
            _partsTextOf(r.content) ==
            ContractCompaction.clearedToolResultPlaceholder)),
        hasLength(2),
        reason: '大的那两条（可清区里其余的）必须被清',
      );
    });

    test('★★★ 非白名单（写类）工具的输出一字不动', () {
      final big = '内' * 400;
      final msgs = <LLMMessage>[
        FunctionExecutionResultMessage(results: [
          FunctionExecutionResult(
            id: 'write-1',
            name: 'write_file',
            isError: false,
            arguments: '{"path":"a.html"}',
            content: <UserContentPart>[TextPart(big)],
          ),
          FunctionExecutionResult(
            id: 'shell-1',
            name: 'run_shell_command', // 子串 shell ⇒ 白名单内
            isError: false,
            arguments: '{}',
            content: <UserContentPart>[TextPart(big)],
          ),
        ]),
        ...filler(40),
      ];

      // 只有一个白名单结果（shell），保留最近 10 条 ⇒ 0 条被清
      final result = MicroCompactor().compact(msgs);
      expect(result.clearedToolResults, 0,
          reason: '唯一一条白名单结果落在"最近 10 条"里，不该清');

      // 再放 11 条 shell 结果，让最早那条落进可清区
      final more = <LLMMessage>[
        ...msgs.take(1),
        for (var i = 0; i < 11; i++)
          FunctionExecutionResultMessage(results: [
            FunctionExecutionResult(
              id: 'shell-$i',
              name: 'run_shell_command',
              isError: false,
              arguments: '{}',
              content: <UserContentPart>[TextPart('内' * 400)],
            ),
          ]),
        ...filler(40),
      ];
      final result2 = MicroCompactor().compact(more);
      final writeMsg = result2.view.messages
          .whereType<FunctionExecutionResultMessage>()
          .first;
      final writeResult =
          writeMsg.results.firstWhere((r) => r.id == 'write-1');
      expect(_partsTextOf(writeResult.content), big,
          reason: '★ 写类工具（write_file）的结果不许清 —— 那是"改了什么"的证据');
      expect(
        result2.view.clearedRefs.keys.any((k) => k.startsWith('shell-')),
          isTrue,
          reason: '较旧的 shell 结果该被清');
    });
  });

  group('② 原始记录不删 + 记账可追溯', () {
    test('★★★ 入参对象与列表都不被修改（纯函数），clearedRefs 指回原 id', () {
      final big = '内' * 400;
      final originalResult = FunctionExecutionResult(
        id: 'read-x',
        name: 'read_file',
        isError: false,
        arguments: '{"path":"x.txt"}',
        content: <UserContentPart>[TextPart(big)],
      );
      final originalMessage = FunctionExecutionResultMessage(
        results: [originalResult],
      );
      // 12 条同类结果 ⇒ 最旧那条（本条）会被清
      final msgs = <LLMMessage>[
        originalMessage,
        for (var i = 0; i < 11; i++)
          FunctionExecutionResultMessage(results: [
            FunctionExecutionResult(
              id: 'read-$i',
              name: 'read_file',
              isError: false,
              arguments: '{}',
              content: <UserContentPart>[TextPart(big)],
            ),
          ]),
        ...filler(30),
      ];

      final result = MicroCompactor().compact(msgs);

      // 视图变了
      expect(_partsTextOf(result.view.messages.first is FunctionExecutionResultMessage
              ? (result.view.messages.first as FunctionExecutionResultMessage)
                  .results
                  .single
                  .content
              : const <UserContentPart>[]),
          ContractCompaction.clearedToolResultPlaceholder);
      // 原始对象一个字段都没动
      expect(_partsTextOf(originalResult.content), big,
          reason: '★★ 原始结果对象被改写了 —— 那就等于删了原始记录');
      expect(msgs.first, same(originalMessage),
          reason: '★ 入参列表里的对象不该被替换（新视图才是副本）');
      // 记账能追溯
      final ref = result.view.clearedRefs['read-x'];
      expect(ref, isNotNull, reason: '必须能按原 id 找到清理记录');
      expect(ref!.originalChars, big.length,
          reason: '要记原始字符数，才知道"原来多大、要不要恢复"');
      expect(ref.kind, ClearedKind.toolResult);
    });
  });

  group('③ 媒体块：超阈值的旧块被清、未超阈值的不动', () {
    test('★★★ 旧大图/长视频 ⇒ [media cleared]；小图原样保留', () {
      final bigBase64 = 'A' * 40000; // 体量代理 = 10000 token > 2000
      final smallBase64 = 'B' * 4000; // 体量代理 = 1000 token < 2000
      final bigImage = ModelImagePart(bigBase64, mimeType: 'image/png');
      final smallImage = ModelImagePart(smallBase64, mimeType: 'image/jpeg');
      final bigVideo = VideoPart('C' * 40000, 'video/mp4');

      final msgs = <LLMMessage>[
        UserMessage.text('看图和视频'),
        ModelMessage(
          model: 'm',
          stopReason: 'stop',
          textOutput: '图收到了',
          imageOutputs: [bigImage, smallImage],
        ),
        UserMessage(<UserContentPart>[
          TextPart('另外看这个视频'),
          bigVideo,
        ]),
        ...filler(30), // 把上面三条挤出保护窗
      ];

      final result = MicroCompactor().compact(msgs);

      expect(result.clearedMedia, 2, reason: '大图 + 长视频各一块');
      final modelMsg = result.view.messages[1] as ModelMessage;
      expect(modelMsg.imageOutputs, hasLength(1),
          reason: '小图必须留着');
      expect(modelMsg.imageOutputs.single.base64Data, smallBase64);
      expect(modelMsg.textOutput, contains(ContractCompaction.clearedMediaPlaceholder),
          reason: '清掉媒体要留可见痕迹（模型要知道这里原本有图）');
      final userMsg = result.view.messages[2] as UserMessage;
      expect(userMsg.contents.whereType<VideoPart>(), isEmpty);
      expect(
        userMsg.contents
            .whereType<TextPart>()
            .map((p) => p.text)
            .join(),
        contains(ContractCompaction.clearedMediaPlaceholder),
      );
      // 记账：kind = media，键是确定性合成键
      expect(
        result.view.clearedRefs.values
            .where((r) => r.kind == ClearedKind.media)
            .length,
        2,
      );
      final refs = result.view.clearedRefs.values
          .where((r) => r.kind == ClearedKind.media)
          .toList();
      expect(refs.map((r) => r.originalChars).toSet(), {40000});
      // 原始消息对象没动
      final original = msgs[1] as ModelMessage;
      expect(original.imageOutputs, hasLength(2),
          reason: '★ 原始消息的 imageOutputs 不许被改（只改视图）');
    });

    test('★★ 未超阈值的媒体块完全不动（阈值是"值不值得清"，不是"图就得清"）', () {
      final smallImage = ModelImagePart('B' * 4000, mimeType: 'image/jpeg');
      final msgs = <LLMMessage>[
        ModelMessage(
          model: 'm',
          stopReason: 'stop',
          textOutput: '图收到了',
          imageOutputs: [smallImage],
        ),
        ...filler(30),
      ];

      final result = MicroCompactor().compact(msgs);

      expect(result.changed, isFalse);
      expect(result.clearedMedia, 0);
      expect((result.view.messages.first as ModelMessage).imageOutputs, hasLength(1));
      expect(result.view.messages.first, same(msgs.first),
          reason: '没动过就该原样返回同一个对象（省内存也便于对账）');
    });

    test('★★ 保护窗内的媒体块不清（刚发来的图模型马上要用）', () {
      // ⚠️ 必须让"窗内的媒体块"数量 > 保留配额(10)，否则 `keepRecent` 会替
      //    `protectedRecentMessages` 兜住，用例就测不到保护窗本身。
      //   这里 12 条大图全部落在最近 24 条里 ⇒ 本层什么都不该做。
      final bigImage = ModelImagePart('A' * 40000, mimeType: 'image/png');
      final msgs = <LLMMessage>[
        ...filler(20),
        for (var i = 0; i < 12; i++)
          ModelMessage(
            model: 'm',
            stopReason: 'stop',
            textOutput: '图 $i',
            imageOutputs: [bigImage],
          ),
      ];

      final result = MicroCompactor().compact(msgs);

      expect(result.clearedMedia, 0, reason: '★ 保护窗内的媒体块不许清');
      expect(result.changed, isFalse);
    });
  });

  group('④ SendView / 截断（/rewind 用，原始历史不动）', () {
    test('★★★ 截断到最近 N 轮：不改原始列表，切点不拆调用/结果', () {
      final msgs = <LLMMessage>[
        UserMessage.text('第 1 轮'),
        ModelMessage(
          model: 'm',
          functionCalls: [
            FunctionCall(id: 'c1', name: 'read_file', arguments: '{}'),
          ],
        ),
        FunctionExecutionResultMessage(results: [
          FunctionExecutionResult(
            id: 'c1',
            name: 'read_file',
            isError: false,
            arguments: '{}',
            content: <UserContentPart>[TextPart('ok')],
          ),
        ]),
        UserMessage.text('第 2 轮'),
        ModelMessage(model: 'm', textOutput: '答'),
        UserMessage.text('第 3 轮'),
      ];
      final before = List<LLMMessage>.of(msgs);

      final view = truncateSendViewToRounds(msgs, 2);

      expect(view.messages.length, lessThan(msgs.length));
      expect(view.messages.first, isA<UserMessage>());
      expect(view.estTokens, greaterThan(0));
      expect(msgs.length, before.length, reason: '★ 截断只作用于视图，原始历史不动');
      expect(msgs.first, same(before.first));
      // 切点落在 tool result 上时，前移到它的调用之前
      final view1 = truncateSendViewToRounds(msgs, 3); // 从"第 1 轮"开始
      expect(view1.messages.first, isA<UserMessage>());
      expect(view1.messages.length, msgs.length, reason: '3 轮都在，不截断');
    });

    test('★★ 轮数给离谱值也不抛：0 ⇒ 只留最后一条；负 ⇒ 同 0', () {
      final msgs = <LLMMessage>[
        UserMessage.text('一'),
        ModelMessage(model: 'm', textOutput: '二'),
      ];
      expect(truncateSendViewToRounds(msgs, 0).messages, hasLength(1));
      expect(truncateSendViewToRounds(msgs, -3).messages, hasLength(1));
      expect(truncateSendViewToRounds(const <LLMMessage>[], 2).messages, isEmpty);
    });
  });
}
