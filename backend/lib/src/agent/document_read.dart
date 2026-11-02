// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **文档读取（V0.4 T1-4，2026-11-02）** —— docx / xlsx / pptx / pdf 的文本提取。
//
// ## 为什么手写 zip 解析而不是加依赖
//
// `archive` 包能给 backend 用，但要改 `pubspec.yaml` + `pub get`（联网）。
// 而 OOXML 只是 **zip + xml**，zip 读取（中央目录 + store/deflate）与 XML 文本
// 提取都能用 **Dart 内置**（`dart:io` 的 ZLib 编解码）实现 —— 零依赖、可单测。
//
// ⚠️ **关键坑（2026-11-02 实测确认）**：zip 条目是 **raw deflate**，
// `ZLibDecoder()` 默认期待 **zlib 包装**（带 header）⇒ 必须 `ZLibDecoder(raw: true)`，
// 否则每个 deflate 条目都解不出来（docx/xlsx/pptx 全废）。
//
// ## 不假装原则（与其它工具一致）
//
// | 情况 | 行为 |
// |---|---|
// | 扩展名不认识 / 不是 zip | **明确报"格式不支持"**，不猜 |
// | PDF | 只提**文本层**（`(...) Tj` / `[...] TJ`）；扫描件无文本层 ⇒ 明确说"未实现 OCR" |
// | 文件过大 | 拒绝并给上限（不 OOM） |
// | 提取到 0 字符 | 明确说"没提取到文本"，不返回空成功 |
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 单次读取上限（字节）。超过就拒绝 —— 手机上解析 50MB docx 会 OOM。
const int kDocumentMaxBytes = 20 * 1024 * 1024;

/// 提取结果（成功/失败都明确）。
class DocumentText {
  const DocumentText({
    required this.ok,
    this.text = '',
    this.pages,
    this.tables,
    this.error,
  });

  final bool ok;
  final String text;

  /// PDF 页数（其它格式为 null）。
  final int? pages;

  /// xlsx 表数（其它格式为 null）。
  final int? tables;

  final String? error;
}

/// **读文档**（按扩展名分派；失败给明确原因）。
DocumentText readDocument(Uint8List bytes, String fileName) {
  if (bytes.isEmpty) {
    return const DocumentText(ok: false, error: '文件为空');
  }
  if (bytes.length > kDocumentMaxBytes) {
    return DocumentText(
      ok: false,
      error: '文件过大（${bytes.length} 字节，上限 $kDocumentMaxBytes）——请先拆分',
    );
  }
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.pdf')) return _readPdf(bytes);
  if (lower.endsWith('.docx')) return _readDocx(bytes);
  if (lower.endsWith('.xlsx')) return _readXlsx(bytes);
  if (lower.endsWith('.pptx')) return _readPptx(bytes);
  return const DocumentText(
    ok: false,
    error: '格式不支持（只认 .docx / .xlsx / .pptx / .pdf）',
  );
}

// ============================================================================
// OOXML（docx/xlsx/pptx）
// ============================================================================

DocumentText _readDocx(Uint8List bytes) {
  final entries = unzipEntries(bytes);
  if (entries == null) {
    return const DocumentText(ok: false, error: '不是合法的 docx（zip 解析失败）');
  }
  final doc = entries['word/document.xml'];
  if (doc == null) {
    return const DocumentText(ok: false, error: 'docx 缺少 word/document.xml');
  }
  // 段落分隔：`</w:p>` → 换行；`<w:tab/>` → 制表符
  final xml = doc.replaceAll('<w:tab/>', '\t').replaceAll('</w:p>', '\n');
  final text = stripXml(xml).trim();
  if (text.isEmpty) {
    return const DocumentText(ok: false, error: 'docx 里没有提取到文本');
  }
  return DocumentText(ok: true, text: text);
}

DocumentText _readXlsx(Uint8List bytes) {
  final entries = unzipEntries(bytes);
  if (entries == null) {
    return const DocumentText(ok: false, error: '不是合法的 xlsx（zip 解析失败）');
  }
  final shared = <String>[];
  final sst = entries['xl/sharedStrings.xml'];
  if (sst != null) {
    for (final m in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(sst)) {
      shared.add(stripXml(m.group(1)!));
    }
  }
  final sheets = entries.keys
      .where((k) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(k))
      .toList()
    ..sort();
  if (sheets.isEmpty) {
    return const DocumentText(ok: false, error: 'xlsx 里没有工作表');
  }
  final out = StringBuffer();
  for (var i = 0; i < sheets.length; i++) {
    out.writeln('=== 表 ${i + 1} ===');
    final xml = entries[sheets[i]]!;
    for (final row
        in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true).allMatches(xml)) {
      final cells = <String>[];
      for (final c in RegExp(r'<c([^>]*)>(.*?)</c>', dotAll: true)
          .allMatches(row.group(1)!)) {
        final attrs = c.group(1)!;
        final inner = c.group(2)!;
        final v = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(inner);
        final t = RegExp(r't="([^"]+)"').firstMatch(attrs)?.group(1);
        final raw = v?.group(1) ?? '';
        if (t == 's') {
          final idx = int.tryParse(raw);
          cells.add(
              (idx != null && idx >= 0 && idx < shared.length) ? shared[idx] : '');
        } else {
          cells.add(stripXml(raw));
        }
      }
      if (cells.any((c) => c.trim().isNotEmpty)) {
        out.writeln(cells.join('\t'));
      }
    }
  }
  final text = out.toString().trim();
  if (text.isEmpty) {
    return const DocumentText(ok: false, error: 'xlsx 里没有提取到文本');
  }
  return DocumentText(ok: true, text: text, tables: sheets.length);
}

