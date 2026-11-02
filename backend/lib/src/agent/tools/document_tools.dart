// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **文档读取工具（V0.4 T1-4，2026-11-02）** —— `read_document`。
//
// 读 docx/xlsx/pptx/pdf 的文本；解析在 `document_read.dart`（零依赖）。
//
// ## 不假装
//
// 能力缺失（宿主没实现 `readBytes`）⇒ 一调用就失败并明说；
// 格式不支持 / 解析失败 / 无文本层 ⇒ 明确原因（不返回空成功）。
library;

import 'dart:typed_data';

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';
import '../document_read.dart';

/// 构建文档读取工具。
List<Tool> buildDocumentTools(ToolFactory f, Capabilities caps) {
  final ws = caps.workspace;

  return [
    f.build(
      name: 'read_document',
      description: '读取工作区里的**文档**并提取文本（支持 .docx / .xlsx / .pptx / .pdf）。'
          'PDF 只提文本层（扫描件没有文本层时会明确说明，不做 OCR）。'
          '二进制/普通文本文件请用 `read_file`。',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '相对工作区的文档路径（.docx/.xlsx/.pptx/.pdf）。',
          },
        },
        'required': ['path'],
      },
      isAvailable: () => ws != null,
      unavailableReason: '当前环境没有工作区能力，读不了文档',
      run: (args) async {
        final path = requireString(args, 'path').trim();
        if (path.isEmpty) {
          return const CapabilityFailure('path 不能为空。');
        }
        final lower = path.toLowerCase();
        if (!(lower.endsWith('.docx') ||
            lower.endsWith('.xlsx') ||
            lower.endsWith('.pptx') ||
            lower.endsWith('.pdf'))) {
          return const CapabilityFailure(
            '格式不支持（只认 .docx / .xlsx / .pptx / .pdf）；'
            '普通文本/代码请用 read_file。',
          );
        }
        // 字节读取：能力层负责"不支持 ⇒ 明确失败"
        final raw = await ws!.readBytes(path, maxBytes: kDocumentMaxBytes);
        final bytes = _bytesOf(raw);
        if (bytes == null) {
          return raw is CapabilityFailure
              ? raw
              : const CapabilityFailure('读取文档字节失败（宿主未返回 bytes）');
        }
        final doc = readDocument(Uint8List.fromList(bytes), path);
        if (!doc.ok) {
          return CapabilityFailure(doc.error ?? '文档解析失败');
        }
        final buf = StringBuffer();
        buf.writeln('文档：$path');
        if (doc.pages != null) buf.writeln('页数：${doc.pages}');
        if (doc.tables != null) buf.writeln('表数：${doc.tables}');
        buf.writeln('---');
        buf.write(doc.text);
        return CapabilitySuccess(buf.toString());
      },
    ),
  ];
}

/// 从能力结果里取 bytes（约定放在 metadata['bytes']）。
List<int>? _bytesOf(CapabilityResult r) {
  if (r is! CapabilitySuccess) return null;
  final meta = r.metadata;
  final raw = meta?['bytes'];
  if (raw is List) {
    return [for (final b in raw) if (b is int) b];
  }
  return null;
}
