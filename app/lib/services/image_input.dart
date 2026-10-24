/// 图片附件 → 模型可读的 base64 数据块（2026-10-23 新增）。
///
/// ## 为什么这个文件必须存在
///
/// 用户质问过一句很到位的话：**"大模型都有识图，为什么给 agent 后就不能了？"**
/// 答案是：**不是模型不能，是我们在接线链上把图片弄丢了** ——
///
/// ```
/// chat_screen        ✅ 把 attachments 传进 AgentBridge.run(attachments: snapshot)
/// AgentBridge.run    ❌ 收了参数但**没往下传**（旧实现留档里 commented 掉了）
/// LocalAgentExecutor ❌ run() 只收 {request, sessionId}，没有附件参数
/// HeraclesAgent      ❌ run() 只收 String，首轮消息硬编码 [UserMessage.text(...)]
/// ⇒ 模型根本没收到图
/// ```
///
/// 本文件补上"最后一公里"：**读字节 → 缩到合理尺寸 → 编码成 `ImagePart`**。
///
/// ## 三个必须守住的约束
///
/// 1. **必须压缩**：手机照片 3–5 MB，base64 后 ×1.33 ⇒ 单图 4–7 MB 进请求体，
///    真机上大概率超时或 OOM。这里统一缩到**长边 ≤ 1568 px**（Anthropic 推荐上限），
///    质量 82 —— 对"看界面截图 / 看代码截图"完全够。
/// 2. **体积硬闸**：压缩后仍 > [kMaxImageBytes]（3 MB）就**明确失败**，
///    让用户看到"图太大"，而不是发出去等超时。
/// 3. **不支持就明说**：当前模型不支持视觉 ⇒ 不塞图，并把原因回报给用户
///    （绝不静默丢图 —— 用户会以为模型看过了）。
///
/// ## 为什么用 `dart:ui` 而不是 `package:image`
///
/// `AGENTS.md`：新增依赖必须先进 `11-复用调研.md` 并写 ADR。`package:image`
/// 只为"缩放/转码"引入一整个图像处理库，不划算。`dart:ui` 的
/// `instantiateImageCodec(targetWidth/targetHeight)` 是 Flutter 自带的
/// **原生解码 + 原生缩放**，更快也更省内存，且能直接拿到 PNG 字节。
///
/// 取舍：输出统一为 **PNG**（`toByteData(format: png)`）。PNG 比 JPEG 大，
/// 但只有"缩到 1568 长边"这一种尺寸，且我们还有 3 MB 硬闸兜底；
/// 换来的是**零新依赖**（不引包、不写 ADR）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:heracles_backend/heracles_backend.dart' show ImageInput;

import '../models/attachment.dart';

/// 压缩后单张图的体积上限（3 MB）。超过就明确失败，不硬发。
const int kMaxImageBytes = 3 * 1024 * 1024;

/// 压缩目标：长边不超过这个像素（Anthropic 官方推荐 1568）。
const int kMaxImageEdge = 1568;

/// 一次"把附件变成模型可读图片"的结果。
class ImagePrepareResult {
  const ImagePrepareResult({this.images = const [], this.notes = const []});

  /// 可直接交给 `HeraclesAgent.run(images:)` 的边界类型。
  ///
  /// 注意是 [ImageInput]（base64 + mime 的纯数据）而**不是**框架的 `ImagePart`
  /// —— App 侧不依赖 `dart_agent_core`，翻译由 backend 做。
  final List<ImageInput> images;

  /// 给用户的说明（失败原因 / 降级提示）。空 = 一切正常。
  final List<String> notes;

  bool get ok => notes.isEmpty;

  /// 有没有图真的发出去。
  bool get hasImages => images.isNotEmpty;
}

/// 把图片附件读成可发送的图片数据（带压缩与体积闸）。
///
/// 只处理 [AttachmentKind.image]；文本/二进制附件走原来的路径（不在这里）。
/// **任何一张失败都不阻断其它张** —— 逐张收集失败原因，最后一起回报。
Future<ImagePrepareResult> prepareImageParts(
  List<HAttachment> attachments,
) async {
  final images = <ImageInput>[];
  final notes = <String>[];

  for (final a in attachments) {
    if (!a.isImage) continue;
    try {
      final raw = await File(a.path).readAsBytes();
      final shrunk = await _shrinkToPng(raw);
      if (shrunk == null) {
        notes.add('图片「${a.name}」读不出来或格式不支持，已跳过。');
        continue;
      }
      if (shrunk.length > kMaxImageBytes) {
        final mb = (shrunk.length / 1024 / 1024).toStringAsFixed(1);
        notes.add(
          '图片「${a.name}」压缩后仍有 $mb MB，'
          '超过 ${(kMaxImageBytes / 1024 / 1024).toStringAsFixed(0)} MB 上限，已跳过。'
          '（建议先裁掉无关部分，或截图时只截关键区域）',
        );
        continue;
      }
      images.add(ImageInput(
        base64Data: base64Encode(shrunk),
        mimeType: 'image/png',
      ));
    } catch (e) {
      notes.add('图片「${a.name}」处理失败：${e.runtimeType}。');
    }
  }

  return ImagePrepareResult(images: images, notes: notes);
}

