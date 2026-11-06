/// **压缩后必须重载/保留的内容** —— 项目指令（AGENTS.md）与最近修改的文件。
///
/// ## 为什么压缩会"弄丢"这些东西，以及为什么必须显式补回来
///
/// 压缩把老消息收进摘要，于是这些**本来在历史/系统提示里、缩不掉的**东西
/// 有了消失的风险：
///
/// | 内容 | 为什么容易丢 | 本文件怎么补 |
/// |---|---|---|
/// | 项目指令（`AGENTS.md`） | 它在 system prompt 里，**不在历史里** —— 压缩动不到它（这一条由测试证明，不是这里补） | 摘要视图里**再显式注入一次**（前 N 字符）：模型读摘要时就看见规则 |
/// | 最近修改的文件 | 全文都在老工具结果里，会被摘要吞掉 | 列路径；小于阈值给节选，大文件**只给路径**（要就重读） |
///
/// ## 为什么"大文件只给路径"
///
/// 摘要视图是"压缩后的摘要"，不是把文件再搬一遍。把一个 5K+ token 的文件
/// 全文塞回来，等于刚压完又填满 —— 那还压什么。给路径 + "需要请重新读取"
/// 是唯一自洽的形状（模型有明确的恢复手段）。
///
/// ## 读文件的活谁干
///
/// backend 是**纯 Dart 包，不碰 IO**（不 import Flutter / 不知道设备路径）。
/// 所以这里只定义**读取器接口**（[ProjectInstructionsReader] / [RecentFileReader]），
/// 由宿主（App 的 `fs.*` 通道 / CLI 的 `dart:io`）注入。
/// 宿主没注入 ⇒ 如实记一条 note（"本次未重载项目指令"），绝不假装读过。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../contract/contract.dart';
import 'compaction_config.dart';
import 'message_scan.dart';
import 'token_estimation.dart';

/// 读一个项目指令文件（如 `AGENTS.md`）的全文；读不到返回 `null`。
typedef ProjectInstructionsReader = Future<String?> Function(String fileName);

/// 读一个工作区文件（相对路径）的全文；读不到返回 `null`。
typedef RecentFileReader = Future<String?> Function(String path);

/// 一份项目指令（可能被截断）。
class ProjectInstructions {
  const ProjectInstructions({
    required this.source,
    required this.content,
    required this.originalChars,
    required this.truncated,
  });

  /// 来源文件名（`AGENTS.md`）。
  final String source;

  /// 注入用的内容（可能已截断到 [ContractCompaction.projectInstructionsMaxChars]）。
  final String content;

  /// 原文总字符数（超过 content.length 说明被截断了）。
  final int originalChars;

  /// 是否被截断。
  final bool truncated;
}

/// 一个"最近修改的文件"。
class RecentFileRef {
  const RecentFileRef({
    required this.path,
    required this.estTokens,
    required this.contentKnown,
    this.excerpt,
    required this.tooLarge,
  });

  /// 路径（原样，不规范化 —— 模型给的是什么就是什么，避免猜）。
  final String path;

  /// 估算 token（`contentKnown == false` 时为 0，**不编**）。
  final int estTokens;

  /// 宿主是否给了内容（false = 读不到，只能给路径）。
  final bool contentKnown;

  /// 节选（只在"内容已知且不大"时非空）。
  final String? excerpt;

  /// 是否超过 [CompactionConfig.largeFileTokenThreshold]（超了只给路径）。
  final bool tooLarge;

  String render() {
    if (!contentKnown) {
      return '- $path（未读取到内容，需要请看文件本身）';
    }
    if (tooLarge) {
      return '- $path（约 $estTokens token，全文未注入；需要请重新读取该文件）';
    }
    final ex = excerpt;
    if (ex == null || ex.isEmpty) return '- $path';
    return '- $path（约 $estTokens token，节选如下）\n$ex';
  }
}

/// 一次重载的全部产物。
class ReloadedContext {
  const ReloadedContext({
    this.instructions,
    this.recentFiles = const <RecentFileRef>[],
    this.notes = const <String>[],
  });

  /// 项目指令（读不到 = null）。
  final ProjectInstructions? instructions;

  /// 最近修改的文件（可能为空）。
  final List<RecentFileRef> recentFiles;

  /// 如实说明（"未提供读取器"/"AGENTS.md 读不到"/"截断了"…）。
  final List<String> notes;

