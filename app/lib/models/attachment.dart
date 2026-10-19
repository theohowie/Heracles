/// 附件模型 —— 用户上传给 LLM 的文件/照片。
///
/// ## 为什么只存路径不存内容
///
/// 手机上的照片动辄几 MB，base64 塞进消息流会：
/// 1. 撑爆内存（Flutter 侧 + Kotlin 侧各一份）
/// 2. 拖慢每次重建
/// 3. 让 `HMessage` 变得很重
///
/// **只传路径**，真正读取由 Kotlin 侧在做上下文组装时按需进行。
library;

/// 附件类型
enum AttachmentKind {
  /// 图片（照片、截图）—— 将来走多模态
  image,

  /// 文本/代码文件 —— 内容直接进上下文
  text,

  /// 其它二进制 —— 只能提供文件名与大小
  binary,
}

/// 一个附件
class HAttachment {
  const HAttachment({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    this.sizeBytes = 0,
  });

  final String id;

  /// 显示名（文件名）
  final String name;

  /// 手机上的绝对路径 —— **内容不在这里**
  final String path;

  final AttachmentKind kind;
  final int sizeBytes;

  bool get isImage => kind == AttachmentKind.image;

  /// 人类可读的大小
  String get sizeLabel {
    if (sizeBytes < 1024) return '${sizeBytes}B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(0)}KB';
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  /// 从扩展名推断类型。
  ///
  /// **不做内容嗅探** —— 那需要读文件，而我们刻意不读。
  /// 扩展名判断对"这个文件该怎么处理"足够。
  static AttachmentKind kindOf(String fileName) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
    const texts = {
      'txt', 'md', 'markdown', 'json', 'yaml', 'yml', 'toml', 'ini', 'cfg',
      'kt', 'kts', 'java', 'py', 'js', 'ts', 'tsx', 'jsx', 'dart', 'go', 'rs',
      'c', 'cpp', 'h', 'hpp', 'cs', 'rb', 'php', 'swift', 'sh', 'bash', 'zsh',
      'sql', 'xml', 'html', 'htm', 'css', 'scss', 'vue', 'gradle', 'properties',
      'log', 'csv', 'tsv',
    };
    if (images.contains(ext)) return AttachmentKind.image;
    if (texts.contains(ext)) return AttachmentKind.text;
    return AttachmentKind.binary;
  }
}
