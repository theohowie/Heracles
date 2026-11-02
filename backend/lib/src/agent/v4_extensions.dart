// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 T1-5 扩展面（2026-11-02）**：Skills 扫描 / MCP 配置 / Automation 存储。
//
// ## 本文件只做"纯逻辑 + 校验"（可 dart test）
//
// 真机上的**安装/连接/调度**（apk 安装技能包、stdio/HTTP 连 MCP、WorkManager 定时）
// 由宿主（Kotlin/App）负责；本文件提供：
// - SKILL.md 解析与启停状态（纯数据，能测）；
// - MCP 服务器配置 CRUD 的**形状校验**（非法配置在保存时就拒绝，而不是连接时才炸）；
// - Automation 任务的**存储形状与校验**（不假调度：只存/校验，调度器由宿主接）。
//
// ## 不编造原则
//
// 解析失败 ⇒ 明确错误；配置非法 ⇒ 明确原因；调度器未接 ⇒ 返回 `schedulerImplemented=false`。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

/// **一个技能**（从 `SKILL.md` 解析）。
class SkillEntry {
  const SkillEntry({
    required this.name,
    required this.description,
    required this.body,
    required this.source,
    this.enabled = true,
  });

  final String name;
  final String description;

  /// SKILL.md 的正文（激活后注入系统提示）。
  final String body;

  /// `builtin` / `user`（来源校验用）。
  final String source;
  final bool enabled;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'source': source,
        'enabled': enabled,
      };

  /// **转成框架 Skill**（注入 StatefulAgent(skills:) 用；只用于已启用技能）。
  Skill toFrameworkSkill() => _UserSkill(
        name: name,
        description: description,
        systemPrompt: body,
      );

  SkillEntry copyWith({bool? enabled}) => SkillEntry(
        name: name,
        description: description,
        body: body,
        source: source,
        enabled: enabled ?? this.enabled,
      );
}

/// **把用户技能转成框架 Skill**（V0.4：注入 `StatefulAgent(skills:)` 用）。
///
/// 框架的 `Skill` 是抽象类（`name`/`description`/`systemPrompt`），这里用一个
/// 极简子类承载 SKILL.md 的正文 —— 与 `_BuiltinSkill` 同形状，行为一致。
class _UserSkill extends Skill {
  _UserSkill({
    required super.name,
    required super.description,
    required super.systemPrompt,
  });
}

/// **SKILL.md 解析结果**（成功/失败都明确）。
class SkillParseResult {
  const SkillParseResult({this.skill, this.error});
  final SkillEntry? skill;
  final String? error;
  bool get ok => skill != null;
}

/// **解析 SKILL.md**（极简 YAML front-matter + 正文）。
///
/// 期望格式（Claude Code 兼容）：
/// ```
/// ---
/// name: my-skill
/// description: 一句话说明
/// ---
/// 正文…
/// ```
///
/// 解析失败 ⇒ [SkillParseResult.error] 写**人话原因**（不猜）。
SkillParseResult parseSkillMd(String raw, {String source = 'user'}) {
  final text = raw.replaceAll('\r\n', '\n');
  if (!text.trimLeft().startsWith('---')) {
    return const SkillParseResult(error: 'SKILL.md 缺少 front-matter（应以 --- 开头）');
  }
  final start = text.indexOf('---');
  final end = text.indexOf('\n---', start + 3);
  if (end < 0) {
    return const SkillParseResult(error: 'SKILL.md front-matter 未闭合（缺少结束的 ---）');
  }
  final header = text.substring(start + 3, end);
  final body = text.substring(end + 4).trim();

  String? name;
  String? description;
  for (final line in header.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final idx = t.indexOf(':');
    if (idx <= 0) continue;
    final key = t.substring(0, idx).trim().toLowerCase();
    final value = t.substring(idx + 1).trim();
    if (key == 'name') name = value;
    if (key == 'description') description = value;
  }
  if (name == null || name.isEmpty) {
    return const SkillParseResult(error: 'SKILL.md 缺少 name');
  }
  if (body.isEmpty) {
    return const SkillParseResult(error: 'SKILL.md 正文为空（激活后没有可注入的内容）');
  }
  return SkillParseResult(
    skill: SkillEntry(
      name: name,
      description: description ?? '',
      body: body,
      source: source,
    ),
  );
}

/// **技能注册表**（扫描/启停；纯内存 + 可导出）。
///
/// 真机安装（下载/解压技能包）由宿主负责；这里只管"已扫到的技能 + 启停状态"。
class SkillRegistry {
  SkillRegistry([Iterable<SkillEntry> initial = const []])
      : _skills = {for (final s in initial) s.name: s};

  final Map<String, SkillEntry> _skills;

  List<SkillEntry> get all => _skills.values.toList(growable: false);

  /// 已启用的技能（注入系统提示时用）。
  List<SkillEntry> get enabled =>
      _skills.values.where((s) => s.enabled).toList(growable: false);