  /// 注入的保留块数量（项目指令 + 每个文件各算一块）—— 进 `CompactionEvent.injectedBlocks`。
  int get injectedBlocks =>
      (instructions == null ? 0 : 1) + recentFiles.length;
}

/// 重载器：**只做编排**，读文件的活交给注入的读取器。
class ContextReloader {
  const ContextReloader({
    this.config = const CompactionConfig(),
    this.readProjectFile,
    this.readRecentFile,
  });

  final CompactionConfig config;

  /// 项目指令读取器（宿主注入；null = 未接入）。
  final ProjectInstructionsReader? readProjectFile;

  /// 工作区文件读取器（宿主注入；null = 未接入）。
  final RecentFileReader? readRecentFile;

  /// 从历史推出"最近改过哪些文件"，并尽力取回它们。
  ///
  /// 任何一步失败都**只记 note、绝不抛** —— 重载是增强，
  /// 不该让压缩（进而让整个任务）失败。
  Future<ReloadedContext> load({required List<LLMMessage> messages}) async {
    final notes = <String>[];

    // ---- 项目指令 ----
    ProjectInstructions? instructions;
    final reader = readProjectFile;
    if (reader == null) {
      notes.add('项目指令未重载：宿主未提供读取器（AGENTS.md 无法读取）');
    } else {
      for (final name in ContractCompaction.projectInstructionFiles) {
        String? content;
        try {
          content = await reader(name);
        } catch (_) {
          content = null;
        }
        if (content == null || content.trim().isEmpty) continue;
        final max = ContractCompaction.projectInstructionsMaxChars;
        final truncated = content.length > max;
        instructions = ProjectInstructions(
          source: name,
          content: truncated ? content.substring(0, max) : content,
          originalChars: content.length,
          truncated: truncated,
        );
        if (truncated) {
          notes.add('项目指令 $name 超过 $max 字符，已截断注入');
        }
        break;
      }
      if (instructions == null) {
        notes.add(
            '项目指令未重载：${ContractCompaction.projectInstructionFiles.join('/')} 读不到');
      }
    }

    // ---- 最近修改的文件 ----
    final paths = collectRecentWritePaths(messages, config.recentFilesMax);
    final files = <RecentFileRef>[];
    for (final path in paths) {
      final fileReader = readRecentFile;
      if (fileReader == null) {
        files.add(RecentFileRef(
          path: path,
          estTokens: 0,
          contentKnown: false,
          tooLarge: false,
        ));
        continue;
      }
      String? content;
      try {
        content = await fileReader(path);
      } catch (_) {
        content = null;
      }
      if (content == null) {
        files.add(RecentFileRef(
          path: path,
          estTokens: 0,
          contentKnown: false,
          tooLarge: false,
        ));
        continue;
      }
      final est = estimateTextTokens(content);
      final tooLarge = est > config.largeFileTokenThreshold;
      files.add(RecentFileRef(
        path: path,
        estTokens: est,
        contentKnown: true,
        tooLarge: tooLarge,
        excerpt: tooLarge
            ? null
            : clipText(content, ContractCompaction.recentFileExcerptMaxChars),
      ));
    }
    if (readRecentFile == null && paths.isNotEmpty) {
      notes.add('最近修改的文件未读取内容：宿主未提供读取器（只列路径）');
    }

    return ReloadedContext(
      instructions: instructions,
      recentFiles: files,
      notes: notes,
    );
  }
}

/// 从历史里收集"最近被写过的文件路径"（**最近在前、去重、最多 [max] 个**）。
///
/// 只看**写类工具的调用**（`ModelMessage.functionCalls`），不看结果：
/// 结果里的路径可能是"被读的文件"，混进来会把"改过什么"说错。
List<String> collectRecentWritePaths(List<LLMMessage> messages, int max) {
  final out = <String>[];
  final seen = <String>{};
  if (max <= 0) return out;
  for (final m in messages.reversed) {
    if (m is! ModelMessage) continue;
    for (final call in m.functionCalls.reversed) {
      if (!isWriteToolName(call.name)) continue;
      final path = extractToolPath(call.arguments);
      if (path == null || path.isEmpty) continue;
      if (seen.add(path)) out.add(path);
      if (out.length >= max) return out;
    }
  }
  return out;
}
