import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'agent_bridge.dart';
import 'voice_asr.dart';
import 'voice_service.dart';

/// **麦克风按钮的统一行为**（2026-10-29）—— 工作模式与决策
/// 模式的麦克风按钮共用这一套：点一次开始录音，再点一次停录
/// 并离线识别、把文本填进输入框光标处。
///
/// 前置条件在这里一次查清、用人话 toast 回给用户，不让用户
/// 对着没反应的按钮猜：模型没下 → 指去设置页；模型产物没备好
/// → 触发准备并让稍后再点；麦克风没授权 → 拉起系统申请、
/// 授权后重点一次；录音 60 秒自动停（防忘关录满缓存）。
enum VoiceInputPhase { idle, recording, recognizing }

class VoiceInputController extends ChangeNotifier {
  VoiceInputController._();

  static final VoiceInputController _shared = VoiceInputController._();
  factory VoiceInputController.shared() => _shared;

  VoiceInputPhase phase = VoiceInputPhase.idle;

  Timer? _maxTimer;

  bool get recording => phase == VoiceInputPhase.recording;
  bool get busy => phase == VoiceInputPhase.recognizing;

  /// 麦克风按钮点按入口。[target] 是要点完往里填字的输入框，
  /// [toast] 是调用方的轻提示出口（各页自己的 showIosToast）。
  Future<void> onMicTap({
    required TextEditingController target,
    required void Function(String message) toast,
  }) async {
    if (phase == VoiceInputPhase.recognizing) return;
    if (phase == VoiceInputPhase.recording) {
      await _stopAndTranscribe(target, toast);
      return;
    }

    final voice = VoiceModelController.shared();
    if (!voice.loaded) await voice.load();
    if (!voice.installed) {
      toast('先下载语音模型：设置 → 语音识别');
      return;
    }
    if (!voice.engineReady) {
      if (voice.prepareError != null) {
        toast(voice.prepareError!);
      } else {
        if (!voice.preparing) unawaited(voice.prepareEngine());
        toast('语音模型正在准备，稍候再点麦克风');
      }
      return;
    }

    final bridge = AgentBridge();
    final perms = await bridge.devicePermissions();
    if (perms['microphone'] != 'granted') {
      await bridge.requestPermission('microphone');
      toast('请先允许麦克风权限，再点一次麦克风');
      return;
    }

    final started = await bridge.startVoiceRecord();
    if (started == null) {
      toast('录音不可用：宿主未实现录音桥');
      return;
    }
    if (started['ok'] == false) {
      toast('录音失败：${started['error'] ?? '未知原因'}');
      return;
    }
    phase = VoiceInputPhase.recording;
    notifyListeners();
    toast('录音中，再点一次麦克风结束');
    _maxTimer?.cancel();
    _maxTimer = Timer(const Duration(seconds: 60), () {
      if (phase == VoiceInputPhase.recording) {
        unawaited(_stopAndTranscribe(target, toast));
      }
    });
  }

  Future<void> _stopAndTranscribe(
    TextEditingController target,
    void Function(String message) toast,
  ) async {
    _maxTimer?.cancel();
    _maxTimer = null;
    phase = VoiceInputPhase.recognizing;
    notifyListeners();
    try {
      final stopped = await AgentBridge().stopVoiceRecord();
      if (stopped == null) {
        toast('录音不可用：宿主未实现录音桥');
        return;
      }
      if (stopped['ok'] == false) {
        toast('${stopped['error'] ?? '录音失败'}');
        return;
      }
      final path = (stopped['path'] as String?) ?? '';
      if (path.isEmpty) {
        toast('录音失败：没拿到录音文件');
        return;
      }
      try {
        final text = await VoiceAsr.transcribeWav(path);
        if (text.isEmpty) {
          toast('没听清，请再试一次');
        } else {
          insertTextAtCursor(target, text);
        }
      } finally {
        unawaited(File(path).delete().catchError((_) => File(path)));
      }
    } catch (e) {
      toast('识别失败：$e');
    } finally {
      phase = VoiceInputPhase.idle;
      notifyListeners();
    }
  }

  /// 放弃当前录音（页面销毁等场景兜底，不识别不填字）。
  Future<void> cancelIfRecording() async {
    if (phase != VoiceInputPhase.recording) return;
    _maxTimer?.cancel();
    _maxTimer = null;
    phase = VoiceInputPhase.idle;
    notifyListeners();
    await AgentBridge().cancelVoiceRecord();
  }
}

/// 把 [text] 填进输入框当前选区（无选区时填到末尾），
/// 光标落在填入文本之后 —— 语音输入与手动打字可无缝接续。
void insertTextAtCursor(TextEditingController controller, String text) {
  final base = controller.text;
  final sel = controller.selection;
  final start = sel.start >= 0 ? sel.start : base.length;
  final end = sel.end >= 0 ? sel.end : base.length;
  final next = base.replaceRange(start, end, text);
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}
