import 'dart:async';

import 'package:flutter/material.dart';

import '../services/voice_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/pressable.dart';
import '../widgets/bw_approval.dart';

/// **语音识别设置页**（2026-10-29 用户定）：语音识别用本地模型，
/// 用户在这页自行下载 SenseVoiceSmall（ONNX），下载、校验、落盘
/// 与引擎准备都由 App 配好；模型就绪后输入框的麦克风按钮即可
/// 离线把语音转成文字。录音只在本机处理，不上传。
///
/// 麦克风**权限不在这页管**（2026-10-29 用户定）：权限统一在
/// 设置 → 设备权限页申请，一处就够，这页不放第二份。
class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  final _voice = VoiceModelController.shared();

  @override
  void initState() {
    super.initState();
    unawaited(_voice.load());
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('语音识别'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: AnimatedBuilder(
        animation: _voice,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              HSpace.lg,
              HSpace.md,
              HSpace.lg,
              HSpace.xl,
            ),
            children: [
              _groupLabel(h, '语音模型'),
              _card(h, [_modelRow(h)]),
              const SizedBox(height: HSpace.lg),
              Text(
                'SenseVoiceSmall（阿里 FunASR）多语言语音识别模型，'
                '支持中文、英文、粤语、日语、韩语，量化版约 231 MB，'
                '经 ModelScope 官方仓库下载。下载完成后 App 会自动'
                '备好识别引擎（补元数据、转词表）；点输入框旁的'
                '麦克风按钮即可把语音转成文字，识别全程在本机离线'
                '完成，录音不上传。麦克风权限在「设置 → 设备权限」'
                '里统一开启。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.55),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _modelRow(Hue h) {
    final state = _voice.download;
    final installed = _voice.installed;
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
                installed ? Icons.check : AppIcons.mic,
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
                    'SenseVoiceSmall',
                    style: HTxt.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'ONNX 量化版 · ${voiceFormatBytes(kVoiceModelTotalBytes)} · ${_statusText(state)}',
                    style: HTxt.caption.copyWith(color: h.textFaint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HSpace.sm),
            _modelAction(h, state),
          ],
        ),
        if (state.phase == VoiceModelPhase.downloading) ...[
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
            '${state.note ?? '正在下载'} · ${voiceFormatBytes(state.received)}'
            ' / ${voiceFormatBytes(state.total)}',
            style: HTxt.caption.copyWith(color: h.textFaint),
          ),
        ],
        if (state.phase == VoiceModelPhase.error && state.error != null) ...[
          const SizedBox(height: HSpace.sm),
          Text(
            state.error!,
            style: HTxt.caption.copyWith(
              color: const Color(0xFFDC2626),
              height: 1.5,
            ),
          ),
        ],
        if (_voice.prepareError != null) ...[
          const SizedBox(height: HSpace.sm),
          Text(
            _voice.prepareError!,
            style: HTxt.caption.copyWith(
              color: const Color(0xFFDC2626),
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  String _statusText(VoiceDownloadState state) {
    if (_voice.engineReady) return '已就绪';
    if (_voice.preparing) return '正在准备模型…';
    if (_voice.installed) return '已下载';
    return switch (state.phase) {
      VoiceModelPhase.downloading => '下载中',
      VoiceModelPhase.error => '下载失败',
      _ => '未下载',
    };
  }

  Widget _modelAction(Hue h, VoiceDownloadState state) {
    if (state.phase == VoiceModelPhase.downloading) {
      return _pillButton(
        h,
        label: '取消',
        filled: false,
        onTap: _voice.cancelDownload,
      );
    }
    if (_voice.installed) {
      return _pillButton(
        h,
        label: '删除',
        filled: false,
        onTap: () => unawaited(_confirmDelete(h)),
      );
    }
    return _pillButton(
      h,
      label: '下载',
      filled: true,
      onTap: _voice.profile == null
          ? null
          : () => unawaited(_voice.startDownload()),
    );
  }

  Future<void> _confirmDelete(Hue h) async {
    final ok = await showBwConfirmSheet(
      context,
      title: '删除语音模型？',
      message: '删除后语音输入将不可用，需要时可在本页重新下载。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (ok) await _voice.deleteModel();
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
