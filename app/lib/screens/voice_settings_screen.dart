import 'dart:async';

import 'package:flutter/material.dart';

import '../services/voice_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/pressable.dart';
import '../widgets/bw_approval.dart';

/// **语音识别设置页**（2026-10-29 用户定；2026-10-31 T0-1 重做）。
///
/// 语音有两套**互相独立**的模型，各有各的状态：
///
/// 1. **流式识别（内置 · 约 24 MB）** —— 14M 中文 streaming zipformer 随 App
///    打包，首次点麦克风时自动解压，边说边出字；开箱即用、不需要下载。
/// 2. **整段识别 SenseVoice（可选 · 231 MB）** —— 阿里 FunASR 多语言模型，
///    经 ModelScope 官方仓库下载，适合长句高精度转写（流式不可用时的回退）。
///
/// 页顶总状态只回答"语音输入能不能用"：**流式内置就绪就算可用**，绝不因为
/// SenseVoice 没下载就把整体判成"未下载/需重下"（那样会让用户以为要下
/// 231 MB 才能用语音）。卸载/重装是真操作：`deleteAllVoiceModels()` 删三个
/// 模型目录并落盘卸载标记，`installVoiceModels()` 清标记并重新解压内置模型。
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

  /// 最近一次卸载/安装/重试的结果（人话）—— 结果如实写在页面上，
  /// 不用 toast 一闪而过（卸载释放了多少、哪项失败，用户要能回看）。
  String? _actionNote;

  /// 动作进行中：防止重复点（解压/删除都要几秒）。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_voice.load());
  }

  /// 已卸载（用户主动卸载或语音总开关被关）—— 之后绝不自动解压。
  bool get _uninstalled => _voice.voiceUninstalled || !_voice.voiceEnabled;

  /// 流式是否可用（内置已解压，或老用户下过双语模型）。
  bool get _streamingReady => !_uninstalled && _voice.streamingInstalled;

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
              _groupLabel(h, '语音输入'),
              _totalStatusRow(h),
              if (_actionNote != null) ...[
                const SizedBox(height: HSpace.sm),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    _actionNote!,
                    key: const Key('voice-action-note'),
                    style: HTxt.caption.copyWith(color: h.textDim, height: 1.5),
                  ),
                ),
              ],
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '语音模型'),
              _streamingCard(h),
              const SizedBox(height: HSpace.md),
              _senseVoiceCard(h),
              const SizedBox(height: HSpace.md),
              // ★ 2026-10-31（T0-1 f）：模型实际落盘目录 + 卸载即删说明。
              //   用户要能核对"到底装在哪、卸载删的是什么"——只写"App 私有目录"
              //   太虚；真实路径由 VoiceModelController 给出（profile.appFilesDir）。
              _modelsDirRow(h),
              const SizedBox(height: HSpace.lg),
              Text(
                '流式识别（内置）：14M 中文 streaming zipformer 已随 App 打包，'
                '约 24 MB，无需下载；点麦克风说话时会边说边出字，全程本机离线。\n\n'
                '整段识别（可选）：SenseVoiceSmall（阿里 FunASR）多语言模型，'
                '量化版约 231 MB，经 ModelScope 官方仓库下载，适合长句高精度转写。\n\n'
                '两套模型都存放在 App 私有目录，卸载 App 会一并删除；「卸载语音输入」'
                '会删掉两套模型并停用语音输入，可用「重新安装」重新解压内置模型。'
                '录音不上传。麦克风权限在「设置 → 设备权限」里统一开启。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.55),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- 总状态

  /// 页顶总状态文案（只回答"语音输入能不能用"）。
  String get _totalStatusText {
    if (!_voice.loaded) return '检测中…';
    if (_uninstalled) return '语音输入不可用（已卸载）';
    if (_voice.bundledStreamingProgress != null) {
      return '语音输入需准备 · 正在准备内置模型…';
    }
    if (_voice.streamingInstalled) return '语音输入可用 · 流式识别已就绪';
    if (_voice.installed && _voice.engineReady) {
      return '语音输入可用 · 整段识别已就绪';
    }
    if (_voice.bundledStreamingError != null) {
      return '语音输入需准备 · 内置模型准备失败（可重试）';
    }
    return '语音输入可用 · 首次使用时会自动准备内置模型';
  }

  Widget _totalStatusRow(Hue h) {
    final ready = _streamingReady || (!_uninstalled && _voice.installed && _voice.engineReady);
    final warn = _uninstalled || _voice.bundledStreamingError != null;
    final action = _uninstalled
        ? _pillButton(
            h,
            key: const Key('voice-install'),
            label: '重新安装',
            filled: true,
            onTap: _busy ? null : () => unawaited(_install()),
          )
        : (_voice.streamingInstalled || _voice.installed)
            ? _pillButton(
                h,
                key: const Key('voice-uninstall'),
                label: '卸载',
                filled: false,
                onTap: _busy ? null : () => unawaited(_confirmUninstall()),
              )
            : null;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: ready
                ? h.text
                : (warn ? HColors.errorOn(h.dark) : h.textFaint),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: HSpace.sm),
        Expanded(
          child: Text(
            _totalStatusText,
            key: const Key('voice-total-status'),
            style: HTxt.body.copyWith(fontWeight: FontWeight.w600, height: 1.4),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: HSpace.sm),
          action,
        ],
      ],
    );
  }

  // ------------------------------------------------------------ 流式（内置）

  String get _streamingStatusLine {
    const base = '中文 streaming zipformer · 约 24 MB';
    if (_uninstalled) return '$base · 已卸载';
    if (_voice.bundledStreamingReady) return '$base · 已就绪';
    if (_voice.streamingInstalled) return '$base · 已就绪（使用已下载的双语模型）';
    if (_voice.bundledStreamingError != null) return '$base · 准备失败';
    return '$base · 首次使用时自动准备';
  }

  Widget _streamingCard(Hue h) {
    final ready = _streamingReady;
    final error = _uninstalled ? null : _voice.bundledStreamingError;
    return _card(
      h,
      key: const Key('voice-streaming-card'),
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
                ready ? Icons.check : AppIcons.mic,
                size: 19,
                color: h.text,
              ),
            ),
            const SizedBox(width: HSpace.md),
            Expanded(
              // 固定两行块（与 SenseVoice 卡同规格）：下载/解压时进度文字
              // 变长也不会改卡片高度。
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 38),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '流式识别（内置）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HTxt.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _streamingStatusLine,
                      key: const Key('voice-streaming-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HTxt.caption.copyWith(
                        color: h.textFaint,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(width: HSpace.sm),
              _pillButton(
                h,
                key: const Key('voice-streaming-retry'),
                label: '重试',
                filled: true,
                onTap: _busy ? null : () => unawaited(_retryBundled()),
              ),
            ],
          ],
        ),
        if (_voice.bundledStreamingProgress != null &&
            !_uninstalled &&
            error == null) ...[
          const SizedBox(height: HSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(HRadius.pill),
            child: LinearProgressIndicator(
              value: _voice.bundledStreamingProgress,
              minHeight: 6,
              backgroundColor: h.border,
              color: h.text,
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: HSpace.sm),
          Text(
            error,
            key: const Key('voice-streaming-error'),
            style: HTxt.caption.copyWith(
              color: const Color(0xFFDC2626),
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  // -------------------------------------------------- 整段识别（SenseVoice）

  Widget _senseVoiceCard(Hue h) {
    return _card(
      h,
      key: const Key('voice-sensevoice-card'),
      children: [_modelRow(h)],
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
        onTap: () => unawaited(_confirmDelete()),
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

  // ------------------------------------------------------------ 卸载 / 重装

  Future<void> _confirmUninstall() async {
    final ok = await showBwConfirmSheet(
      context,
      title: '卸载语音输入？',
      message: '会删除内置流式模型（约 24 MB）与 SenseVoice（若已下载），'
          '语音输入随即不可用；可随时在本页「重新安装」。',
      confirmLabel: '确认卸载',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final result = await _voice.deleteAllVoiceModels();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _actionNote = result.ok
          ? '已卸载 · 已释放 ${voiceFormatBytes(result.freedBytes)}'
          : '已卸载，但有 ${result.failures.length} 项删除失败：'
              '${result.failures.first}';
    });
  }

  Future<void> _install() async {
    setState(() => _busy = true);
    final result = await _voice.installVoiceModels();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _actionNote = result.ok
          ? '已重新安装 · 流式识别可用'
          : '安装失败：${result.message ?? '未知原因'}';
    });
  }

  Future<void> _retryBundled() async {
    setState(() => _busy = true);
    final result = await _voice.ensureStreamingReady();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _actionNote = result.ok
          ? '内置流式模型已就绪'
          : '准备失败：${result.message ?? '未知原因'}';
    });
  }

  Future<void> _confirmDelete() async {
    final ok = await showBwConfirmSheet(
      context,
      title: '删除语音模型？',
      message: '删除 SenseVoice 后仍可用内置流式识别；需要时可重新下载。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (ok) await _voice.deleteModel();
  }

  Widget _pillButton(
    Hue h, {
    Key? key,
    required String label,
    required bool filled,
    required VoidCallback? onTap,
  }) {
    return Pressable(
      key: key,
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

  /// **模型落盘目录**（T0-1 f，2026-10-31）。
  ///
  /// 用户要能核对"装在哪个目录、卸载会删什么"。`voice_models/` 是 App 私有
  /// 目录：真机路径由控制器给出（`<appFilesDir>/voice_models`），拿不到
  /// profile 时（测试/极早期）退化成相对说明 —— 不编一个假绝对路径。
  Widget _modelsDirRow(Hue h) {
    final root = _modelsRootDir;
    return Container(
      key: const Key('voice-models-dir'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: h.surface,
        borderRadius: BorderRadius.circular(HRadius.md),
        border: Border.all(color: h.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('模型目录',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: h.textDim)),
          const SizedBox(height: 4),
          SelectableText(
            root ?? 'files/voice_models/（App 私有目录）',
            style: TextStyle(
                fontSize: 11.5, height: 1.45, color: h.textFaint),
          ),
          const SizedBox(height: 4),
          Text(
            '该目录下两套模型（内置流式 + SenseVoice）在「卸载语音输入」时一并删除；'
            '卸载 App 也会一并删除。录音不上传。',
            style: TextStyle(fontSize: 11, height: 1.5, color: h.textFaint),
          ),
        ],
      ),
    );
  }

  /// `<appFilesDir>/voice_models` —— 优先用内置流式目录反推（它一定在
  /// `voice_models/` 下），拿不到 profile 时返回 null。
  String? get _modelsRootDir {
    final dir = _voice.bundledStreamingModelDir ??
        _voice.streamingModelDir ??
        _voice.modelDir;
    if (dir == null || dir.isEmpty) return null;
    const marker = '/voice_models';
    final i = dir.indexOf(marker);
    if (i < 0) return dir;
    return dir.substring(0, i + marker.length);
  }

  Widget _groupLabel(Hue h, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(text, style: HTxt.sectionTitle.copyWith(color: h.textDim)),
    );
  }

  Widget _card(Hue h, {Key? key, required List<Widget> children}) {
    return Container(
      key: key,
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
