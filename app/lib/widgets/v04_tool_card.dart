// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 工具卡补充**（2026-11-02，对应 #5/T1）：web_search / read_document / notify_user。
//
// 数据只从**结构化字段**取（`call.args` / `call.result` / `call.status`），
// 不靠文本前缀猜成功/失败：
//   · `web_search`：查询词 + 来源 URL（结果里「来源：」行；没有就如实"未返回来源"）；
//   · `read_document`：文件名 + 类型（docx/xlsx/pptx/pdf）+ 页数/表数（有才显示）；
//   · `notify_user`：标题/正文 + 已发送/被拒（**没送达就是失败**）。
// 失败一律显示原因，绝不渲染成成功。

import 'package:flutter/material.dart';

import '../models/message.dart' show HToolCall, ToolStatus;
import '../theme/app_theme.dart';

/// 这三个工具的自定义明细区；其它工具返回 null（走原有渲染）。
Widget? v04ToolDetail(Hue h, HToolCall call) {
  switch (call.tool) {
    case 'web_search':
      return _webSearch(h, call);
    case 'read_document':
      return _readDocument(h, call);
    case 'notify_user':
      return _notifyUser(h, call);
    default:
      return null;
  }
}

bool _failed(HToolCall call) => call.status == ToolStatus.failure;

String _reason(HToolCall call) {
  final r = call.result?.trim() ?? '';
  if (r.isEmpty) return '未给出原因';
  final first = r.split('\n').first.trim();
  return first.isEmpty ? r : first;
}

Widget _row(Hue h, String label, String value, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style: TextStyle(fontSize: 11.5, color: h.textDim)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 11.5, height: 1.45, color: h.textFaint)),
          ),
        ],
      ),
    );

Widget _box(Hue h, List<Widget> children, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 2),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: h.surface,
          borderRadius: BorderRadius.circular(HRadius.sm),
          border: Border.all(color: h.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );

// ---------------------------------------------------------------- web_search

Widget _webSearch(Hue h, HToolCall call) {
  final query = (call.args['query'] ?? call.args['q'] ?? '').trim();
  final failed = _failed(call);
  final sources = <String>[];
  if (!failed) {
    for (final line in (call.result ?? '').split('\n')) {
      final t = line.trim();
      final idx = t.indexOf('来源：');
      if (idx >= 0) {
        final url = t.substring(idx + 3).trim();
        if (url.isNotEmpty && !sources.contains(url)) sources.add(url);
      }
    }
  }
  return _box(h, [
    if (query.isNotEmpty) _row(h, '查询', query),
    if (failed)
      _row(h, '结果', '失败：${_reason(call)}',
          key: const Key('v04-web-search-failure'))
    else ...[
      if (sources.isEmpty)
        _row(h, '来源', '未返回来源（结果里没有「来源：」行）',
            key: const Key('v04-web-search-no-source'))
      else
        for (final s in sources.take(5)) _row(h, '来源', s),
    ],
  ], key: const Key('v04-web-search'));
}

// ------------------------------------------------------------- read_document

const Map<String, String> _docTypes = <String, String>{
  'docx': 'Word 文档',
  'xlsx': 'Excel 表格',
  'pptx': '演示文稿',
  'pdf': 'PDF',
};

Widget _readDocument(Hue h, HToolCall call) {
  final rawPath =
      (call.args['path'] ?? call.args['file'] ?? '').trim();
  // 结果首行「文档：path」也是权威来源（args 缺失时兜底）
  var path = rawPath;
  final result = call.result ?? '';
  if (path.isEmpty) {
    final m = RegExp(r'^文档：(.+)$', multiLine: true).firstMatch(result);
    if (m != null) path = m.group(1)!.trim();
  }
  final name = path.split('/').last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  final type = _docTypes[ext];
  final pages = RegExp(r'页数：\s*(\d+)').firstMatch(result)?.group(1);
  final sheets = RegExp(r'表数：\s*(\d+)').firstMatch(result)?.group(1);
  final failed = _failed(call);
  return _box(h, [
    if (name.isNotEmpty) _row(h, '文件', name, key: const Key('v04-doc-name')),
    if (type != null) _row(h, '类型', type, key: const Key('v04-doc-type')),
    if (pages != null) _row(h, '页数', pages, key: const Key('v04-doc-pages')),
    if (sheets != null)
      _row(h, '工作表数', sheets, key: const Key('v04-doc-sheets')),
    if (failed)
      _row(h, '结果', '读取失败：${_reason(call)}',
          key: const Key('v04-doc-failure'))
    else if (type == null && pages == null && sheets == null)
      _row(h, '结果', '已读取（未返回类型/页数）'),
  ], key: const Key('v04-read-document'));
}

// ---------------------------------------------------------------- notify_user

Widget _notifyUser(Hue h, HToolCall call) {
  final title = (call.args['title'] ?? '').trim();
  final body = (call.args['body'] ?? call.args['message'] ?? '').trim();
  final failed = _failed(call);
  return _box(h, [
    if (title.isNotEmpty) _row(h, '标题', title, key: const Key('v04-notify-title')),
    if (body.isNotEmpty) _row(h, '正文', body, key: const Key('v04-notify-body')),
    _row(
      h,
      '结果',
      failed ? '未送达：${_reason(call)}' : '已发送通知',
      key: Key(failed ? 'v04-notify-failure' : 'v04-notify-sent'),
    ),
  ], key: const Key('v04-notify-user'));
}