DocumentText _readPptx(Uint8List bytes) {
  final entries = unzipEntries(bytes);
  if (entries == null) {
    return const DocumentText(ok: false, error: '不是合法的 pptx（zip 解析失败）');
  }
  int slideNo(String s) =>
      int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(s)?.group(1) ?? '') ?? 0;
  final slides = entries.keys
      .where((k) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(k))
      .toList()
    ..sort((a, b) => slideNo(a).compareTo(slideNo(b)));
  if (slides.isEmpty) {
    return const DocumentText(ok: false, error: 'pptx 里没有幻灯片');
  }
  final out = StringBuffer();
  for (var i = 0; i < slides.length; i++) {
    out.writeln('=== 第 ${i + 1} 页 ===');
    final xml = entries[slides[i]]!;
    for (final p in RegExp(r'<a:p>(.*?)</a:p>', dotAll: true).allMatches(xml)) {
      final line = stripXml(p.group(1)!).trim();
      if (line.isNotEmpty) out.writeln(line);
    }
  }
  final text = out.toString().trim();
  if (text.isEmpty) {
    return const DocumentText(ok: false, error: 'pptx 里没有提取到文本');
  }
  return DocumentText(ok: true, text: text);
}

// ============================================================================
// PDF：只提文本层
// ============================================================================

DocumentText _readPdf(Uint8List bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  if (!raw.startsWith('%PDF')) {
    return const DocumentText(ok: false, error: '不是合法的 PDF（缺少 %PDF 头）');
  }
  // 页数：`/Type /Page`（排除 /Pages）
  final pages = RegExp(r'/Type\s*/Page(?![s])').allMatches(raw).length;
  final out = StringBuffer();
  for (final m in RegExp(r'\((?:[^()\\]|\\.)*\)').allMatches(raw)) {
    final s = m.group(0)!;
    final inner = s.substring(1, s.length - 1);
    if (inner.isEmpty) continue;
    out.write(_unescapePdf(inner));
  }
  final text = out.toString().trim();
  if (text.isEmpty) {
    return DocumentText(
      ok: false,
      pages: pages,
      error: 'PDF 没有文本层（可能是扫描件；本工具未实现 OCR）',
    );
  }
  return DocumentText(ok: true, text: text, pages: pages);
}

String _unescapePdf(String s) => s
    .replaceAll(r'\(', '(')
    .replaceAll(r'\)', ')')
    .replaceAll(r'\\', r'\')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\r', '\r')
    .replaceAll(r'\t', '\t');

// ============================================================================
// 极简 zip 读取（中央目录 + store/deflate；**deflate 用 raw 解码**）
// ============================================================================

/// **解 zip**：返回 `{条目名: 文本}`（只处理 xml/rels 文本类条目；失败返回 null）。
///
/// 支持 store(0) 与 deflate(8)；不支持 zip64/加密（跳过）。
Map<String, String>? unzipEntries(Uint8List bytes) {
  try {
    var eocd = -1;
    final minPos = bytes.length - 65536 < 0 ? 0 : bytes.length - 65536;
    for (var i = bytes.length - 22; i >= minPos; i--) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x05 &&
          bytes[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return null;
    final count = _u16(bytes, eocd + 10);
    final cdOffset = _u32(bytes, eocd + 16);
    final out = <String, String>{};
    var p = cdOffset;
    for (var n = 0; n < count; n++) {
      if (p + 46 > bytes.length) break;
      if (bytes[p] != 0x50 ||
          bytes[p + 1] != 0x4b ||
          bytes[p + 2] != 0x01 ||
          bytes[p + 3] != 0x02) {
        return out; // 结构不对 ⇒ 返回已解析部分
      }
      final method = _u16(bytes, p + 10);
      final compSize = _u32(bytes, p + 20);
      final nameLen = _u16(bytes, p + 28);
      final extraLen = _u16(bytes, p + 30);
      final commentLen = _u16(bytes, p + 32);
      final localOffset = _u32(bytes, p + 42);
      final name = latin1.decode(
        bytes.sublist(p + 46, p + 46 + nameLen),
        allowInvalid: true,
      );
      p += 46 + nameLen + extraLen + commentLen;

      // 只取文本类条目（避免解出图片占内存）
      final want = name.endsWith('.xml') || name.endsWith('.rels');
      if (!want || compSize == 0) continue;
      final content = _extractLocal(bytes, localOffset, method, compSize);
      if (content != null) out[name] = content;
    }
    return out;
  } catch (_) {
    return null;
  }
}

String? _extractLocal(
  Uint8List bytes,
  int localOffset,
  int method,
  int compSize,
) {
  try {
    if (localOffset + 30 > bytes.length) return null;
    final nameLen = _u16(bytes, localOffset + 26);
    final extraLen = _u16(bytes, localOffset + 28);
    final dataStart = localOffset + 30 + nameLen + extraLen;
    final dataEnd = dataStart + compSize;
    if (dataEnd > bytes.length) return null;
    final data = bytes.sublist(dataStart, dataEnd);
    final Uint8List plain;
    if (method == 0) {
      plain = data;
    } else if (method == 8) {
      // ★ zip 条目是 **raw deflate**（无 zlib header）⇒ 必须 raw: true
      plain = Uint8List.fromList(ZLibDecoder(raw: true).convert(data));
    } else {
      return null; // 其它压缩方式（bzip2 等）⇒ 跳过
    }
    return utf8.decode(plain, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

int _u16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _u32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

/// **剥 XML 标签**：去掉标签、解码常见实体、折叠空白、按行 trim。
String stripXml(String xml) {
  var s = xml.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#160;', ' ');
  s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
  return s
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
}
