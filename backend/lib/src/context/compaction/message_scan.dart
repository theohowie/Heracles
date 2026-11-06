/// **历史消息扫描小工具**（纯函数，压缩层共用）。
///
/// SessionMemory 与"最近修改文件重载"都要回答同一类问题：
/// "哪些工具调用改了文件？路径是什么？" —— 抽成一份，避免两处口径漂移
/// （一处认 `write_file`、另一处认 `write`，就会漏文件）。
library;

import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';

/// 拼接内容块里的纯文本（**忽略媒体块**：媒体没有可读文本）。
String partsText(List<UserContentPart> parts) {
  final buf = StringBuffer();
  for (final p in parts) {
    if (p is TextPart) buf.write(p.text);
  }
  return buf.toString();
}

/// 这个工具是不是"会改工作区"的写类工具。
///
/// 判据是名字里的动词，**不是白名单全名**：工具的正式名在演变
/// （`write_file` / `edit_file` / `apply_patch` / `file_write`…），
/// 按动词认比按全名认更抗改名；误判的方向也是安全的（多列一个文件）。
bool isWriteToolName(String name) {
  final n = name.toLowerCase();
  return n.contains('write') ||
      n.contains('edit') ||
      n.contains('patch') ||
      n.contains('create') ||
      n.contains('move') ||
      n.contains('copy');
}

/// 写类工具的中文动词（渲染"已完成"时用）。
String writeVerbOf(String name) {
  final n = name.toLowerCase();
  if (n.contains('patch')) return '打了补丁';
  if (n.contains('edit')) return '编辑了';
  if (n.contains('move')) return '移动了';
  if (n.contains('copy')) return '复制了';
  return '写入了';
}

/// 从工具参数 JSON 里取被操作的路径。
///
/// ## 为什么容忍失败
///
/// 参数偶有非 JSON（旧工具、手工日志、被截断的历史），抽不到就返回 null ——
/// **少记一个文件名的代价**远小于"因为解析失败让压缩崩掉"。
/// 这不是抗幻觉，是分层容错：拿不到就不编。
String? extractToolPath(String arguments) {
  final raw = arguments.trim();
  if (raw.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  for (final key in const <String>['path', 'filePath', 'file', 'target']) {
    final v = decoded[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

/// 把按条数算出的切点调整到**不拆批**的位置。
///
/// ## 为什么这条规则必须独立成函数
///
/// 压缩的所有层（本地记忆视图、模型摘要视图、强制重置、兜底裁剪）都要切历史，
/// 而切点一旦落在"调用与结果之间"，provider 会直接 400（有结果没有请求）。
/// 四处各写一遍必然有一处漏 —— 所以只留这一份。
///
/// 规则：
/// · 切点落点的第一条消息若是 `FunctionExecutionResultMessage` ⇒
///   它的配对调用在切点之前 ⇒ 切点**前移**（多留）；
/// · 带调用的 `ModelMessage` 且下一条不是它的结果 ⇒ 切点**后移**
///   （连调用一起丢，否则留下一个永远等不到结果的调用）。
/// 有界循环（最多走一遍消息列表），绝不死循环。
int adjustCutToBatchBoundary(List<LLMMessage> messages, int raw) {
  var cut = raw.clamp(0, messages.length);
  for (var guard = 0; guard < messages.length + 1; guard++) {
    if (cut >= messages.length || cut <= 0) return cut;
    final m = messages[cut];
    if (m is FunctionExecutionResultMessage) {
      cut--;
      continue;
    }
    if (m is ModelMessage && m.functionCalls.isNotEmpty) {
      final next = cut + 1 < messages.length ? messages[cut + 1] : null;
      if (next is FunctionExecutionResultMessage) return cut; // 成对保留，合法
      cut++;
      continue;
    }
    return cut;
  }
  return cut;
}
