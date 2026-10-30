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
                '流式识别（内置）：14M 中文 streaming zipformer 已随 App 打包，'
                '约 24 MB，无需下载；点麦克风说话时会边说边出字，全程本机离线。\n\n'
                '整段识别（可选）：SenseVoiceSmall（阿里 FunASR）多语言模型，'
                '量化版约 231 MB，经 ModelScope 官方仓库下载，适合长句高精度转写。\n\n'
                '两套模型都存放在 App 私有目录，卸载 App 会一并删除；录音不上传。'
                '麦克风权限在「设置 → 设备权限」里统一开启。',
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
              // ★ 固定两行块（2026-10-29 用户反馈"下载时卡片抖"）：
              //   行 1 文件名、行 2 「已下载 X / Y」；两行都 maxLines:1
              //   ⇒ 行数被钉死，字节数变长/变短都改不了高度。
              //   高度用 minHeight:38（与左侧图标同高）而不是写死 SizedBox：
              //   字体放大时块会变高，不会被裁字（写死 2.0 缩放下必溢出）。
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 38),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SenseVoiceSmall',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HTxt.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _statusLine(state),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // ★ tabular figures：数字等宽 ⇒ 位数变化也不挤动文本
                      style: HTxt.caption.copyWith(
                        color: h.textFaint,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
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
          // 进度文案（原「正在下载 · X / Y」）已上收到行 2 的固定两行块里：
          // 放在进度条下面时它的折行会改变卡片高度 —— 这正是抖动的根因。
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

  /// 行 2 文案（固定一行）：
  /// · 下载中 ⇒ 「已下载 X / Y」（数值固定 1 位小数，配 tabular figures）；
  /// · 其它   ⇒ 「ONNX 量化版 · 230.4 MB · 未下载/已就绪…」。
  ///
  /// 为什么不把 `state.note`（'正在下载 model_quant.onnx'）放进来：文件名长度
  /// 会变，且它会跟字节数抢同一行的宽度预算 —— 抖动的两个来源都在这行。
  String _statusLine(VoiceDownloadState state) {
    if (state.phase == VoiceModelPhase.downloading) {
      return '已下载 ${_fmtFixed(state.received)} / ${_fmtFixed(state.total)}';
    }
    return 'ONNX 量化版 · ${voiceFormatBytes(kVoiceModelTotalBytes)} · '
        '${_statusText(state)}';
  }

  /// 固定 1 位小数的字节数（**宽度稳定**优先于单位语义）：
  /// 0 B 也写「0.0 KB」而不换回 B —— 保证「X.Y 单位」形状恒定；
  /// 再配 tabular figures，数字本身也等宽。
  String _fmtFixed(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
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
