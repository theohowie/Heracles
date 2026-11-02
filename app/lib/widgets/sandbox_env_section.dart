// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 沙箱环境区**（2026-11-02，对应 #3/T0）。
//
// 数据全部来自真实通道（`SandboxService.envProfile / installEnv / uninstallEnv /
// detectProjectEnv`，契约见 docs/INTERFACE.md §N15）：
//   · 隔离档位：只有 process(L1) 已实现；container/vm 必须显示「未实现」+ note，
//     **禁止画成可用、禁止给安装按钮**；
//   · 网络策略：whitelistOnly / allowAllOutbound 如实展示；riskLevel=high 打风险标；
//     riskNote **原样展示**（含"策略级，非硬隔离"）；
//   · 环境清单：5 配方 node/python3/deno/bun/go，逐项 已安装/未安装/未知；
//     安装/卸载走真实 API；安装中禁用防连点；失败显示 error/message 人话，
//     **绝不显示成功**；verifiedVersion==null 显示「未校验」，不编版本；
//   · 降级：envProfile 抛异常/通道未实现 ⇒ 「当前版本不支持环境管理」+ 原因，
//     不返回假数据、不画假开关；
//   · 项目识别：detectProjectEnv 空结果 ⇒ 「认不出项目类型」，不猜命令。

import 'package:flutter/material.dart';

import '../services/sandbox_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

/// 5 个配方（与 backend sandbox 的 recipe 名逐字一致）。
const List<String> kSandboxEnvRecipes = <String>[
  'node',
  'python3',
  'deno',
  'bun',
  'go',
];

class SandboxEnvSection extends StatefulWidget {
  const SandboxEnvSection({super.key, this.service});

  /// 可注入（测试用）；默认新建一个 SandboxService。
  final SandboxService? service;

  @override
  State<SandboxEnvSection> createState() => _SandboxEnvSectionState();
}

class _SandboxEnvSectionState extends State<SandboxEnvSection> {
  late final SandboxService _service = widget.service ?? SandboxService();

  SandboxEnvProfile? _profile;
  String? _degrade;
  bool _loading = true;

  /// 正在安装/卸载的配方（按钮禁用 + 转圈）
  final Set<String> _busy = <String>{};

  /// 每个配方最近一次操作结果的人话（成功/失败都写这里）
  final Map<String, String> _notes = <String, String>{};

