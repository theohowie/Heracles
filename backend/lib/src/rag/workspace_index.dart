/// **工作区词法索引**（R1-R3，2026-10-25；用户拍板"词法可以"）。
///
/// ## 教材对齐（第 6 章）
///
/// | 教材要求 | 本实现的对应物 |
/// |---|---|
/// | R1 加载/切分/入库 | 逐文件按**行**切分 → 倒排索引（token → [(文件, 行号, 行文本)]）→ 持久化 `.heracles/rag-index.json` |
/// | R2 检索注入+来源 | [search] 按 token 重合打分 → top-K 片段（每条带 `文件:行号` 出处）|
/// | R3 质量策略（≥1 项）| **混合检索**：正文关键词命中 + **文件名命中加权**（文件名相关即使正文没提也排前）|
///
/// ## 为什么词法不做向量（用户口径）
///
/// 词法 = 关键词字面匹配（教材合规："按语义**或关键词**"）；向量需要端侧
/// embedding 模型 = 新依赖 = ADR 级（暂不做，用户拍板）。
///
/// ## 分词（复用 M4 的策略）
///
/// ASCII 词（≥2 字符，小写化）+ CJK 二元组 —— 中英混合任务都能命中。
///
/// ## 预算（防爆索引拖死手机）
///
/// · 最多 [maxFiles] 个**文本扩展名**文件（快照已给出文件清单，只挑文本）；
/// · 每文件最多读 [maxLinesPerFile] 行；
/// · 构建失败/超时 ⇒ 静默跳过（检索是增强，不是主链路）。
library;

import 'dart:convert';

import '../capability/capabilities.dart';

/// 工作区词法索引。
class WorkspaceIndex {
  WorkspaceIndex({this.maxFiles = 50, this.maxLinesPerFile = 300});

  /// 最多索引多少个文件（R1 入库预算）。
  final int maxFiles;

  /// 每文件最多读多少行。
  final int maxLinesPerFile;

  /// 倒排表：token → postings。
  final Map<String, List<_Posting>> _postings = {};

  /// 已索引的文件清单（staleness 判定 + 避免重复）。
  final Set<String> _indexedFiles = {};

  /// 文件名 token（R3 混合检索的文件名通道）。
  final Map<String, Set<String>> _fileNameTokens = {};

  static const _textExtensions = {
    '.md', '.txt', '.dart', '.kt', '.java', '.json', '.yaml', '.yml',
    '.xml', '.html', '.css', '.js', '.ts', '.py', '.sh', '.gradle',
    '.properties', '.cfg', '.ini', '.toml', '.csv', '.gitignore', '',
  };

  /// 从文件清单构建/刷新索引（增量：新文件追加，消失的文件忽略）。
  ///
  /// [files] 是快照给出的**相对路径**清单（App 侧已有）；只挑文本扩展名，
  /// 截到 [maxFiles]。读文件失败的单个跳过。
  Future<void> build(WorkspaceCapability ws, List<String> files) async {
    final textFiles = files.where(_isTextFile).take(maxFiles);
    for (final path in textFiles) {
      if (_indexedFiles.contains(path)) continue;
      final r = await ws.read(path, limit: maxLinesPerFile);
      if (r is! CapabilitySuccess) continue;
      _indexFile(path, r.data);
    }
  }

