/// **多模态输入的边界类型**（2026-10-23 新增）。
///
/// ## 为什么需要这个文件（而不是让 App 直接用框架的 `ImagePart`）
///
/// `app/pubspec.yaml` **不直接依赖** `dart_agent_core`（它只是 `backend/` 的
/// 传递依赖）。App 侧一旦 `import 'package:dart_agent_core/...'` 就会触发
/// `depend_on_referenced_packages`，并糊掉"**谁的依赖谁负责**"这条边界 ——
/// 这个仓库已经在 `local_agent.dart` 里为 `LLMMessage` 明确记过同一条判断。
///
/// 所以：**App 只传 base64 + mime 这种纯数据**，由 backend（框架的合法持有者）
/// 翻译成 `ImagePart`。多模态如此，将来的音频/PDF 输入照此办理。
///
/// ## 为什么不用 `Map<String, dynamic>`
///
/// 图片是**要进请求体**的东西，字段名写错要到真机上 400 才发现。
/// 用一个小类让编译器把关，并且 `base64Data` / `mimeType` 的语义一眼可见。
library;

import 'package:dart_agent_core/dart_agent_core.dart'
    show ImagePart, UserContentPart;

/// 一张已经**压缩编码好**的图片（App 侧产出，backend 消费）。
///
/// ⚠️ 约定：`base64Data` 是**纯 base64**（不带 `data:image/png;base64,` 前缀），
/// 前缀由 provider 自己拼 —— 先加前缀会被服务端当成非法 base64。
class ImageInput {
  const ImageInput({required this.base64Data, required this.mimeType});

  /// 纯 base64（无 data URI 前缀）。
  final String base64Data;

  /// 如 `image/png`。必须与真实字节一致，否则部分 provider 会拒绝。
  final String mimeType;

  /// 解码后的近似字节数（用于诊断/日志，不参与请求）。
  int get approxBytes => (base64Data.length * 3) ~/ 4;

  @override
  String toString() => 'ImageInput($mimeType, ~${approxBytes ~/ 1024} KB)';
}

/// 纯数据 → 框架内容块。
///
/// 顺序与入参一致（调用方按用户上传顺序传，模型看到的顺序就一致）。
List<UserContentPart> buildImageParts(List<ImageInput> images) => [
      for (final img in images) ImagePart(img.base64Data, img.mimeType),
    ];