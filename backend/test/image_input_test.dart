/// 图片输入（多模态）的接线测试 —— 2026-10-23。
///
/// ## 为什么必须有这一组测试
///
/// 用户的质问是：**"大模型都有识图，为什么给 agent 后就不能了？"**
/// 排查结果是**图片在链路上被逐段丢弃**：
///
/// ```
/// AgentBridge.run(attachments:)  ❌ 收了参数没往下传
/// LocalAgentExecutor.run()       ❌ 签名里根本没有附件
/// HeraclesAgent.run()            ❌ 只收 String，首轮硬编码纯文本
/// ```
///
/// 修完之后，**唯一能证明"图真的进了请求体"的地方就是这里** ——
/// 真机截图只能证明界面上有图，证明不了请求里有图。
///
/// 本文件盯三件事：
/// 1. `images` 非空 ⇒ 请求里的用户消息**真的带图片块**（不是只有文字）；
/// 2. `images` 为空 ⇒ **完全走老路径**（不能因为加了多模态就让纯文本请求变样）；
/// 3. 文本与图片的**顺序**（文字在前）—— 顺序错了会改变模型的理解方式。
///
/// 做法与 `agent_run_e2e_test.dart` 一致：**不发任何网络请求**，
/// 用一个假 client 把 `run() → _drive() → 首轮消息` 这条链真的跑一遍，
/// 再从假 client 手里把它**收到的那份消息**要回来检查。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 一个 1×1 的透明 PNG（base64）—— 真实且极小，避免用假字节自欺。
const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
    'q842iQAAAABJRU5ErkJggg==';

/// 假 client：只回答一轮正文，并把**收到的消息**记下来。
class _CapturingClient implements LLMClient {
  _CapturingClient(this.answer);

  final String answer;

  /// 每次调用收到的完整消息（我们要检查的就是第 0 次里的用户消息）。
  final List<List<LLMMessage>> seen = [];

  ModelMessage _build() => ModelMessage(
        model: 'test-model',
        // ⚠️ `stopReason` 必须给：框架在校验 `stopReason == null` 时会判定
        //    "模型返回空停止原因"并重试 3 次，然后抛 loopDetection。
        stopReason: 'stop',
        textOutput: answer,
      );

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    seen.add(List.of(messages));
    return _build();
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    seen.add(List.of(messages));
    final msg = _build();
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(modelMessage: msg),
    ]);
  }

  /// 第一次调用里那条**用户消息**（找不到就返回 null）。
  UserMessage? firstUserMessage() {
    if (seen.isEmpty) return null;
    for (final m in seen.first) {
      if (m is UserMessage) return m;
    }
    return null;
  }
}

HeraclesAgent _agent(LLMClient client) => HeraclesAgent(
      config: const BackendConfig(
        apiKey: 'test-not-used',
        modelName: 'test-model',
        baseUrl: 'http://127.0.0.1:1', // 假 client 不会真的连它
      ),
      // 不传 workspace：本测试不碰工具，只关心首轮消息的形状。
      capabilities: const Capabilities(),
      options: const RunOptions(maxTurns: 4, maxToolCalls: 8),
      client: client,
    );

/// 收干事件流（带超时：超时即失败 —— 卡住本身就是 bug）。
Future<void> _drain(Stream<HeraclesEvent> s) async {
  await for (final _ in s.timeout(const Duration(seconds: 10))) {}
}

void main() {
  group('ImageInput 边界类型', () {
    test('approxBytes 按 base64 长度估算（3/4）', () {
      const img = ImageInput(base64Data: 'AAAA', mimeType: 'image/png');
      expect(img.approxBytes, 3);
    });

    test('toString 带 mime 与大概体积（排障用）', () {
      final img = ImageInput(
        base64Data: base64Encode(List<int>.filled(2048, 0)),
        mimeType: 'image/png',
      );
      expect(img.toString(), contains('image/png'));
      expect(img.toString(), contains('KB'));
    });

    test('buildImageParts 逐张翻译且保持顺序', () {
      final parts = buildImageParts(const [
        ImageInput(base64Data: 'AA', mimeType: 'image/png'),
        ImageInput(base64Data: 'BB', mimeType: 'image/jpeg'),
      ]);
      expect(parts.length, 2);
      expect(parts[0], isA<ImagePart>());
      expect((parts[0] as ImagePart).base64Data, 'AA');
      expect((parts[0] as ImagePart).mimeType, 'image/png');
      expect((parts[1] as ImagePart).mimeType, 'image/jpeg');
    });
  });

  group('图片进请求体（端到端，真跑 Agent）', () {
    test('★★ 有图 ⇒ 用户消息里既有文字也有图片块，且文字在前', () async {
      final client = _CapturingClient('这是一张 1×1 的透明图片。');

      await _drain(_agent(client).run(
        '这张图里是什么？',
        images: const [
          ImageInput(base64Data: _tinyPngBase64, mimeType: 'image/png'),
        ],
      ));

      final userMsg = client.firstUserMessage();
      expect(userMsg, isNotNull, reason: '必须有用户消息');

      final parts = userMsg!.contents;
      expect(parts.length, 2, reason: '文字 1 块 + 图片 1 块');

      // 顺序：文字在前（部分模型把"图在前"当成历史附件而忽略）
      expect(parts[0], isA<TextPart>());
      expect((parts[0] as TextPart).text, '这张图里是什么？');
      expect(parts[1], isA<ImagePart>());

      final img = parts[1] as ImagePart;
      expect(img.mimeType, 'image/png');
      expect(img.base64Data, _tinyPngBase64);
      // 纯 base64，**不带** data URI 前缀（带前缀会被服务端判非法）
      expect(img.base64Data.startsWith('data:'), isFalse);
    });

    test('★★ 无图 ⇒ 完全走老路径（内容块数为 1，不加壳）', () async {
      final client = _CapturingClient('好的。');
      await _drain(_agent(client).run('你好'));

      final userMsg = client.firstUserMessage()!;
      expect(userMsg.contents.length, 1,
          reason: '不能因为支持了多模态就给纯文本请求加壳');
      expect((userMsg.contents.first as TextPart).text, '你好');
    });

    test('★★ 多图 ⇒ 全部进入，顺序与入参一致', () async {
      final client = _CapturingClient('两张图都看到了。');
      await _drain(_agent(client).run(
        '对比这两张图',
        images: const [
          ImageInput(base64Data: 'R0lGOD1', mimeType: 'image/gif'),
          ImageInput(base64Data: 'UE5H', mimeType: 'image/png'),
        ],
      ));

      final parts = client.firstUserMessage()!.contents;
      expect(parts.length, 3);
      expect((parts[1] as ImagePart).mimeType, 'image/gif');
      expect((parts[2] as ImagePart).mimeType, 'image/png');
    });

    test('图片块里不含 data URI 前缀（否则服务端按非法 base64 拒绝）', () async {
      final client = _CapturingClient('ok');
      await _drain(_agent(client).run(
        'x',
        images: const [
          ImageInput(base64Data: _tinyPngBase64, mimeType: 'image/png'),
        ],
      ));

      final parts = client.firstUserMessage()!.contents;
      final img = parts.whereType<ImagePart>().single;
      expect(img.base64Data.contains('base64,'), isFalse);
    });
  });
}