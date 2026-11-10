// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **搜索服务设置页**（2026-11-03，对应 #6）。
//
// 后端 `SearchConfigService` 已就绪（仅免鉴权）：endpoint 存安全存储，
// `save()` 会做**合法校验**（非法 endpoint 整笔拒绝并回人话）。
//
// · 三态显示：未配置 / 已配置（endpoint 原样）/ 读取失败如实
//   （`SearchConfigException` = 环境坏，message 已脱敏、永不含 Key）；
// · **不建 Key 输入框**（§13：当前版本仅支持免鉴权搜索服务）——
//   置灰写死「当前版本仅支持免鉴权搜索服务，无需 API Key」；
//   硬传 Key 后端 save() 整笔拒绝并回人话（契约红线）；
// · web_search 未配置文案为「尚未配置搜索服务：…」（§13.2），
//   由 `device_capabilities` 在运行时给出，本页不重复、不改动。
//
// 行样式沿用权限页 / KeepaliveRow 规格（图标砖 + 标题 + 说明 + 右侧控件）。

import 'package:flutter/material.dart';

import '../services/search_config_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../widgets/background_keepalive_card.dart';

import 'package:heracles/i18n/l10n.dart';

class SearchSettingsScreen extends StatefulWidget {
  const SearchSettingsScreen({super.key, this.service});

  /// 搜索配置通道（F4 已就绪）。测试可注入替身；默认走真通道。
  final SearchConfigService? service;

  @override
  State<SearchSettingsScreen> createState() => _SearchSettingsScreenState();
}

class _SearchSettingsScreenState extends State<SearchSettingsScreen> {
  late final SearchConfigService _service =
      widget.service ?? SearchConfigService();

  final _endpoint = TextEditingController();

  /// 三态：null = 还在读；false = 读取失败（[_readError] 如实）；
  /// true = 读到了（[_endpoint] 里是真实值，可能为空 = 未配置）。
  bool? _loaded;
  String? _readError;
  bool _saving = false;
  String? _saveMessage;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final r = await _service.read();
      if (!mounted) return;
      setState(() {
        _endpoint.text = r.endpoint;
        _loaded = true;
        _readError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = false;
        _readError = e.toString();
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      final r = await _service.save(_endpoint.text.trim());
      if (!mounted) return;
      setState(() {
        _saveMessage = r.ok ? tr('已保存') : r.message; // 非法拒绝原样上屏（人话）
        _saving = false;
      });
      if (r.ok) await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveMessage = '保存失败：$e';
        _saving = false;
      });
    }
  }

  Future<void> _clear() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      await _service.clear();
      if (!mounted) return;
      setState(() => _saving = false);
      await _reload();
      if (mounted) showIosToast(context, tr('已清除搜索服务配置'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveMessage = '清除失败：$e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final configured = _loaded == true && _endpoint.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: Text(tr('搜索服务')),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding:
            const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          // ---- 三态显示（权限页 / KeepaliveRow 规格） ----
          KeepaliveRow(
            icon: AppIcons.search,
            title: tr('搜索 endpoint'),
            subtitle: _loaded == null
                ? tr('读取中…')
                : (_loaded == false
                    ? '读取失败：$_readError'
                    : (configured
                        ? '已配置：${_endpoint.text.trim()}'
                        : '未配置。web_search 在未配置时会明确失败，不会编造结果。')),
            subtitleKey: const Key('search-state'),
          ),
          const SizedBox(height: HSpace.md),
          if (_loaded == false)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(tr('配置读取失败（环境问题），本页暂不能编辑。错误信息已脱敏。'),
                key: const Key('search-read-error'),
                style: TextStyle(fontSize: 12, height: 1.5, color: h.accent),
              ),
            )
          else ...[
            TextField(
              key: const Key('search-endpoint'),
              controller: _endpoint,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                  labelText: tr('endpoint（免鉴权搜索服务）')),
            ),
            // ★ §13：不建 Key 输入框 —— 置灰写死说明（硬传 Key 后端整笔拒绝）。
            TextField(
              key: const Key('search-key-note'),
              enabled: false,
              controller: TextEditingController(
                  text: '当前版本仅支持免鉴权搜索服务，无需 API Key'),
              style: TextStyle(fontSize: 12, color: h.textFaint),
              decoration: InputDecoration(labelText: 'API Key'),
            ),
            const SizedBox(height: HSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('search-clear'),
                  onPressed: _saving ? null : _clear,
                  child:
                      Text(tr('清除'), style: TextStyle(fontSize: 13, color: h.accent)),
                ),
                const SizedBox(width: HSpace.sm),
                TextButton(
                  key: const Key('search-save'),
                  onPressed: _saving ? null : _save,
                  child:
                      Text(tr('保存'), style: TextStyle(fontSize: 13, color: h.accent)),
                ),
              ],
            ),
            if (_saveMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _saveMessage!,
                  key: const Key('search-save-message'),
                  style: TextStyle(
                      fontSize: 12, height: 1.5, color: h.textDim),
                ),
              ),
            const SizedBox(height: HSpace.md),
            Text(tr('web_search 未配置时的提示是「尚未配置搜索服务：请在设置里填写搜索 endpoint 后重试」——'
              '配置好这里之后，该提示自然消失。'),
              style: TextStyle(fontSize: 12, height: 1.6, color: h.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}
