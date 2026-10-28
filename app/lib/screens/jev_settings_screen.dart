import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/jev.dart';
import '../services/jev_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/elastic_switch.dart';
import '../theme/pressable.dart';

/// **JEV 决策引擎编辑页**（2026-10-27 建，2026-10-28 按用户要求
/// 重排并搬家）。
///
/// 位置：设置 →「模型」页里与各提供商并列一张卡，点「编辑」进来，
/// 版式与「编辑提供商」页一致（字段 + 右上「保存」）。
///
/// 内容顺序（用户定）：**云端在前**（接口地址 / 密钥 / 模型 +
/// 生成理由开关），**本机检测与本地模型在后**。引擎来源不在这里
/// 选 —— 已按用户要求挪到决策页输入框的来源胶囊抽屉里切换。
class JevSettingsScreen extends StatefulWidget {
  const JevSettingsScreen({super.key, required this.jev});

  final JevController jev;

  @override
  State<JevSettingsScreen> createState() => _JevSettingsScreenState();
}

class _JevSettingsScreenState extends State<JevSettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  bool _keyLoaded = false;
  bool _obscureKey = true;

  JevController get jev => widget.jev;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = jev.config.cloudBaseUrl;
    _modelCtrl.text = jev.config.cloudModel;
    unawaited(_loadKey());
    if (!jev.loaded) unawaited(jev.load());
  }

  Future<void> _loadKey() async {
    var key = '';
    try {
      key = await JevStore.readCloudKey();
    } catch (_) {
      // 安全存储不可用（测试环境/异常机型）时按未配置处理，不崩页。
      key = '';
    }
    if (!mounted) return;
    _keyCtrl.text = key;
    _keyLoaded = true;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveCloud() async {
    await jev.updateConfig(
      jev.config.copyWith(
        cloudBaseUrl: _urlCtrl.text.trim(),
        cloudModel: _modelCtrl.text.trim(),
      ),
    );
    if (_keyLoaded) await JevStore.writeCloudKey(_keyCtrl.text.trim());
    if (!mounted) return;
    showIosToast(context, '已保存');
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('JEV 决策引擎'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          CupertinoButton(
            onPressed: () => unawaited(_saveCloud()),
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
            foregroundColor: h.accent,
            child: const Text('保存'),
          ),
          const SizedBox(width: HSpace.sm),
        ],
      ),
      body: AnimatedBuilder(
        animation: jev,
        builder: (context, _) {
          final config = jev.config;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              HSpace.lg,
              HSpace.md,
              HSpace.lg,
              HSpace.xl,
            ),
            children: [
              // ★ 顺序（2026-10-28 用户定）：云端在前，本机检测与
              // 本地模型在后；引擎来源不在本页 —— 在决策页输入框
              // 左下角的来源胶囊里点按切换（同工作模式切模型）。
              Text(
                '引擎来源（云端 / 本地）在决策页输入框左下角点按切换；'
                '这里只编辑云端接口与本地模型。',
                style: TextStyle(fontSize: 13, color: h.textFaint, height: 1.5),
              ),
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '云端'),
              _field(
                h,
                '接口地址',
                _urlCtrl,
                hint: '如 https://你的服务/v1，填到 /v1 为止',
              ),
              const SizedBox(height: HSpace.md),
              _field(
                h,
                'API 密钥',
                _keyCtrl,
                hint: '自建服务可留空',
                obscure: _obscureKey,
                trailing: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
                  minimumSize: const Size(0, 32),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  child: Icon(
                    _obscureKey ? CupertinoIcons.eye_slash : AppIcons.eye,
                    size: 19,
                    color: h.textFaint,
                  ),
                ),
              ),
              const SizedBox(height: HSpace.md),
              _field(h, '模型', _modelCtrl, hint: '选填，如 StartLux-Decision 27B'),
              const SizedBox(height: HSpace.sm),
              Text(
                '改完点右上角「保存」。本地模型在本机出决策、不联网；'
                '云端用更强的大参数模型（如 27B），需要接口地址与密钥。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.55),
              ),
              const SizedBox(height: HSpace.lg),
              _card(h, [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '生成理由',
                            style: HTxt.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '决策模型只给结论和概率；开启后由当前对话模型'
                            '补写一两句理由（云端模型自带的思考会优先用）。',
                            style: HTxt.caption.copyWith(
                              color: h.textFaint,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: HSpace.md),
                    ElasticSwitch(
                      value: config.reasonEnabled,
                      onChanged: (v) => unawaited(
                        jev.updateConfig(config.copyWith(reasonEnabled: v)),
                      ),
                    ),
                  ],
                ),
              ]),
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '本机检测'),
              _card(h, [_profileBody(h)]),
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '本地模型'),
              _card(h, [
                for (var i = 0; i < kJevModelSpecs.length; i++) ...[
                  if (i > 0) ...[
                    const SizedBox(height: HSpace.md),
                    Divider(height: 1, color: h.border),
                    const SizedBox(height: HSpace.md),
                  ],
                  _modelRow(h, kJevModelSpecs[i]),
                ],
                const SizedBox(height: HSpace.md),
                Text(
                  '本地推理引擎尚未接入：模型可以先下载备好，引擎由'
                  '后端接入后即可离线决策；现在想体验，先用云端。'
                  '权重为 StartLux-Decision（CC BY-NC 4.0，非商业使用），'
                  '经 Hugging Face 下载（镜像优先）；另含引擎所需的'
                  'tokenizer 与决策配置文件。',
                  style: HTxt.caption.copyWith(
                    color: h.textFaint,
                    height: 1.55,
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }

  Widget _profileBody(Hue h) {
    final p = jev.profile;
    if (p == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '检测不可用（宿主未返回本机信息）。云端决策不受影响。',
            style: HTxt.secondary.copyWith(color: h.textDim, height: 1.55),
          ),
          const SizedBox(height: HSpace.sm),
          GestureDetector(
            onTap: () => unawaited(jev.reloadProfile()),
            behavior: HitTestBehavior.opaque,
            child: Text(
              '重新检测',
              style: HTxt.secondary.copyWith(
                color: h.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    }
    final rec = jev.recommendation!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv(h, '机型', p.model.isEmpty ? '未知' : p.model),
        Divider(height: 17, color: h.border),
        _kv(h, '运行内存', '${p.totalRamGb.toStringAsFixed(0)} GB'),
        Divider(height: 17, color: h.border),
        _kv(h, '可用存储', '${p.freeStorageGb.toStringAsFixed(0)} GB'),
        const SizedBox(height: HSpace.md),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(
              0xFF22C55E,
            ).withValues(alpha: h.dark ? 0.16 : 0.08),
            border: Border.all(
              color: const Color(
                0xFF22C55E,
              ).withValues(alpha: h.dark ? 0.5 : 0.3),
            ),
            borderRadius: BorderRadius.circular(HRadius.md),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${rec.headline} — ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: rec.detail),
              ],
            ),
            style: TextStyle(fontSize: 13.5, height: 1.55, color: h.text),
          ),
        ),
        if (rec.source != null && rec.source != jev.config.source) ...[
          const SizedBox(height: HSpace.sm),
          GestureDetector(
            onTap: () => unawaited(
              jev.updateConfig(jev.config.copyWith(source: rec.source)),
            ),
            behavior: HitTestBehavior.opaque,
            child: Text(
              '按推荐切换到「${rec.source!.label}」',
              style: HTxt.secondary.copyWith(
                color: h.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _modelRow(Hue h, JevModelSpec spec) {
    final state = jev.downloads[spec.source] ?? const JevDownloadState();
    final downloaded = jev.isDownloaded(spec.source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: h.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                downloaded ? Icons.check : Icons.balance,
                size: 19,
                color: h.text,
              ),
            ),
            const SizedBox(width: HSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spec.displayName,
                    style: HTxt.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${spec.quantLabel} · ${spec.sizeLabel} · ${_modelStatusText(spec, state)}',
                    style: HTxt.caption.copyWith(color: h.textFaint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HSpace.sm),
            _modelAction(h, spec, state),
          ],
        ),
        if (state.phase == JevDownloadPhase.downloading) ...[
          const SizedBox(height: HSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(HRadius.pill),
            child: LinearProgressIndicator(
              value: state.fraction,
              minHeight: 6,
              backgroundColor: h.border,
              color: h.text,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${state.note ?? '正在下载'} · ${jevFormatBytes(state.received)}'
            '${state.total > 0 ? ' / ${jevFormatBytes(state.total)}' : ''}',
            style: HTxt.caption.copyWith(color: h.textFaint),
          ),
        ],
        if (state.phase == JevDownloadPhase.error && state.error != null) ...[
          const SizedBox(height: HSpace.sm),
          Text(
            state.error!,
            style: HTxt.caption.copyWith(
              color: const Color(0xFFDC2626),
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  String _modelStatusText(JevModelSpec spec, JevDownloadState state) {
    if (jev.isDownloaded(spec.source)) return '已下载';
    return switch (state.phase) {
      JevDownloadPhase.downloading => '下载中',
      JevDownloadPhase.error => '下载失败',
      _ => '未下载',
    };
  }

  Widget _modelAction(Hue h, JevModelSpec spec, JevDownloadState state) {
    if (state.phase == JevDownloadPhase.downloading) {
      return _pillButton(
        h,
        label: '取消',
        filled: false,
        onTap: () => jev.cancelDownload(spec.source),
      );
    }
    if (jev.isDownloaded(spec.source)) {
      return _pillButton(
        h,
        label: '删除',
        filled: false,
        onTap: () => unawaited(jev.deleteModel(spec)),
      );
    }
    return _pillButton(
      h,
      label: '下载',
      filled: true,
      onTap: jev.profile == null
          ? null
          : () => unawaited(jev.startDownload(spec)),
    );
  }

  Widget _pillButton(
    Hue h, {
    required String label,
    required bool filled,
    required VoidCallback? onTap,
  }) {
    return Pressable(
      enabled: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: filled ? h.text : h.surface,
            borderRadius: BorderRadius.circular(HRadius.pill),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: onTap == null ? h.textFaint : (filled ? h.bg : h.text),
            ),
          ),
        ),
      ),
    );
  }

  /// 字段 —— 与「编辑提供商」页同一规格（2026-10-28 搬家后对齐）：
  /// 小标签在上、描边圆角框、右端可挂操作（如密钥可见切换）。
  Widget _field(
    Hue h,
    String label,
    TextEditingController ctrl, {
    String? hint,
    bool obscure = false,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: h.textDim)),
        const SizedBox(height: HSpace.sm),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: h.border),
            borderRadius: BorderRadius.circular(HRadius.sm),
          ),
          child: Row(
            children: [
              Expanded(
                child: CupertinoTextField.borderless(
                  controller: ctrl,
                  obscureText: obscure,
                  placeholder: hint,
                  placeholderStyle: TextStyle(fontSize: 14, color: h.textFaint),
                  style: TextStyle(fontSize: 14, color: h.text),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HSpace.md,
                    vertical: 12,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(Hue h, String k, String v) {
    return Row(
      children: [
        Text(k, style: HTxt.body.copyWith(color: h.textDim)),
        const Spacer(),
        Text(v, style: HTxt.body.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _groupLabel(Hue h, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(text, style: HTxt.sectionTitle.copyWith(color: h.textDim)),
    );
  }

  Widget _card(Hue h, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