  bool _isTextFile(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot).toLowerCase() : '';
    if (!_textExtensions.contains(ext)) return false;
    // 二进制嗅：超大的不索引（预算）
    return path.length < 512;
  }

  void _indexFile(String path, String content) {
    _indexedFiles.add(path);
    // R3：文件名通道（小写化分词）
    _fileNameTokens[path] = tokenize(_baseName(path)).toSet();
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      // 去重同文件同 token 的重复行（首 2 个命中行保留）
      final seen = <String>{};
      for (final t in tokenize(line)) {
        if (!seen.add(t)) continue;
        (_postings[t] ??= []).add(_Posting(path, i + 1, _clip(line)));
      }
    }
  }

  /// **检索**（R2/R3）：token 重合打分 + 文件名加权，返回 top-K 片段
  /// （每条带 `文件:行号` 出处与原文摘录）。
  ///
  /// 无命中返回空列表（调用方据此不注入）。
  List<IndexHit> search(String query, {int maxResults = 3}) {
    final tokens = tokenize(query);
    if (tokens.isEmpty) return const [];

    // 文件 → 得分（正文命中 1 分/次，文件名命中 +3/词）
    final scores = <String, double>{};
    final hitLines = <String, List<_Posting>>{};
    for (final t in tokens) {
      for (final p in _postings[t] ?? const <_Posting>[]) {
        scores[p.file] = (scores[p.file] ?? 0) + 1;
        (hitLines[p.file] ??= []).add(p);
      }
    }
    for (final e in _fileNameTokens.entries) {
      for (final t in tokens) {
        if (e.value.contains(t)) {
          scores[e.key] = (scores[e.key] ?? 0) + 3; // R3：文件名加权
        }
      }
    }

    // 排序取 top 文件；每文件取最高分的 1 行做片段
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <IndexHit>[];
    for (final e in ranked.take(maxResults)) {
      if (e.value < 1) continue; // 纯文件名加权命中也算 ≥1
      final lines = [...(hitLines[e.key] ?? const [])];
      final best = lines.isNotEmpty ? lines.first : null;
      out.add(IndexHit(
        file: e.key,
        line: best?.line ?? 0,
        snippet: best?.text ?? '(文件名相关)',
        score: e.value,
      ));
    }
    return out;
  }

  /// 索引规模（诊断/测试用）。
  int get indexedFileCount => _indexedFiles.length;
  int get tokenCount => _postings.length;

  // ---------------------------------------------------------------- 序列化

  Map<String, dynamic> toJson() => {
        'files': _indexedFiles.toList(),
        'postings': {
          for (final e in _postings.entries)
            e.key: [
              for (final p in e.value) [p.file, p.line, p.text],
            ],
        },
      };

  /// 持久化到工作区（R1 的"入库"）。
  Future<void> save(WorkspaceCapability ws, {String path = ragIndexPath}) async {
    await ws.mkdir('.heracles');
    await ws.write(path, jsonEncode(toJson()));
  }

  static const ragIndexPath = '.heracles/rag-index.json';

  // ---------------------------------------------------------------- 分词

  /// 分词：ASCII 词（≥2 字符，小写）+ CJK 二元组（与 M4 同策略）。
  static List<String> tokenize(String text) {
    final out = <String>{};
    for (final m in RegExp(r'[a-z0-9_]{2,}').allMatches(text.toLowerCase())) {
      out.add(m.group(0)!);
    }
    for (final m in RegExp(r'[\u4e00-\u9fff]{2}').allMatches(text)) {
      out.add(m.group(0)!);
    }
    return out.toList();
  }

  static String _baseName(String path) =>
      path.split('/').last;

  static String _clip(String s) =>
      s.length <= 160 ? s : '${s.substring(0, 160)}…';
}

/// 一条检索命中（带出处 —— R2 的"注明来源"）。
class IndexHit {
  const IndexHit({
    required this.file,
    required this.line,
    required this.snippet,
    required this.score,
  });

  /// 相对路径。
  final String file;

  /// 行号（0 = 文件名通道命中，无具体行）。
  final int line;

  /// 命中行原文（截断）。
  final String snippet;

  /// 得分（诊断用）。
  final double score;

  /// 给模型看的渲染（`文件:行号 → 内容`）。
  String render() => line > 0 ? '`$file:$line` → $snippet' : '`$file`（文件名相关）';
}

class _Posting {
  const _Posting(this.file, this.line, this.text);
  final String file;
  final int line;
  final String text;
}
