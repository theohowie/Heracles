/// **文件管理类工具** —— 删除、移动、复制。
///
/// ## 为什么单独一个文件（不跟 file_tools 混）
///
/// 这三个工具**有破坏性**。它们和"读/写/列"在风险等级上不同：
/// - 读错了只是浪费 token
/// - **删错了用户的数据就没了**
///
/// 分文件是为了让"哪些工具危险"在代码结构上可见 ——
/// 将来加审批门禁时，看文件名就知道要挂哪一组。
///
/// ## 不在这里做的是
///
/// **不自己做递归预扫描**。旧实现有"递归删除前先预扫描，超限时一个文件都不删"
/// 的逻辑（防止删到一半失败）。那个约束应该由能力层实现 ——
/// 因为只有它知道文件系统是 POSIX 还是 SAF（SAF 的 delete 对目录天然递归）。
/// 工具层只负责"把用户意图翻译成能力调用"。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 构建文件管理工具。
List<Tool> buildFileManageTools(ToolFactory f, Capabilities caps) {
  final ws = caps.workspace;
  return [
    // ------------------------------------------------------------------ 删除
    f.build(
      name: 'delete_path',
      description: '删除文件或目录。'
          '⚠️ 不可恢复。删除非空目录必须显式传 recursive=true。'
          '删除前请确认路径正确 —— 这是唯一会造成数据丢失的工具。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要删除的相对路径。',
          },
          'recursive': {
            'type': 'boolean',
            'description': '是否递归删除非空目录。默认 false（目录非空会失败）。',
            'default': false,
          },
        },
        'required': ['path'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final path = requireString(args, 'path');
        final recursive = optionalBool(args, 'recursive') ?? false;
        return ws!.delete(path, recursive: recursive);
      },
    ),

    // ------------------------------------------------------------------ 移动
    f.build(
      name: 'move_path',
      description: '移动或重命名文件/目录。'
          '跨目录移动时请确保目标父目录存在（否则会失败，不会自动创建）。',
      parameters: {
        'type': 'object',
        'properties': {
          'from': {
            'type': 'string',
            'description': '源路径。',
          },
          'to': {
            'type': 'string',
            'description': '目标路径。',
          },
        },
        'required': ['from', 'to'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final from = requireString(args, 'from');
        final to = requireString(args, 'to');
        return ws!.move(from, to);
      },
    ),

    // ------------------------------------------------------------------ 复制
    f.build(
      name: 'copy_path',
      description: '复制文件或目录（保留原文件不动）。'
          '适合"另存一份再改"的场景；如果只是改名或换位置，用 move_path 更省 IO。',
      parameters: {
        'type': 'object',
        'properties': {
          'from': {
            'type': 'string',
            'description': '源路径。',
          },
          'to': {
            'type': 'string',
            'description': '目标路径。',
          },
        },
        'required': ['from', 'to'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final from = requireString(args, 'from');
        final to = requireString(args, 'to');
        return ws!.copy(from, to);
      },
    ),
  ];
}
