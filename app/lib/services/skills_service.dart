// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **Skills 服务层**（V0.4 F1，2026-11-02；契约见 `docs/INTERFACE.md` §N16.1）。
//
// ## 为什么"解析/校验/合并"在 Dart 而不是宿主
//
// 宿主（Kotlin）只做**文件系统**：扫 `.heracles/skills/**/SKILL.md`、搬字节、
// 存启停表。语义判断留在 Dart，是因为：
//   · `parseSkillMd` 的唯一真相在 backend（`dart test` 能覆盖，Kotlin 侧再写
//     一份就是第二套规则，改一边不会提醒另一边）；
//   · 合并内置清单必须读 `builtinSkillEntries()` —— 那是 backend 的导出，
//     宿主看不到。
//
// ## 三条硬口径（改代码前先读）
//
// 1. **通道不抛 `PlatformException`**：失败一律 `{ok:false, error, code}`，
//    本文件**每个方法都判 `ok`**，绝不把"宿主说失败"当成成功。
// 2. **单个坏 `SKILL.md` 不拖垮整张清单**：逐条解析，坏项进 `errors`
//    （形如 `<path>: <原因>`），好技能照常返回。
// 3. **正文（body）不出本文件**：[SkillView] 刻意没有 `body` 字段 ——
//    技能正文只该进系统提示，不该进 UI 状态、日志、会话 JSON。
//
// ## 旧宿主（没有这 4 个方法）
//
// `MissingPluginException` ⇒ **如实降级**：内置技能仍可显示（它们不依赖宿主），
// 用户技能为空，并给一条说明性 `errors`；`code = E_SKILLS_CHANNEL_MISSING`
// 让 UI 能区分"旧版本"和"技能本身坏了"。
library;

import 'package:flutter/services.dart';
import 'package:heracles_backend/heracles_backend.dart';

/// **一个技能的展示视图**（不含正文）。
///
/// [path] 对内置技能是空串：它们随 App 发布，磁盘上没有独立文件。
class SkillView {
  const SkillView({
    required this.name,
    required this.description,
    required this.source,
    required this.enabled,
    required this.path,
  });

  final String name;
  final String description;

  /// `builtin` / `user`（[ContractSkills.sourceBuiltin] / [sourceUser]）。
  final String source;
  final bool enabled;
  final String path;

  bool get isBuiltin => source == ContractSkills.sourceBuiltin;

  SkillView copyWith({bool? enabled}) => SkillView(
    name: name,
    description: description,
    source: source,
    enabled: enabled ?? this.enabled,
    path: path,
  );

  /// 对外 JSON：**不放正文**。UI/日志/埋点都只能拿到这些字段。
  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'description': description,
    'source': source,
    'enabled': enabled,
    'path': path,
  };

  @override
  String toString() =>
      'SkillView(name: $name, source: $source, enabled: $enabled, path: $path)';
}

/// **一次清单加载的结果**。
///
/// [errors] 是**逐条**问题（坏文件、宿主跳过的大文件…）；[error]/[code] 是
/// **整次调用**失败（没有工作区、通道缺失、宿主 `ok:false`）。
/// 两者分开：UI 可以在"清单拿到了但有一个文件坏了"时正常渲染 + 提示。
class SkillsSnapshot {
  const SkillsSnapshot({
    required this.builtin,
    required this.user,
    required this.errors,
    this.error,
    this.code,
  });

  final List<SkillView> builtin;
  final List<SkillView> user;
  final List<String> errors;
  final String? error;
  final String? code;

  bool get ok => error == null;

  List<SkillView> get all => <SkillView>[...builtin, ...user];

  SkillView? viewOf(String name) {
    for (final v in all) {
      if (v.name == name) return v;
    }
    return null;
  }

  @override
  String toString() =>
      'SkillsSnapshot(ok: $ok, builtin: ${builtin.length}, '
      'user: ${user.map((v) => v.name).join(",")}, errors: ${errors.length})';
}

/// **启停 / 其它返回 `{ok}` 的操作结果**。
class SkillOpResult {
  const SkillOpResult.ok() : ok = true, error = null, code = null;