  /// 项目识别结果（空 = 认不出）
  List<String> _projectEnvs = const <String>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _degrade = null;
    });
    try {
      final p = await _service.envProfile();
      List<String> detected = const <String>[];
      try {
        detected = await _service.detectProjectEnv(const <String>[]);
      } catch (_) {
        // 识别失败不影响环境清单；空 = 认不出
        detected = const <String>[];
      }
      if (!mounted) return;
      setState(() {
        _profile = p;
        _projectEnvs = detected;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _degrade = _humanError(e);
        _loading = false;
      });
    }
  }

  Future<void> _run(String name, {required bool install}) async {
    if (_busy.contains(name)) return;
    setState(() => _busy.add(name));
    try {
      final r = install
          ? await _service.installEnv(name)
          : await _service.uninstallEnv(name);
      if (!mounted) return;
      setState(() {
        _notes[name] = _resultText(r, name: name, install: install);
      });
      // 成功/失败都重查一次真实状态（不乐观改 UI）
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _notes[name] = _humanError(e));
    } finally {
      if (mounted) setState(() => _busy.remove(name));
    }
  }

  /// 结果人话：ok=false **绝不显示成功**；版本没校验就说「未校验」。
  static String _resultText(SandboxEnvInstallResult r,
      {required String name, required bool install}) {
    if (!r.ok) {
      final why = r.error ?? r.message ?? '未给出原因';
      return '${install ? '安装' : '卸载'}失败：$why';
    }
    final ver = r.verifiedVersion == null
        ? '版本未校验'
        : '版本 ${r.verifiedVersion}';
    final size = r.approxBytes > 0
        ? ' · 约 ${(r.approxBytes / (1024 * 1024)).toStringAsFixed(0)} MB'
        : '';
    return '${install ? '已安装' : '已卸载'} $name · $ver$size';
  }

  static String _humanError(Object e) {
    final s = e.toString();
    // 通道未实现/未接通是"能力缺失"，不是用户操作错误
    if (s.contains('未知方法') || s.contains('MethodNotFound')) {
      return '当前版本不支持环境管理（通道未实现 envProfile）';
    }
    if (s.contains('不存在') || s.contains('not found')) {
      return '环境服务不可用：$s';
    }
    return '读取环境信息失败：$s';
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Container(
      key: const Key('sandbox-env-section'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.terminal, size: 16, color: h.textDim),
              const SizedBox(width: 8),
              Text('环境',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: h.text)),
              const Spacer(),
              if (_loading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: h.textFaint),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_degrade != null) ...[
            Text(
              '当前版本不支持环境管理',
              key: const Key('sandbox-env-degrade'),
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: h.text),
            ),
            const SizedBox(height: 4),
            Text(_degrade!,
                style: TextStyle(
                    fontSize: 11.5, height: 1.45, color: h.textFaint)),
          ] else if (_profile != null) ...[
            _isolationRow(h, _profile!),
            const SizedBox(height: 8),
            _networkRows(h, _profile!),
            const SizedBox(height: 8),
            _projectRow(h),
            const SizedBox(height: 10),
            Text('已安装环境',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: h.textDim)),
            const SizedBox(height: 4),
            for (final name in kSandboxEnvRecipes) _envRow(h, name),
          ],
        ],
      ),
    );
  }

  Widget _isolationRow(Hue h, SandboxEnvProfile p) {
    final implemented = p.tierImplemented && p.isolationTier == 'process';
    final tierText = implemented
        ? '已实现（L1 进程级）'
        : '未实现（${p.isolationTier}）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 64,
              child: Text('隔离档位',
                  style: TextStyle(fontSize: 12, color: h.textDim)),
            ),
            Expanded(
              child: Text(
                tierText,
                key: const Key('sandbox-env-tier'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: implemented ? h.text : h.textFaint),
              ),
            ),
          ],
        ),
        if (!implemented && (p.tierNote ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 64),
            child: Text(p.tierNote!,
                key: const Key('sandbox-env-tier-note'),
                style: TextStyle(
                    fontSize: 11, height: 1.4, color: h.textFaint)),
          ),
      ],
    );
  }

  Widget _networkRows(Hue h, SandboxEnvProfile p) {
    final mode = p.allowAllOutbound
        ? '自由出网（已开启）'
        : (p.whitelistOnly ? '仅白名单' : '未限制');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 64,
              child: Text('网络策略',
                  style: TextStyle(fontSize: 12, color: h.textDim)),
            ),
            Expanded(
              child: Text(mode,
                  key: const Key('sandbox-env-network'),
                  style: TextStyle(fontSize: 12, color: h.text)),
            ),
            if (p.riskLevel == 'high')
              Container(
                key: const Key('sandbox-env-risk-badge'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: h.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(HRadius.sm),
                ),
                child: Text('高风险',
                    style: TextStyle(fontSize: 10.5, color: h.accent)),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 64),
          child: Text(
            p.riskNote,
            key: const Key('sandbox-env-risk-note'),
            style: TextStyle(fontSize: 11, height: 1.4, color: h.textFaint),
          ),
        ),
        if (p.hosts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 64),
            child: Text('白名单：${p.hosts.take(6).join('、')}'
                '${p.hosts.length > 6 ? ' 等 ${p.hosts.length} 个' : ''}',
                style:
                    TextStyle(fontSize: 11, height: 1.4, color: h.textFaint)),
          ),
        if (p.proxy.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 64),
            child: Text('代理：${p.proxy}',
                style:
                    TextStyle(fontSize: 11, height: 1.4, color: h.textFaint)),
          ),
      ],
    );
  }

  Widget _projectRow(Hue h) {
    final text = _projectEnvs.isEmpty
        ? '认不出项目类型（未检测到可识别的项目文件）'
        : '检测到：${_projectEnvs.join('、')}';
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text('项目识别',
              style: TextStyle(fontSize: 12, color: h.textDim)),
        ),
        Expanded(
          child: Text(text,
              key: const Key('sandbox-env-project'),
              style: TextStyle(
                  fontSize: 12,
                  color: _projectEnvs.isEmpty ? h.textFaint : h.text)),
        ),
      ],
    );
  }

  Widget _envRow(Hue h, String name) {
    final p = _profile!;
    final installed = p.envs.contains(name);
    final busy = _busy.contains(name);
    final note = _notes[name];
    final canAct = p.tierImplemented && !busy;
    return Padding(
      key: Key('sandbox-env-$name'),
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(name,
                    style: TextStyle(fontSize: 12.5, color: h.text)),
              ),
              Expanded(
                child: Text(
                  installed ? '已安装' : '未安装',
                  key: Key('sandbox-env-$name-status'),
                  style: TextStyle(
                      fontSize: 12,
                      color: installed ? h.text : h.textFaint),
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  key: Key('sandbox-env-$name-action'),
                  onPressed: canAct
                      ? () => _run(name, install: !installed)
                      : null,
                  child: Text(installed ? '卸载' : '安装',
                      style: TextStyle(
                          fontSize: 12,
                          color: canAct ? h.accent : h.textFaint)),
                ),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 76, bottom: 2),
              child: Text(
                note,
                key: Key('sandbox-env-$name-note'),
                style: TextStyle(
                    fontSize: 11, height: 1.4, color: h.textFaint),
              ),
            ),
        ],
      ),
    );
  }
}
