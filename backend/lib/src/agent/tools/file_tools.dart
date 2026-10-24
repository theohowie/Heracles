/// **文件类工具** —— 读写、列目录、查找、搜索、编辑、打补丁。
///
/// ## JSON Schema 用真实类型
///
/// 旧实现 55 个参数**全是 `string`**（GBNF 时代只能出扁平标量），
/// 导致模型必须把 `limit` 写成 `"80"`，然后在服务端被拒或本地解析失败。
///
/// 这里 `offset` / `limit` 是 `integer`，`numbered` / `recursive` 是 `boolean`。
/// **云端原生 function calling 完整支持这些类型**（真机四轮验证过）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 构建所有文件类工具。
List<Tool> buildFileTools(ToolFactory f, Capabilities caps) {
  final ws = caps.workspace;
  return [
    // ------------------------------------------------------------------ 列目录
    f.build(
      name: 'list_files',
      description: '列出工作区中某个目录的内容。'
          '不传 path 则列工作区根目录。返回每项的名称、类型（文件/目录）、大小。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的目录路径，如 "src/lib"。省略 = 工作区根目录。',
          },
          'recursive': {
            'type': 'boolean',
            'description': '是否递归列出子目录。默认 false。',
            'default': false,
          },
          'max_entries': {
            'type': 'integer',
            'description': '最多返回多少项，默认 200。超过时如实告知被截断的数量。',
            'default': 200,
            'minimum': 1,
            'maximum': 10000,
          },
        },
        'required': <String>[],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final path = optionalString(args, 'path') ?? '';
        final recursive = optionalBool(args, 'recursive') ?? false;
        final maxEntries = optionalInt(args, 'max_entries') ?? 200;
        return ws!.list(path, recursive: recursive, maxEntries: maxEntries);
      },
    ),

    // ------------------------------------------------------------------ 读文件
    f.build(
      name: 'read_file',
      description: '读取工作区中某个文件的内容。大文件可用 offset/limit 读指定行区间。'
          '返回内容包含行号，便于后续用 edit 精确修改。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的文件路径。',
          },
          'offset': {
            'type': 'integer',
            'description': '起始行号（从 1 开始）。默认 1。',
            'default': 1,
            'minimum': 1,
          },
          'limit': {
            'type': 'integer',
            'description': '读取多少行。0 或省略 = 读到文件末尾。',
            'default': 0,
            'minimum': 0,
            'maximum': 1000000,
          },
        },
        'required': ['path'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final path = requireString(args, 'path');
        final offset = optionalInt(args, 'offset') ?? 1;
        final limit = optionalInt(args, 'limit') ?? 0;
        return ws!.read(path, offset: offset, limit: limit);
      },
    ),

    // ------------------------------------------------------------------ 写文件
    f.build(
      name: 'write_file',
      description: '把内容完整写入文件（覆盖已有内容）。'
          '如果文件不存在会自动创建；父目录不存在需要先 mkdir。'
          '⚠️ 这是覆盖写，不是追加。追加请先 read_file 再 write_file 全文。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的文件路径。',
          },
          'content': {
            'type': 'string',
            'description': '要写入的完整内容。支持多行、中文、任意字符。',
          },
        },
        'required': ['path', 'content'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final path = requireString(args, 'path');
        final content = requireString(args, 'content');
        return ws!.write(path, content);
      },
    ),

    // -------------------------------------------------------------------- 编辑
    f.build(
      name: 'edit',
      description: '把文件中的一段文本替换成另一段。'
          'old_string 必须在文件中**唯一出现**，否则会报错（避免改错位置）。'
          '这是改代码的首选工具 —— 比 write_file 全文重写更安全、更省 token。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的文件路径。',
          },
          'old_string': {
            'type': 'string',
            'description': '要被替换的原文。必须与文件内容逐字符一致（含缩进）。',
          },
          'new_string': {
            'type': 'string',
            'description': '替换后的新文本。',
          },
        },
        'required': ['path', 'old_string', 'new_string'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final path = requireString(args, 'path');
        final oldStr = requireString(args, 'old_string');
        final newStr = requireString(args, 'new_string');
        return ws!.edit(path, oldStr, newStr);
      },
    ),

    // ---------------------------------------------------------------- 打补丁
    f.build(
      name: 'apply_patch',
      description: '应用 unified diff 格式的补丁到文件。'
          '适合一次改多处；单处修改用 edit 更直观。'
          '补丁格式：@@ 行号 @@ 标记的上下文行（+ 开头为新增，- 开头为删除）。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的文件路径。',
          },
          'patch': {
            'type': 'string',
            'description': 'unified diff 格式的补丁内容。',
          },
        },
        'required': ['path', 'patch'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final path = requireString(args, 'path');
        final patch = requireString(args, 'patch');
        return ws!.applyPatch(path, patch);
      },
    ),

    // -------------------------------------------------------------------- mkdir
    f.build(
      name: 'mkdir',
      description: '创建目录（含所有不存在的父目录）。已存在不会报错。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的目录路径。',
          },
        },
        'required': ['path'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async => ws!.mkdir(requireString(args, 'path')),
    ),

    // ------------------------------------------------------------------ 找文件
    f.build(
      name: 'find_files',
      description: '按 glob 模式在工作区里查找文件。'
          '支持 ** 递归、* 通配、? 单字符、[abc] 字符集、{a,b} 多选。'
          '例："**/*.kt"、"src/{main,test}/**/*.dart"。',
      parameters: {
        'type': 'object',
        'properties': {
          'pattern': {
            'type': 'string',
            'description': 'glob 模式，如 "**/*.kt"。',
          },
          'max_results': {
            'type': 'integer',
            'description': '最多返回多少个文件，默认 200。',
            'default': 200,
            'minimum': 1,
            'maximum': 10000,
          },
        },
        'required': ['pattern'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final pattern = requireString(args, 'pattern');
        final maxResults = optionalInt(args, 'max_results') ?? 200;
        return ws!.findFiles(pattern, maxResults: maxResults);
      },
    ),

    // ------------------------------------------------------------------ 搜内容
    f.build(
      name: 'grep_files',
      description: '在工作区文件中按正则表达式搜索内容。'
          '返回匹配的文件名、行号和该行内容。'
          '这是"这个函数在哪被用到"这类问题的首选工具 —— 一次搜索胜过多次读文件。',
      parameters: {
        'type': 'object',
        'properties': {
          'pattern': {
            'type': 'string',
            'description': '正则表达式，如 "class\\s+\\w+Tool"。',
          },
          'path_filter': {
            'type': 'string',
            'description': '限定搜索路径的 glob，如 "src/**/*.kt"。空 = 整个工作区。',
            'default': '',
          },
          'max_results': {
            'type': 'integer',
            'description': '最多返回多少条匹配，默认 200。',
            'default': 200,
            'minimum': 1,
            'maximum': 10000,
          },
        },
        'required': ['pattern'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境不支持文件访问',
      run: (args) async {
        final pattern = requireString(args, 'pattern');
        final pathFilter = optionalString(args, 'path_filter') ?? '';
        final maxResults = optionalInt(args, 'max_results') ?? 200;
        return ws!.grepFiles(pattern, pathFilter: pathFilter, maxResults: maxResults);
      },
    ),
  ];
}