/// 用 `dart:ui` 原生解码 + 等比缩放到长边 ≤ [kMaxImageEdge]，输出 PNG 字节。
///
/// 解码失败（格式不支持 / 文件损坏）⇒ `null`（调用方记一条说明并跳过）。
Future<Uint8List?> _shrinkToPng(Uint8List raw) async {
  ui.Codec? codec;
  try {
    // 先只解尺寸（不分配整张位图），据此算目标边长
    codec = await ui.instantiateImageCodec(raw);
    final first = await codec.getNextFrame();
    final w = first.image.width;
    final h = first.image.height;
    final longEdge = w > h ? w : h;

    // 小图直接用原帧；大图按比例给 targetWidth/targetHeight（原生缩放）
    final needShrink = longEdge > kMaxImageEdge;
    final tw = needShrink ? (w >= h ? kMaxImageEdge : (w * kMaxImageEdge / h).round()) : w;
    final th = needShrink ? (h > w ? kMaxImageEdge : (h * kMaxImageEdge / w).round()) : h;

    first.image.dispose();

    if (needShrink) {
      codec.dispose();
      codec = await ui.instantiateImageCodec(raw, targetWidth: tw, targetHeight: th);
      final scaled = await codec.getNextFrame();
      final data = await scaled.image.toByteData(format: ui.ImageByteFormat.png);
      scaled.image.dispose();
      return data?.buffer.asUint8List();
    }

    // 不需要缩放时，仍然重新编码成 PNG —— 统一格式，避免 provider 对
    // heic/webp 支持不一致（heic 尤其：多数云端不认）
    final data = await first.image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}

/// 模型对图片的支持程度。
enum VisionSupport {
  /// 明确支持（白名单家族）。
  yes,

  /// **明确不支持**（纯文本家族）—— 发了必然失败或静默丢，所以拦下来并说清。
  no,

  /// 不知道。
  ///
  /// ## 为什么"不知道"要按"发出去"处理
  ///
  /// 一开始我把未知归到"不发"，但那是**拿猜测当事实**：
  /// 用户用的是中转站的模型（例如 `deepseek-v4.1-flash`），
  /// 我们手上没有任何一处能权威回答"它支持视觉吗"。
  /// 猜"不支持"的后果是：用户传了图，我们却不发，还告诉他"你的模型不能看图"——
  /// 如果他那个模型其实能看，这就是我们**替他做了错误决定**。
  ///
  /// 所以未知一律**发出去，让 provider 说话**：
  /// · 支持 ⇒ 正常识图；
  /// · 不支持 ⇒ provider 返回明确错误（少见的"静默忽略"情形另有说明）。
  ///
  /// 这符合仓库那条更根本的规矩：**拿不准就不要替模型做判断，如实回告**。
  unknown,
}

/// 判定口径：白名单（明确支持）/ 黑名单（明确纯文本）/ 其余未知。
VisionSupport visionSupportOf(String modelName) {
  final m = modelName.toLowerCase();

  const visionMarkers = <String>[
    'gpt-4o', 'gpt-4.1', 'gpt-4-turbo', 'gpt-4-vision', 'o1', 'o3', 'o4',
    'claude-3', 'claude-4', 'claude-sonnet', 'claude-opus', 'claude-haiku',
    'gemini', 'qwen-vl', 'qwen2-vl', 'qwen2.5-vl', 'qwen3-vl',
    'glm-4v', 'glm-4.1v', 'llava', 'internvl', 'minicpm-v', 'pixtral',
    'deepseek-vl', 'step-1v', 'yi-vl', 'moonshot-v1-vision', 'kimi-vl',
    // 多模态旗舰：名字里没带 vl 但确实有视觉
    'deepseek-v4', 'deepseek-v3.2', 'gpt-5', 'grok-4', 'grok-2-vision',
  ];
  if (visionMarkers.any(m.contains)) return VisionSupport.yes;

  const textOnlyMarkers = <String>[
    'deepseek-chat', 'deepseek-reasoner', 'deepseek-coder', 'deepseek-v3',
    'gpt-3.5', 'text-davinci', 'qwen-turbo', 'qwen-plus', 'qwen-max',
    'glm-4-flash', 'glm-4-air', 'ernie', 'hunyuan', 'abab',
  ];
  if (textOnlyMarkers.any(m.contains)) return VisionSupport.no;

  return VisionSupport.unknown;
}

/// 兼容旧调用点：`true` = 可以尝试发送（含"未知"）。
bool modelSupportsVision(String modelName) =>
    visionSupportOf(modelName) != VisionSupport.no;

/// 调试/诊断用：把结果摘要成一行。
String describeImagePrepare(ImagePrepareResult r, String modelName) {
  if (r.images.isEmpty && r.notes.isEmpty) return '无图片附件';
  if (!modelSupportsVision(modelName)) {
    return '当前模型「$modelName」不支持看图，未发送图片';
  }
  final buf = StringBuffer('发送 ${r.images.length} 张图');
  if (r.notes.isNotEmpty) buf.write('（${r.notes.length} 条被跳过）');
  return buf.toString();
}
