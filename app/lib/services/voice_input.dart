import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'agent_bridge.dart';
import 'voice_asr.dart';
import 'voice_service.dart';
import 'voice_stream.dart';

/// **麦克风按钮的统一行为**（2026-10-29；同日追加流式语音方案 A）—— 工作模式
/// 与决策模式的麦克风按钮共用这一套：点一次开始录音，再点一次停录，把识别
/// 文本填进输入框光标处。
///
/// ## 两条识别路径（契约 `docs/INTERFACE.md` §N13）
///
/// 1. **流式**（优先）：流式模型已下载 ⇒ `VoiceStreamRunner` 边录边解码，
///    累积草稿经 `AgentBridge.voicePartials` 发给 UI；停止时以最终结果为准。
/// 2. **整段回退**（与今天一致）：流式模型未下载 / 加载失败 / 旧包没有
///    `heracles/voice` 事件流 ⇒ 停录后拿 WAV 走 `VoiceAsr.transcribeWav`，
///    并如实提示"流式不可用，用整段识别"。
///
/// 前置条件在这里一次查清、用人话 toast 回给用户，不让用户对着没反应的
/// 按钮猜：模型没下 → 指去设置页；模型产物没备好 → 触发准备并让稍后再点；
/// 麦克风没授权 → 拉起系统申请、授权后重点一次；录音 60 秒自动停（防忘关
/// 录满缓存 —— 流式路径同样受这条约束）。
enum VoiceInputPhase { idle, recording, recognizing }

class VoiceInputController extends ChangeNotifier {
  VoiceInputController._();

  static final VoiceInputController _shared = VoiceInputController._();
  factory VoiceInputController.shared() => _shared;

  VoiceInputPhase phase = VoiceInputPhase.idle;

  Timer? _maxTimer;

  /// 本次录音的流式泵（null = 这次走整段回退）。
  VoiceStreamRunner? _stream;

  /// 防重入：stop 被 60 秒定时器与用户点击同时触发时只跑一遍。
  bool _stopping = false;

  bool get recording => phase == VoiceInputPhase.recording;
  bool get busy => phase == VoiceInputPhase.recognizing;

  /// 本次/上次录音是否走了流式（诊断与提示用）。
  bool get streamingActive => _stream != null;

  /// 测试注入：替换真实 sherpa 解码器（生产 null = 用 isolate + OnlineRecognizer）。
  /// 测试里注入"必失败/假"解码器，避免在 flutter_tester 里起真 isolate。
  @visibleForTesting
  static VoiceStreamDecoder? Function(VoiceModelController voice)?
      decoderFactoryForTest;

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
    // 真卸载时由本控制器释放当前流式 session（注册到 engineReleaseHooks）。
    VoiceModelController.registerEngineRelease(_releaseStreamingEngine);
    // ★ T0-2 真卸载闸门：用户卸载过 ⇒ 明确人话提示，**不录音、不解压、不转写**。
    if (voice.voiceUninstalled || !voice.voiceEnabled) {
      toast('语音模型已卸载：设置 → 语音识别 里可重新安装');
      return;
    }
    // ★ 每次点麦克风都重新看一次磁盘：模型可能在设置页刚下完、或某处被
    // 删除/改名（§N13.4 的回退判定必须即时，不能吃启动时的缓存）。只做
    // 几个 `File.existsSync/lengthSync`，主 isolate 开销可忽略。
    voice.refreshInstalled();
    // ★ B1（2026-10-30）：内置 14M 中文流式模型**开箱即用** —— 第一次点
    // 麦克风时幂等解压（≈24MB，断网也可用，普通用户无需下载任何东西）。
    // ★ 即使设备上还留着"可选下载的 200MB 双语模型"，也优先把**内置模型**
    // 备好（默认用内置；老模型只有在用户明确需要高精度时才被 `activeStreamingModel`
    // 在 bundled 不可用时选中）。解压失败不崩，照旧走整段回退。
    if (!voice.bundledStreamingReady) {
      final ensured = await voice.ensureStreamingReady();
      // 双保险：解压期间用户可能刚好点了卸载。
      if (ensured.uninstalled) {
        toast('语音模型已卸载：设置 → 语音识别 里可重新安装');
        return;
      }
    }
    // 两条路径的模型门槛分开算（§N13.4）：
    // · 流式：内置解压完成（或可选下载完整）即可录（边说边出字）；
    // · 整段回退：需要 SenseVoice 的引擎产物（补完 metadata + 词表）。
    // 流式可用 ⇒ 不为整段路径的准备状态挡路；整段只作后台兜底。
    final streamingReady = voice.streamingInstalled;
    final wholeReady = voice.installed && voice.engineReady;
    if (!streamingReady && !wholeReady) {
      if (!voice.installed) {
        toast('先下载语音模型：设置 → 语音识别');
        return;
      }
      if (voice.prepareError != null) {
        toast(voice.prepareError!);
      } else {
        if (!voice.preparing) unawaited(voice.prepareEngine());
        toast('语音模型正在准备，稍候再点麦克风');
      }
      return;
    }
    // 流式可用但整段模型也在 ⇒ 后台把回退路径备好（不挡本次录音）。
    if (streamingReady && voice.installed && !voice.engineReady && !voice.preparing) {
      unawaited(voice.prepareEngine());
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

    // 流式：模型已下载 + 宿主回了 sessionId 才尝试；任何一步不满足都回退。
    final streamed = await _startStreaming(bridge, started, target, toast);
    toast(
      streamed
          ? '录音中，再点一次麦克风结束'
          : '录音中（流式不可用，用整段识别），再点一次麦克风结束',
    );
    _maxTimer?.cancel();
    _maxTimer = Timer(const Duration(seconds: 60), () {
      if (phase == VoiceInputPhase.recording) {
        unawaited(_stopAndTranscribe(target, toast));
      }
    });
  }

