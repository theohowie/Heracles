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
///
/// [tracker] 为 null 时不做"先读再改"强制（旧行为，测试便捷入口用）；
/// 生产组装（`HeraclesAgent._buildTools`）恒传 —— 那是 K1 的架构保证。
List<Tool> buildFileTools(
  ToolFactory f,
  Capabilities caps, {
  EditReadTracker? tracker,
  Future<String> Function()? verify,
}) {
  final ws = caps.workspace;
  return [
    // ------------------------------------------------------------------ 列目录
    f.build(
      name: 'list_files',
      description: '列出工作区中某个目录的内容。'
          '不传 path 则列工作区根目录。返回每项的名称、类型（文件/目录）、大小。'
          '返回：每行一项的清单文本；超限附截断说明。',
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
          '返回内容包含行号，便于后续用 edit 精确修改。'
          '返回：带行号前缀（"   12| 内容"）的全文或指定行区间；文件不存在则报错。',
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
        final r = await ws!.read(path, offset: offset, limit: limit);
        // ★ 读成功 ⇒ 记入已读（"先读再改"的记账来源）
        if (tracker != null && r is CapabilitySuccess) tracker.markRead(path);
        // ★ SEC1（2026-10-24）：文件内容是"外部内容" —— 无条件包裹。
        //   工作区文件可能来自别处（clone/下载），同样按零信任对待。
        if (r is CapabilitySuccess) {
          return CapabilitySuccess(
            '【工作区文件内容开始 · $path】\n'
            '${r.data}\n'
            '【工作区文件内容结束】',
            metadata: r.metadata,
          );
        }
        return r;
      },
    ),

    // ------------------------------------------------------------------ 写文件
    f.build(
      name: 'write_file',
      description: '把内容完整写入文件（覆盖已有内容）。返回：写入确认（路径+字符数）。'
          '如果文件不存在会自动创建；父目录不存在需要先 mkdir。'
          '⚠️ 这是覆盖写，不是追加。追加请先 read_file 再 write_file 全文。'
          '⚠️ 覆盖**已存在**的文件前必须先 read_file（或本会话写过它）—— '
          '没读过会被拒绝，防止盲覆盖丢掉现有内容。',
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
        // ★ "先读再改"强制（K1）：覆盖**已存在**的文件前必须读过或写过；
        //   盲覆盖 = 基于猜测修改，正是这条防线要挡的。
        if (tracker != null) {
          final ex = await ws!.exists(path);
          if (ex && !tracker.canEdit(path)) {
            return const CapabilityFailure(
              '未执行：这个文件已存在，但你还没有读过它。'
              '先 read_file 看当前内容，再决定怎么写 —— '
              '盲覆盖会丢掉别人的改动（基于猜测的修改一律拒绝）。',
              isRetryable: true,
            );
          }
          // ★ K3（2026-10-25）：已读文件的大幅重写门禁 —— 读了之后再整文重写
          //   大文件（> 200 行新内容且文件原本非空）仍然要求走 edit/apply_patch
          //   的小步路径；确实需要全量替换时在 content 末尾加一行
          //   `[FULL_REWRITE]` 显式声明（模型可见的软门禁，不是硬拒绝：
          //   有些任务确实要全文重写，例如格式化）。
          if (ex) {
            final newLines = '\n'.allMatches(content).length + 1;
            if (newLines > 200 &&
                !content.contains('[FULL_REWRITE]')) {
              return CapabilityFailure(
                '未执行：这次 write_file 要写入 $newLines 行到**已存在的**文件 —— '
                '大改写请优先用 edit / apply_patch 小步修改（保留原有结构，'
                '出错可定位）。如果确实需要全文重写（如格式化、重新生成），'
                '在 content 末尾加一行 "[FULL_REWRITE]" 再试。',
                isRetryable: true,
              );
            }
          }
        }
        final r = await ws!.write(path, content);
        if (tracker != null && r is CapabilitySuccess) {
          tracker.markWritten(path);
        }
        // ★ H3/K2（2026-10-25）：写成功 ⇒ 自动跑宿主配置的验证命令，
        //   输出附在结果里 —— 模型看到失败立刻修（架构级闭环）。
        if (verify != null && r is CapabilitySuccess) {
          final v = await verify();
          return CapabilitySuccess('${r.data}\n[自动验证] $v');
        }
        return r;
      },
    ),

    // -------------------------------------------------------------------- 编辑
    f.build(
      name: 'edit',
      description: '把文件中的一段文本替换成另一段。返回：替换结果确认或失败原因（未找到/多处匹配）。'
          'old_string 必须在文件中**唯一出现**，否则会报错（避免改错位置）。'
          '⚠️ 改之前必须先 read_file 这个文件（本会话写过也算）—— 没读过会被拒绝。'
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
        // ★ "先读再改"强制（K1）：没读过/没写过就 edit = 基于猜测的修改。
        if (tracker != null && !tracker.canEdit(path)) {
          return const CapabilityFailure(
            '未执行：这个文件还没被读过。先 read_file 拿到带行号的当前内容，'
            '再 edit —— old_string 要与真实内容逐字符一致，猜是猜不中的。',
            isRetryable: true,
          );
        }
        final r = await ws!.edit(path, oldStr, newStr);
        if (tracker != null && r is CapabilitySuccess) {
          tracker.markWritten(path);
        }
        if (verify != null && r is CapabilitySuccess) {
          final v = await verify();
          return CapabilitySuccess('${r.data}\n[自动验证] $v');
        }
        return r;
      },
    ),

    // ---------------------------------------------------------------- 打补丁
    f.build(
      name: 'apply_patch',
      description: '应用 unified diff 格式的补丁到文件。返回：应用的 hunk 数与结果确认。'
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
        // ★ 同 edit：先读再改。
        if (tracker != null && !tracker.canEdit(path)) {
          return const CapabilityFailure(
            '未执行：这个文件还没被读过。先 read_file 看当前内容，再打补丁。',
            isRetryable: true,
          );
        }
        final r = await ws!.applyPatch(path, patch);
        if (tracker != null && r is CapabilitySuccess) {
          tracker.markWritten(path);
        }
        if (verify != null && r is CapabilitySuccess) {
          final v = await verify();
          return CapabilitySuccess('${r.data}\n[自动验证] $v');
        }
        return r;
      },
    ),

    // -------------------------------------------------------------------- mkdir
    f.build(
      name: 'mkdir',
      description: '创建目录（含所有不存在的父目录）。已存在不会报错。返回：创建确认。',
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
      description: '按 glob 模式在工作区里查找文件。返回：匹配的相对路径列表（每行一个）。'
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
          '返回匹配的文件名、行号和该行内容（每行一条）；超限附截断说明。'
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