  /// 扫描一批 SKILL.md 文本（**逐个解析，失败项单独报告**，不整体失败）。
  ({List<SkillEntry> added, List<String> errors}) scan(
    Map<String, String> mdByPath, {
    String source = 'user',
  }) {
    final added = <SkillEntry>[];
    final errors = <String>[];
    for (final e in mdByPath.entries) {
      final r = parseSkillMd(e.value, source: source);
      if (r.ok) {
        _skills[r.skill!.name] = r.skill!;
        added.add(r.skill!);
      } else {
        errors.add('${e.key}: ${r.error}');
      }
    }
    return (added: added, errors: errors);
  }

  /// 启用/停用；未知技能 ⇒ false（不静默成功）。
  bool setEnabled(String name, bool enabled) {
    final s = _skills[name];
    if (s == null) return false;
    _skills[name] = s.copyWith(enabled: enabled);
    return true;
  }

  /// 移除（卸载）；未知 ⇒ false。
  bool remove(String name) => _skills.remove(name) != null;

  SkillEntry? byName(String name) => _skills[name];
}

// ============================================================================
// MCP
// ============================================================================

/// **MCP 服务器配置**（CRUD 的形状）。
class McpServerConfig {
  const McpServerConfig({
    required this.name,
    required this.transport,
    this.command = '',
    this.url = '',
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.enabled = true,
  });

  final String name;

  /// `stdio` | `http`。
  final String transport;

  /// stdio：可执行命令。
  final String command;

  /// http：URL。
  final String url;

  final List<String> args;
  final Map<String, String> env;
  final bool enabled;

  Map<String, Object?> toJson() => {
        'name': name,
        'transport': transport,
        'command': command,
        'url': url,
        'args': args,
        'env': env,
        'enabled': enabled,
      };

  McpServerConfig copyWith({bool? enabled}) => McpServerConfig(
        name: name,
        transport: transport,
        command: command,
        url: url,
        args: args,
        env: env,
        enabled: enabled ?? this.enabled,
      );
}

/// **校验 MCP 配置**（返回 null = 合法；否则人话原因）。
///
/// 为什么要在这里校验：非法配置若拖到"连接时"才报，模型会白等一次超时。
String? validateMcpServer(McpServerConfig c) {
  if (c.name.trim().isEmpty) return 'name 不能为空';
  if (c.transport != 'stdio' && c.transport != 'http') {
    return 'transport 只能是 stdio 或 http（收到 ${c.transport}）';
  }
  if (c.transport == 'stdio' && c.command.trim().isEmpty) {
    return 'stdio 模式必须给 command';
  }
  if (c.transport == 'http') {
    if (!c.url.startsWith('http://') && !c.url.startsWith('https://')) {
      return 'http 模式 url 必须以 http:// 或 https:// 开头';
    }
  }
  // 环境变量里不许塞密钥明文（安全纪律）
  for (final k in c.env.keys) {
    if (k.toUpperCase().contains('KEY') ||
        k.toUpperCase().contains('TOKEN') ||
        k.toUpperCase().contains('SECRET')) {
      return '不要把密钥写进 MCP 环境变量（$k）——应使用宿主的安全存储';
    }
  }
  return null;
}

/// **MCP 配置表**（CRUD；纯内存，持久化由宿主）。
class McpConfigStore {
  McpConfigStore([Iterable<McpServerConfig> initial = const []])
      : _servers = {for (final s in initial) s.name: s};

  final Map<String, McpServerConfig> _servers;

  List<McpServerConfig> get all => _servers.values.toList(growable: false);

  /// 新增/更新（校验失败 ⇒ 返回人话原因，不写入）。
  String? upsert(McpServerConfig c) {
    final err = validateMcpServer(c);
    if (err != null) return err;
    _servers[c.name] = c;
    return null;
  }

  /// 删除（未知 ⇒ false）。
  bool remove(String name) => _servers.remove(name) != null;

  McpServerConfig? byName(String name) => _servers[name];

  bool setEnabled(String name, bool enabled) {
    final s = _servers[name];
    if (s == null) return false;
    _servers[name] = s.copyWith(enabled: enabled);
    return true;
  }
}

// ============================================================================
// Automation
// ============================================================================

/// **定时任务**（存储形状；调度器由宿主 WorkManager/前台服务接）。
class AutomationTask {
  const AutomationTask({
    required this.id,
    required this.title,
    required this.prompt,
    required this.schedule,
    this.intervalMinutes = 0,
    this.cron = '',
    this.enabled = true,
    this.runHistory = const <AutomationRun>[],
  });

  final String id;
  final String title;

  /// 到点要跑的任务描述（作为一次 run 的请求）。
  final String prompt;

  /// `interval` | `cron`。
  final String schedule;
  final int intervalMinutes;
  final String cron;
  final bool enabled;
  final List<AutomationRun> runHistory;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'prompt': prompt,
        'schedule': schedule,
        'intervalMinutes': intervalMinutes,
        'cron': cron,
        'enabled': enabled,
        'runHistory': [for (final r in runHistory) r.toJson()],
      };

  AutomationTask copyWith({bool? enabled, List<AutomationRun>? runHistory}) =>
      AutomationTask(
        id: id,
        title: title,
        prompt: prompt,
        schedule: schedule,
        intervalMinutes: intervalMinutes,
        cron: cron,
        enabled: enabled ?? this.enabled,
        runHistory: runHistory ?? this.runHistory,
      );
}