  /// 尝试开启流式识别；返回 false = 本次走整段回退（不报错）。
  Future<bool> _startStreaming(
    AgentBridge bridge,
    Map<String, dynamic> started,
    TextEditingController target,
    void Function(String message) toast,
  ) async {
    final voice = VoiceModelController.shared();
    // 流式模型仍不可用（内置解压失败且没下载过）⇒ 不报错，回退整段（§N13.4）。
    if (!voice.streamingInstalled) return false;
    final sessionId = (started['sessionId'] as String?) ?? '';
    // 旧包 start 不回 sessionId：拿不到会话就只能整段识别。
    if (sessionId.isEmpty) return false;
    final decoder =
        decoderFactoryForTest?.call(voice) ?? createSherpaStreamDecoder(voice);
    if (decoder == null) return false;
    final runner = VoiceStreamRunner(
      sessionId: sessionId,
      decoder: decoder,
      events: bridge.voiceAudioEvents(),
      emitPartial: (partial) {
        // 诊断用（debug 构建）：**只记长度/序号/是否定稿，不记识别正文**
        // —— 语音内容属用户隐私，release 不打印（kDebugMode 为常量折叠）。
        if (kDebugMode) {
          debugPrint(
            '[voice] partial seq=${partial.seq} final=${partial.isFinal} '
            'chars=${partial.text.length}',
          );
        }
        AgentBridge.emitVoicePartial(partial);
      },
      onTimeout: () {
        // 60 秒上限：与旧路径同一个停录入口（幂等）。
        unawaited(_stopAndTranscribe(target, toast));
      },
      onUnavailable: (reason) {
        // 旧包/通道报错：如实提示一次，停录时自然走整段识别。
        toast('流式不可用，用整段识别');
      },
    );
    try {
      await runner.start();
    } catch (_) {
      await runner.dispose();
      toast('流式不可用，用整段识别');
      return false;
    }
    // 加载期间已经判不可用（事件通道立刻报错）⇒ 也不接管本次录音。
    if (runner.unavailable) {
      await runner.dispose();
      return false;
    }
    _stream = runner;
    return true;
  }

  Future<void> _stopAndTranscribe(
    TextEditingController target,
    void Function(String message) toast,
  ) async {
    if (_stopping || phase != VoiceInputPhase.recording) return;
    _stopping = true;
    _maxTimer?.cancel();
    _maxTimer = null;
    phase = VoiceInputPhase.recognizing;
    notifyListeners();
    final runner = _stream;
    _stream = null;
    var wavPath = '';
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
      wavPath = (stopped['path'] as String?) ?? '';
      final useStream = runner != null && !runner.unavailable;
      if (useStream) {
        // 等解码器把尾音解完（内部有兜底超时，不会卡住 UI）。
        final finalText = (await runner.stop()).trim();
        if (finalText.isEmpty) {
          toast('没听清，请再试一次');
        } else if (!AgentBridge.hasVoicePartialListener) {
          // 前端还没接草稿展示 ⇒ 代填，保证"点麦克风就能出字"不回归。
          // 前端接上 `AgentBridge.voicePartials` 后自动不再代填（避免双写）。
          insertTextAtCursor(target, finalText);
        }
      } else {
        // 回退：与今天完全一致的整段识别。
        if (runner != null) await runner.dispose();
        final voice = VoiceModelController.shared();
        // T0-2：卸载后即使残留 WAV 也绝不转写（VoiceAsr 里还有一道硬闸）。
        if (voice.voiceUninstalled || !voice.voiceEnabled) {
          toast('语音模型已卸载：设置 → 语音识别 里可重新安装');
          return;
        }
        if (!voice.installed || !voice.engineReady) {
          toast('流式不可用，且整段识别模型未准备');
          return;
        }
        if (wavPath.isEmpty) {
          toast('录音失败：没拿到录音文件');
          return;
        }
        final text = await VoiceAsr.transcribeWav(wavPath);
        if (text.isEmpty) {
          toast('没听清，请再试一次');
        } else {
          insertTextAtCursor(target, text);
        }
      }
    } catch (e) {
      toast('识别失败：$e');
    } finally {
      _stopping = false;
      if (wavPath.isNotEmpty) {
        unawaited(File(wavPath).delete().catchError((_) => File(wavPath)));
      }
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
    final runner = _stream;
    _stream = null;
    // 先断流（取消后立即停发 partial），再让宿主丢录音文件。
    if (runner != null) await runner.cancel();
    await AgentBridge().cancelVoiceRecord();
  }

  /// 真卸载时释放流式引擎/解码器（注册进
  /// [VoiceModelController.engineReleaseHooks]，删除模型时被调用）。
  static void _releaseStreamingEngine() {
    final controller = VoiceInputController._shared;
    final runner = controller._stream;
    controller._stream = null;
    if (runner != null) unawaited(runner.cancel());
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
