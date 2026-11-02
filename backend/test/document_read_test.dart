// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **文档读取测试（V0.4 T1-4）** —— docx/xlsx/pptx/pdf 文本提取。
//
// 夹具用**已验证的最小 zip 构造**（store + raw deflate；2026-11-02 探针确认
// `ZLibDecoder(raw: true)` 是解 zip deflate 的唯一正确方式）。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | docx（deflate）→ 段落文本 | raw/zlib 解码选错 ⇒ 全部解不出 |
// | ①b | store（不压缩）也能读 | 只支持压缩分支 |
// | ② | xlsx → 共享字符串 + 表数 | 共享字符串下标错 ⇒ 单元格空 |
// | ③ | pptx → 按页序输出 | 幻灯片排序错 |
// | ④ | PDF → 文本层 + 页数 | Tj 提取错 |
// | ⑤ | 未知格式/坏 zip/空文件 ⇒ 明确错误 | 假装成功 |
// | ⑥ | PDF 无文本层 ⇒ 明确"未实现 OCR" | 扫描件被当成"读到了" |
// | ⑦ | 超大文件拒绝 | OOM |
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 构造最小 zip（`compress=true` 用 **raw deflate**）。
Uint8List buildZip(Map<String, String> entries, {bool compress = true}) {
  final locals = <Uint8List>[];
  final centrals = <Uint8List>[];
  var offset = 0;
  for (final e in entries.entries) {
    final raw = utf8.encode(e.value);
    final data = compress
        ? Uint8List.fromList(ZLibEncoder(raw: true).convert(raw))
        : Uint8List.fromList(raw);
    final name = utf8.encode(e.key);
    final method = compress ? 8 : 0;

    final local = BytesBuilder()
      ..add([0x50, 0x4b, 0x03, 0x04])
      ..add([10, 0])
      ..add([0, 0])
      ..add([method, 0])
      ..add([0, 0, 0, 0])
      ..add([0, 0, 0, 0])
      ..add(_le32(data.length))
      ..add(_le32(raw.length))
      ..add(_le16(name.length))
      ..add([0, 0])
      ..add(name)
      ..add(data);

    final central = BytesBuilder()
      ..add([0x50, 0x4b, 0x01, 0x02])
      ..add([10, 0])
      ..add([10, 0])
      ..add([0, 0])
      ..add([method, 0])
      ..add([0, 0, 0, 0])
      ..add([0, 0, 0, 0])
      ..add(_le32(data.length))
      ..add(_le32(raw.length))
      ..add(_le16(name.length))
      ..add([0, 0])
      ..add([0, 0])
      ..add([0, 0])
      ..add([0, 0])
      ..add([0, 0, 0, 0])
      ..add(_le32(offset))
      ..add(name);

    locals.add(local.toBytes());
    centrals.add(central.toBytes());
    offset += local.length;
  }
  final cd = BytesBuilder();
  for (final c in centrals) {
    cd.add(c);
  }
  final cdBytes = cd.toBytes();
  final eocd = BytesBuilder()
    ..add([0x50, 0x4b, 0x05, 0x06])
    ..add([0, 0, 0, 0])
    ..add(_le16(entries.length))
    ..add(_le16(entries.length))
    ..add(_le32(cdBytes.length))
    ..add(_le32(offset))
    ..add([0, 0]);

  final out = BytesBuilder();
  for (final l in locals) {
    out.add(l);
  }
  out.add(cdBytes);
  out.add(eocd.toBytes());
  return out.toBytes();
}

List<int> _le16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _le32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  test('① docx：raw deflate 解压 + 段落分行', () {
    final xml = '<w:document><w:body>'
        '<w:p><w:r><w:t>第一段</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>第二段</w:t></w:r></w:p>'
        '</w:body></w:document>';
    final r = readDocument(buildZip({'word/document.xml': xml}), 'a.docx');
    expect(r.ok, isTrue, reason: 'raw deflate 解码正确才能读出字');
    expect(r.text, contains('第一段'));
    expect(r.text, contains('第二段'));
  });

  test('①b store（不压缩）也能读', () {
    final xml =
        '<w:document><w:p><w:r><w:t>store 模式</w:t></w:r></w:p></w:document>';
    final r = readDocument(
        buildZip({'word/document.xml': xml}, compress: false), 'b.docx');
    expect(r.ok, isTrue);
    expect(r.text, contains('store 模式'));
  });

  test('② xlsx：共享字符串 + 表数', () {
    final sst = '<sst><si><t>甲</t></si><si><t>乙</t></si></sst>';
    final sheet = '<worksheet><sheetData>'
        '<row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row>'
        '<row><c><v>42</v></c></row>'
        '</sheetData></worksheet>';
    final r = readDocument(
      buildZip({
        'xl/sharedStrings.xml': sst,
        'xl/worksheets/sheet1.xml': sheet,
      }),
      'a.xlsx',
    );
    expect(r.ok, isTrue);
    expect(r.tables, 1);
    expect(r.text, contains('甲'));
    expect(r.text, contains('乙'));
    expect(r.text, contains('42'));
  });

  test('③ pptx：按页序输出', () {
    final r = readDocument(
      buildZip({
        'ppt/slides/slide1.xml': '<p:sld><a:p><a:t>第一页字</a:t></a:p></p:sld>',
        'ppt/slides/slide2.xml': '<p:sld><a:p><a:t>第二页字</a:t></a:p></p:sld>',
      }),
      'a.pptx',
    );
    expect(r.ok, isTrue);
    expect(r.text.indexOf('第一页字'), lessThan(r.text.indexOf('第二页字')));
  });

  test('④ pdf：文本层 + 页数', () {
    final pdf = '%PDF-1.4\n'
        '1 0 obj /Type /Page\n'
        '(Hello PDF) Tj\n'
        '2 0 obj /Type /Page\n'
        '(Second page text) Tj\n'
        'trailer';
    final r = readDocument(Uint8List.fromList(latin1.encode(pdf)), 'a.pdf');
    expect(r.ok, isTrue);
    expect(r.text, contains('Hello PDF'));
    expect(r.pages, 2);
  });

  test('⑤ 未知格式 / 坏 zip / 空文件 ⇒ 明确错误（不假装成功）', () {
    expect(readDocument(Uint8List(0), 'x.docx').error, contains('空'));
    final unknown = readDocument(Uint8List.fromList([1, 2, 3]), 'a.txt');
    expect(unknown.ok, isFalse);
    expect(unknown.error, contains('格式不支持'));
    final badZip =
        readDocument(Uint8List.fromList(utf8.encode('not a zip')), 'a.docx');
    expect(badZip.ok, isFalse);
    expect(badZip.error, contains('zip'));
  });

  test('⑥ PDF 无文本层 ⇒ 明确"未实现 OCR"', () {
    final pdf =
        '%PDF-1.4\n1 0 obj /Type /Page stream image data endstream\ntrailer';
    final r = readDocument(Uint8List.fromList(latin1.encode(pdf)), 'scan.pdf');
    expect(r.ok, isFalse);
    expect(r.error, contains('OCR'), reason: '★ 扫描件不许当成"读到了"');
    expect(r.pages, 1);
  });

  test('⑦ 超大文件拒绝（不 OOM）', () {
    final r = readDocument(Uint8List(kDocumentMaxBytes + 1), 'big.docx');
    expect(r.ok, isFalse);
    expect(r.error, contains('过大'));
  });
}