/// 一次运行历史（**只记真实结果**，不预填成功）。
class AutomationRun {
  const AutomationRun({
    required this.ts,
    required this.ok,
    this.error,
    this.durationMs = 0,
  });
  final int ts;
  final bool ok;
  final String? error;
  final int durationMs;

  Map<String, Object?> toJson() => {
        'ts': ts,
        'ok': ok,
        'error': ?error,
        'durationMs': durationMs,
      };
}

/// **校验自动化任务**（null = 合法）。
String? validateAutomationTask(AutomationTask t) {
  if (t.id.trim().isEmpty) return 'id 不能为空';
  if (t.prompt.trim().isEmpty) return 'prompt 不能为空（到点要跑什么）';
  if (t.schedule != 'interval' && t.schedule != 'cron') {
    return 'schedule 只能是 interval 或 cron';
  }
  if (t.schedule == 'interval' && t.intervalMinutes <= 0) {
    return 'interval 模式 intervalMinutes 必须 > 0';
  }
  if (t.schedule == 'cron' && t.cron.trim().isEmpty) {
    return 'cron 模式必须给 cron 表达式';
  }
  return null;
}

/// **自动化任务表**（CRUD + 运行历史；**不假调度**）。
class AutomationStore {
  AutomationStore([Iterable<AutomationTask> initial = const []])
      : _tasks = {for (final t in initial) t.id: t};

  final Map<String, AutomationTask> _tasks;

  /// 调度器是否已实现（2026-11-02：宿主用 **AlarmManager** 实现真实周期触发）。
  ///
  /// ⚠️ 但**执行**仍需要 App 在前台（到点只发通知 + 写 pending 标记，真正 run 由
  /// App 打开后发起）—— 这条必须如实告诉 UI，不许说成"后台自动跑完"。
  static const bool schedulerImplemented = true;

  /// **执行**是否需要 App 在前台（2026-11-02 现状 = true，如实标注）。
  static const bool executionRequiresAppForeground = true;

  List<AutomationTask> get all => _tasks.values.toList(growable: false);

  String? upsert(AutomationTask t) {
    final err = validateAutomationTask(t);
    if (err != null) return err;
    _tasks[t.id] = t;
    return null;
  }

  bool remove(String id) => _tasks.remove(id) != null;

  bool setEnabled(String id, bool enabled) {
    final t = _tasks[id];
    if (t == null) return false;
    _tasks[id] = t.copyWith(enabled: enabled);
    return true;
  }

  /// 追加一次**真实**运行记录（只保留最近 N 条，防无限增长）。
  bool recordRun(String id, AutomationRun run, {int keep = 20}) {
    final t = _tasks[id];
    if (t == null) return false;
    final hist = [...t.runHistory, run];
    final trimmed = hist.length > keep ? hist.sublist(hist.length - keep) : hist;
    _tasks[id] = t.copyWith(runHistory: trimmed);
    return true;
  }

  /// **最近一次运行**（`null` = 从未跑过；**不预填假结果**）。
  AutomationRun? lastRun(String id) {
    final h = _tasks[id]?.runHistory;
    if (h == null || h.isEmpty) return null;
    return h.last;
  }

  /// **最近一次失败原因**（最近一条 `ok=false` 的 `error`；全成功/没跑过 ⇒ `null`）。
  ///
  /// 取"最近一条失败"而不是"最后一条"：最后一条成功不该把上一轮的失败原因抹掉 ——
  /// 用户需要知道"上次为什么没跑成"，直到它真的被修好。
  String? lastError(String id) {
    final h = _tasks[id]?.runHistory;
    if (h == null) return null;
    for (var i = h.length - 1; i >= 0; i--) {
      if (!h[i].ok) return h[i].error ?? '未知原因';
    }
    return null;
  }

  /// **下次预计运行时间**（毫秒时间戳；`null` = 算不出）。
  ///
  /// 算不出的三种情况，都返回 `null` 而不是编一个数：
  /// ① 任务不存在；② 已停用；③ **从未跑过**（interval 任务的首轮由闹钟决定，
  /// Dart 侧并不知道宿主何时注册了第一个闹钟）。
  ///
  /// cron 任务返回 `null`：cron 解析**未实现**（宿主的 AlarmManager 只支持 interval），
  /// 编一个"下次时间"就是假信息。
  int? nextRunAt(String id) {
    final t = _tasks[id];
    if (t == null || !t.enabled) return null;
    if (t.schedule != 'interval' || t.intervalMinutes <= 0) return null;
    final last = lastRun(id);
    if (last == null) return null;
    return last.ts + t.intervalMinutes * 60 * 1000;
  }
}