  const SkillOpResult.fail(this.error, {this.code}) : ok = false;

  final bool ok;
  final String? error;
  final String? code;
}

/// **卸载结果**（`removed` 与 `ok` 分开：宿主可能"成功执行但没删到"）。
class RemoveSkillResult {
  const RemoveSkillResult.ok()
    : ok = true,
      removed = true,
      error = null,
      code = null;

  const RemoveSkillResult.fail(this.error, {this.code})
    : ok = false,
      removed = false;

  final bool ok;
  final bool removed;
  final String? error;
  final String? code;
}

/// **安装结果**。
///
/// [ok] 的口径：**这次安装的每一条都可用**（且宿主没报错）。若有坏技能被
/// 回滚，[ok] 为 `false`，但 [installed] 里仍保留已经装好的部分 —— UI 应该
/// 同时展示"成功的"和"被回滚的"，而不是把整次操作渲染成一句"失败"。
class InstallResult {
  const InstallResult({
    required this.ok,
    this.installed = const <SkillView>[],
    this.errors = const <String>[],
    this.error,
    this.code,
  });

  final bool ok;
  final List<SkillView> installed;
  final List<String> errors;
  final String? error;
  final String? code;
}

/// 通道调用结果：把 `MissingPluginException` 变成一个**可判**的状态，
/// 而不是在 4 个方法里各写一遍 try/catch（漏一个就会炸到 UI）。
class _Reply {
  const _Reply(this.data) : missing = false;
  const _Reply.missing() : data = null, missing = true;

  final Map<String, Object?>? data;
  final bool missing;
}

/// **Skills 门面**（App 侧）。
///
/// 用法：
/// ```dart
/// final skills = SkillsService(workspace: activeWorkspace.path);
/// final snap = await skills.listSkills();
/// if (!snap.ok) showError(snap.error);
/// ```
///
/// [workspace] 在构造时固定：工作区切换时由页面重建实例（与 [GitService]
/// 同一约定）。为空/空串 ⇒ 每个需要工作区的方法都明确失败
/// `E_SKILLS_NO_WORKSPACE`，**不静默返回空清单**。
class SkillsService {
  SkillsService({this.workspace, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ContractSkills.channel);

  /// 工作区根目录（绝对路径）；null/空 = 还没选。
  final String? workspace;

  final MethodChannel _channel;

  /// 最近一次成功加载的清单（启停/卸载后同步用；不做跨实例缓存）。
  SkillsSnapshot? _last;

  /// 旧宿主没有技能通道时的错误码（**Dart 侧自建**）。
  ///
  /// 契约里的 `E_SKILL_*` 都是**宿主**失败；这个码描述的是"App 版本太旧，
  /// 根本没有这条通道"，UI 据此给出"升级 App"而不是"技能文件坏了"。
  static const String errChannelMissing = 'E_SKILLS_CHANNEL_MISSING';

  static const String _noWorkspaceMessage =
      '还没有选择工作区，读不到（也装不了、删不了）工作区里的技能。请先选择工作区。';

  // ==========================================================================
  // 对外 API
  // ==========================================================================

  /// 内置 + 用户技能合并后的清单。
  ///
  /// 内置技能**不依赖宿主**：即使通道缺失/没有工作区，也照样返回三条，
  /// 让 UI 至少能展示与启停（启停能否落盘取决于宿主，失败会明确报错）。
  Future<SkillsSnapshot> listSkills() async {
    final ws = _normalizedWorkspace;
    if (ws == null) {
      return SkillsSnapshot(
        builtin: _builtinViews(const <String, bool>{}),
        user: const <SkillView>[],
        errors: const <String>[_noWorkspaceMessage],
        error: _noWorkspaceMessage,
        code: ContractSkills.errNoWorkspace,
      );
    }

    final reply = await _invoke(ContractSkills.listMethod, <String, Object?>{
      'workspace': ws,
    });
    if (reply.missing) return _degradedSnapshot();

    final data = reply.data;
    if (data == null) {
      return _failedSnapshot('宿主没有返回技能清单（通道返回 null）。');
    }
    if (data['ok'] != true) {
      return _failedSnapshot(
        _errorOf(data, '宿主未能列出工作区里的技能。'),
        code: _codeOf(data),
      );
    }

    final enabled = _enabledOf(data['enabled']);
    final errors = <String>[];
    final user = <SkillView>[];

    final entries = data['entries'];
    if (entries is List) {
      for (final e in entries) {
        // 不要 `$e`：那里的 raw 含技能正文，拼进错误就是正文外泄。
        if (e is! Map) {
          errors.add('宿主返回了一条无法识别的技能条目（已跳过）。');
          continue;
        }
        final path = e['path'];
        final raw = e['raw'];
        if (path is! String || raw is! String) {
          errors.add('宿主返回的技能条目缺少 path/raw（已跳过）。');
          continue;
        }
        final parsed = parseSkillMd(raw, source: ContractSkills.sourceUser);
        if (!parsed.ok) {
          errors.add('$path: ${parsed.error}');
          continue;
        }
        final skill = parsed.skill!;
        user.add(
          SkillView(
            name: skill.name,
            description: skill.description,
            source: ContractSkills.sourceUser,
            enabled: enabled[skill.name] ?? true,
            path: path,
          ),
        );
      }
    } else if (entries != null) {
      errors.add('宿主返回的 entries 不是列表（已按空清单处理）。');
    }

    final snapshot = SkillsSnapshot(
      builtin: _builtinViews(enabled),
      user: user,
      errors: errors,
    );
    _last = snapshot;
    return snapshot;
  }

  /// 启停（内置与用户技能**共用宿主那张表**）。
  ///
  /// 成功后同步本地快照：页面只翻一个开关，不必重拉整张表。
  Future<SkillOpResult> setSkillEnabled(String name, bool enabled) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const SkillOpResult.fail('技能名不能为空。');
    }

    final reply = await _invoke(
      ContractSkills.setEnabledMethod,
      <String, Object?>{'name': trimmed, 'enabled': enabled},
    );
    if (reply.missing) {
      return const SkillOpResult.fail(
        _channelMissingMessage,
        code: errChannelMissing,
      );
    }

    final data = reply.data;
    if (data == null) {
      return const SkillOpResult.fail('宿主没有返回结果（通道返回 null）。');
    }
    if (data['ok'] != true) {
      return SkillOpResult.fail(
        _errorOf(data, '宿主未能保存「$trimmed」的启停状态。'),
        code: _codeOf(data),
      );
    }

    _applyEnabled(trimmed, enabled);
    return const SkillOpResult.ok();
  }

  /// 安装技能（`https://` URL 或绝对路径；来源校验在宿主）。
  ///
  /// **坏技能回滚**：宿主只搬字节，装回来的 `SKILL.md` 可能根本解析不了。
  /// 这种文件留在磁盘上比"没装上"更糟（用户以为装好了，模型却永远看不到），
  /// 因此逐条调用 `skillsRemove` 删掉，并把原因写进 [InstallResult.errors]。
  Future<InstallResult> installSkill(String source) async {
    final ws = _normalizedWorkspace;
    if (ws == null) {
      return const InstallResult(
        ok: false,
        error: _noWorkspaceMessage,
        code: ContractSkills.errNoWorkspace,
      );
    }

    final reply = await _invoke(ContractSkills.installMethod, <String, Object?>{
      'workspace': ws,
      'source': source,
    });
    if (reply.missing) {
      return const InstallResult(
        ok: false,
        error: '当前版本的应用没有提供技能通道，无法安装技能。请升级 App。',
        code: errChannelMissing,
      );
    }

    final data = reply.data;
    if (data == null) {
      return const InstallResult(ok: false, error: '宿主没有返回结果（通道返回 null）。');
    }

    final errors = _stringListOf(data['errors']);
    if (data['ok'] != true) {
      return InstallResult(
        ok: false,
        errors: errors,
        error: _errorOf(data, '安装技能失败。'),
        code: _codeOf(data),
      );
    }

    final installed = <SkillView>[];
    final broken = <({String path, String error})>[];
    final entries = data['installed'];
    if (entries is List) {
      for (final e in entries) {
        if (e is! Map) {
          errors.add('宿主返回了一条无法识别的安装结果（已跳过）。');
          continue;
        }
        final path = e['path'];
        final raw = e['raw'];
        if (path is! String || raw is! String) {
          errors.add('宿主返回的安装结果缺少 path/raw（已跳过）。');
          continue;
        }
        final parsed = parseSkillMd(raw, source: ContractSkills.sourceUser);
        if (!parsed.ok) {
          broken.add((path: path, error: parsed.error!));
          continue;
        }
        final skill = parsed.skill!;
        installed.add(
          SkillView(
            name: skill.name,
            description: skill.description,
            source: ContractSkills.sourceUser,
            // 刚装上就是"启用"（宿主缺省 true）；不在这里猜用户偏好。
            enabled: true,
            path: path,
          ),
        );
      }
    }

    for (final bad in broken) {
      final rolledBack = await _rollback(ws, bad.path);
      errors.add(
        rolledBack
            ? '${bad.path}: ${bad.error}（已回滚删除）'
            : '${bad.path}: ${bad.error}（回滚失败，文件可能仍在磁盘上，请手动删除）',
      );
    }

    return InstallResult(
      ok: broken.isEmpty && errors.isEmpty,
      installed: installed,
      errors: errors,
    );
  }

  /// 卸载用户技能。
  ///
  /// 优先用**已解析清单里的 `path`** 定位：同名技能可能散在不同分类目录下，
  /// 只给 name 让宿主自己找会删错。内置技能直接拒绝 —— 它们不在工作区里，
  /// 让宿主回"未找到"只会把"不可删"说成"删失败了"。
  Future<RemoveSkillResult> removeSkill(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const RemoveSkillResult.fail('技能名不能为空。');
    }

    final builtin = builtinSkillEntries();
    if (builtin.any((e) => e.name == trimmed)) {
      return const RemoveSkillResult.fail(
        '内置技能随 App 一起发布，不能卸载；如果想让它不生效，请关闭开关。',
      );
    }

    final ws = _normalizedWorkspace;
    if (ws == null) {
      return const RemoveSkillResult.fail(
        _noWorkspaceMessage,
        code: ContractSkills.errNoWorkspace,
      );
    }

    final arguments = <String, Object?>{'workspace': ws, 'name': trimmed};
    final knownPath = _last?.viewOf(trimmed)?.path;
    if (knownPath != null && knownPath.isNotEmpty) {
      arguments['path'] = knownPath;
    }

    final reply = await _invoke(ContractSkills.removeMethod, arguments);
    if (reply.missing) {
      return const RemoveSkillResult.fail(
        '当前版本的应用没有提供技能通道，无法卸载技能。请升级 App。',
        code: errChannelMissing,
      );
    }

    final data = reply.data;
    if (data == null) {
      return const RemoveSkillResult.fail('宿主没有返回结果（通道返回 null）。');
    }
    if (data['ok'] != true) {
      return RemoveSkillResult.fail(
        _errorOf(data, '宿主未能卸载「$trimmed」。'),
        code: _codeOf(data),
      );
    }
    if (data['removed'] != true) {
      return const RemoveSkillResult.fail(
        '宿主没有找到要卸载的技能（可能已经被删除或改名）。',
        code: ContractSkills.errNotFound,
      );
    }

    _dropFromSnapshot(trimmed);
    return const RemoveSkillResult.ok();
  }

  // ==========================================================================
  // 通道
  // ==========================================================================

  Future<_Reply> _invoke(String method, Map<String, Object?> arguments) async {
    try {
      final data = await _channel.invokeMapMethod<String, Object?>(
        method,
        arguments,
      );
      return _Reply(data);
    } on MissingPluginException {
      return const _Reply.missing();
    } on PlatformException catch (e) {
      // 契约要求宿主不抛，但旧实现/宿主 bug 可能抛：转成统一的失败形状，
      // 别让一个 PlatformException 冒到 UI 变红屏。
      return _Reply(<String, Object?>{
        'ok': false,
        'error': (e.message ?? '').trim().isEmpty
            ? '技能通道调用失败（${e.code}）。'
            : e.message,
        'code': e.code,
      });
    }
  }

  /// 回滚一个坏技能：删掉刚装上的文件。返回是否真的删成功。
  Future<bool> _rollback(String workspace, String path) async {
    final reply = await _invoke(ContractSkills.removeMethod, <String, Object?>{
      'workspace': workspace,
      'name': _nameGuessOf(path),
      'path': path,
    });
    final data = reply.data;
    return !reply.missing && data != null && data['ok'] == true;
  }

  // ==========================================================================
  // 内部工具
  // ==========================================================================

  /// 归一化工作区：去空白、去尾部 `/`。空 ⇒ null（按"没有工作区"处理）。
  String? get _normalizedWorkspace {
    final raw = workspace?.trim();
    if (raw == null || raw.isEmpty) return null;
    var t = raw.replaceAll('\\', '/');
    while (t.length > 1 && t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  List<SkillView> _builtinViews(Map<String, bool> enabled) => <SkillView>[
    for (final e in builtinSkillEntries())
      SkillView(
        name: e.name,
        description: e.description,
        source: ContractSkills.sourceBuiltin,
        // 宿主表里没有 ⇒ 用 backend 的出厂默认（`enabled=true`）。
        enabled: enabled[e.name] ?? e.enabled,
        path: '',
      ),
  ];

  /// 通道缺失：内置仍列出（不依赖宿主），用户列表为空 + 一条人话说明。
  SkillsSnapshot _degradedSnapshot() => SkillsSnapshot(
    builtin: _builtinViews(const <String, bool>{}),
    user: const <SkillView>[],
    errors: const <String>[_channelMissingMessage],
    error: _channelMissingMessage,
    code: errChannelMissing,
  );

  SkillsSnapshot _failedSnapshot(String message, {String? code}) =>
      SkillsSnapshot(
        builtin: _builtinViews(const <String, bool>{}),
        user: const <SkillView>[],
        errors: <String>[message],
        error: message,
        code: code,
      );

  void _applyEnabled(String name, bool enabled) {
    final snapshot = _last;
    if (snapshot == null) return;
    List<SkillView> map(List<SkillView> src) => <SkillView>[
      for (final v in src)
        if (v.name == name) v.copyWith(enabled: enabled) else v,
    ];
    _last = SkillsSnapshot(
      builtin: map(snapshot.builtin),
      user: map(snapshot.user),
      errors: snapshot.errors,
    );
  }

  void _dropFromSnapshot(String name) {
    final snapshot = _last;
    if (snapshot == null) return;
    _last = SkillsSnapshot(
      builtin: snapshot.builtin,
      user: <SkillView>[
        for (final v in snapshot.user)
          if (v.name != name) v,
      ],
      errors: snapshot.errors,
    );
  }

  Map<String, bool> _enabledOf(Object? raw) {
    final out = <String, bool>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        final k = e.key;
        final v = e.value;
        if (k is String && v is bool) out[k] = v;
      }
    }
    return out;
  }

  List<String> _stringListOf(Object? raw) => <String>[
    if (raw is List)
      for (final e in raw)
        if (e is String && e.trim().isNotEmpty) e,
  ];

  String _errorOf(Map<String, Object?> data, String fallback) {
    final e = data['error'];
    return e is String && e.trim().isNotEmpty ? e : fallback;
  }

  String? _codeOf(Map<String, Object?> data) {
    final c = data['code'];
    return c is String && c.trim().isNotEmpty ? c : null;
  }

  /// 从 `<...>/skills/<slug>/SKILL.md` 猜出目录名，仅用于回滚时的 `name` 入参。
  ///
  /// 为什么猜：解析失败的技能拿不到 front-matter 里的 `name`，而宿主接口要求
  /// `name` 必填。**定位靠 `path`**（契约里 path 优先），name 只是陪跑。
  String _nameGuessOf(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return parts[parts.length - 2];
    return 'unknown';
  }

  static const String _channelMissingMessage =
      '当前版本的应用没有提供技能通道（旧版本宿主），读不到工作区里的用户技能；内置技能仍可查看。升级 App 后可管理自定义技能。';
}
