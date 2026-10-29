/// **语音流式草稿的纯逻辑层（阶段 1）**（task-6，2026-10-29）。
///
/// 背景（第 8 条）：语音识别边识别边往输入框里写字 —— 录音期间输入框全文
/// 应为
///
///     全文 = 原文[0..anchor] + 草稿 + 原文[anchor..]
///
/// 每次 ASR 回一段**累积全文**（不是增量）时，只替换「草稿」这一段：
/// 用户原来的前缀/后缀**一字不动**、光标不被拽走。停止录音后 final 变成
/// 正式文本（草稿样式消失），光标落在插入段末尾。
///
/// ★ 本文件阶段 1 只做逻辑层（不碰 input_bar / chat_screen）：
/// 阶段 2 才把它接到输入框（录音态、「识别中」轻量状态、草稿下划线样式、
/// 无流式能力时回退「录完再识别」）。
///
/// ★ B5 的流式通道**尚未交付**：这里只定义 UI 侧占位模型 [VoicePartial]，
/// 不接 AgentBridge、不假造 partial。真实接入点见任务移交说明：
/// `AgentBridge.startVoiceStream()` / `VoicePartial{sessionId, text, isFinal}`
/// 200–300ms 回累积全文、停止时发 final。
library;

import 'package:flutter/services.dart';

/// **一段累积的部分识别结果**（UI 侧占位模型，等 B5 落地后由
/// AgentBridge 事件生产）。
///
/// · [sessionId]：一次录音会话的标识 —— 迟到的旧会话 partial 必须丢弃；
/// · [text]：**累积全文**（不是增量），平台/引擎每 200–300ms 回一次；
/// · [isFinal]：停止录音后的最后一次结果（之后不再有 partial）。
class VoicePartial {
  const VoicePartial({
    required this.sessionId,
    required this.text,
    this.isFinal = false,
  });

  final String sessionId;

  /// 本次识别到目前为止的**累积全文**。
  final String text;

  /// 是否是结束时的最终结果。
  final bool isFinal;

  @override
  bool operator ==(Object other) =>
      other is VoicePartial &&
      other.sessionId == sessionId &&
      other.text == text &&
      other.isFinal == isFinal;

  @override
  int get hashCode => Object.hash(sessionId, text, isFinal);

  @override
  String toString() =>
      'VoicePartial(session: $sessionId, final: $isFinal, text: "$text")';
}

/// 流式草稿的纯逻辑控制器（无 Widget 依赖，可纯单测；阶段 2 由
/// input_bar / chat_screen 驱动）。
///
/// 生命周期：
/// ```
/// final d = VoiceDraft();
/// controller.value = d.start(controller.text, controller.selection.baseOffset);
/// // …ASR 每来一段累积全文：
/// controller.value = d.applyPartial(cumulative);
/// // 停止录音：
/// controller.value = d.commitFinal(finalText);   // 草稿转正式文本
/// // 用户中途取消：
/// controller.value = d.cancel();                 // 恢复原文与起始选区
/// // 用户中途手打：
/// controller.value = d.applyUserEdit(controller.value);
/// ```
///
/// 不变量：
/// · 录音中 [text] 恒为 `原文[0..anchor] + draft + 原文[anchor..]`，
///   每次只替换 draft 段，前缀/后缀逐字不动（不 trim、不重编码）；
/// · [applyPartial] 返回的选区不把光标拽到末尾：草稿段之前不动、
///   之后随长度差平移、之内随长度差调整；
/// · 提交/取消/手打之后 [active] 为 false，迟到的 partial 一律丢弃
///   （不覆盖用户内容、不二次插入）。
class VoiceDraft {
  /// 原文（录音开始前的全文；提交后为提交后的正式文本）。
  String _base = '';

  /// 插入锚点（草稿插在这里）。
  int _anchor = 0;

  /// 当前草稿段（ASR 累积全文）。
  String _draft = '';

  /// 起始选区（取消时恢复）。
  TextSelection _initialSelection = const TextSelection.collapsed(offset: 0);

  /// 最近一次建议的选区（下次 applyPartial 按它算光标）。
  TextSelection _selection = const TextSelection.collapsed(offset: 0);

  bool _active = false;

  /// 是否支持流式（不支持时 partial 不生效，走「录完再识别」）。
  bool _streaming = true;

  /// 本次录音会话 id（用于丢弃其它会话的迟到事件）。
  String? _sessionId;

  /// 是否还在录音/识别中。
  bool get active => _active;

  /// 当前是否具备流式能力（false = 只接受 final，不假造 partial）。
  bool get streaming => _streaming;

  /// 原文（录音开始前的全文；提交后为提交后的正式文本）。
  String get originalText => _base;

  /// 插入锚点。
  int get anchor => _anchor;

  /// 当前草稿段。
  String get draft => _draft;

  /// 当前会话 id（未开始为 null）。
  String? get sessionId => _sessionId;

  /// 当前合成全文：录音中 = 原文[0..anchor] + 草稿 + 原文[anchor..]。
  String get text {
    if (!_active) return _base;
    return '${_prefix()}$_draft${_suffix()}';
  }

  /// 最近一次建议的选区。
  TextSelection get selection => _selection;

  /// 开始一次录音草稿，返回开始时的 [TextEditingValue]（不会移动光标）。
  ///
  /// [anchor] 会被 clamp 到 `[0, originalText.length]`；[selection] 缺省为
  /// 锚点处的折叠选区（取消时恢复到它）。[sessionId] 用于过滤其它会话的
  /// 迟到事件；[streaming] = false 表示本次只能「录完再识别」。
  TextEditingValue start(
    String originalText,
    int anchor, {
    TextSelection? selection,
    String? sessionId,
    bool streaming = true,
  }) {
    _base = originalText;
    _anchor = anchor.clamp(0, originalText.length);
    _draft = '';
    _active = true;
    _streaming = streaming;
    _sessionId = sessionId;
    _initialSelection = selection != null && selection.isValid
        ? _clampSelection(selection, originalText.length)
        : TextSelection.collapsed(offset: _anchor);
    _selection = _initialSelection;
    return TextEditingValue(text: _base, selection: _selection);
  }

  /// 应用一段**累积全文**的 partial，返回输入框应呈现的 value。
  ///
  /// 只替换草稿段；[selection] 是应用前输入框里的选区（缺省用上次建议值）。
  TextEditingValue applyPartial(
    String cumulative, {
    TextSelection? selection,
  }) {
    if (!_active) {
      // 提交/取消/手打之后的迟到 partial：丢弃，不覆盖用户内容。
      return TextEditingValue(text: _base, selection: _selection);
    }
    final current = _base;
    final caretBefore = selection != null && selection.isValid
        ? _clampSelection(selection, text.length)
        : _selection;
    if (!_streaming) {
      // 无流式能力：如实降级 —— 不写草稿、不假造 partial，光标原样保留。
      _selection = caretBefore;
      return TextEditingValue(text: current, selection: _selection);
    }
    final oldLen = _draft.length;
    _draft = cumulative;
    final newLen = cumulative.length;
    _selection = _mapSelection(caretBefore, oldLen, newLen);
    return TextEditingValue(text: text, selection: _selection);
  }

  /// 应用一次 [VoicePartial] 事件：final 走 [commitFinal]，其余走
  /// [applyPartial]；非本次活动会话的事件直接丢弃（不串台）。
  TextEditingValue applyEvent(VoicePartial partial) {
    if (!_active) {
      return TextEditingValue(text: _base, selection: _selection);
    }
    final session = _sessionId;
    if (session != null && partial.sessionId != session) {
      return TextEditingValue(text: text, selection: _selection);
    }
    return partial.isFinal ? commitFinal(partial.text) : applyPartial(partial.text);
  }

  /// 停止录音：把 final 文本写成正式文本（草稿样式消失），
  /// 光标落在**插入段末尾**。
  TextEditingValue commitFinal(String text) {
    if (!_active) {
      // 已提交过（或已取消/手打）：幂等，不二次插入。
      return TextEditingValue(text: _base, selection: _selection);
    }
    final composed = '${_prefix()}$text${_suffix()}';
    _base = composed;
    _draft = '';
    _active = false;
    _selection = TextSelection.collapsed(offset: _anchor + text.length);
    return TextEditingValue(text: _base, selection: _selection);
  }

  /// 取消录音：恢复原文与**起始选区**（不保留识别出的草稿）。
  TextEditingValue cancel() {
    if (!_active) {
      return TextEditingValue(text: _base, selection: _selection);
    }
    _draft = '';
    _active = false;
    _selection = _initialSelection;
    return TextEditingValue(text: _base, selection: _selection);
  }

  /// 录音中用户手打：先把当前草稿「提交」为正式文本，再让用户编辑 ——
  /// 之后迟到的 partial 不得覆盖用户输入（[active] 已为 false）。
  ///
  /// [value] 是输入框当前（或用户编辑后）的值；它成为新的权威文本。
  TextEditingValue applyUserEdit(TextEditingValue value) {
    if (!_active) return value;
    _base = value.text;
    _draft = '';
    _active = false;
    _selection = value.selection.isValid
        ? _clampSelection(value.selection, value.text.length)
        : TextSelection.collapsed(offset: value.text.length);
    _initialSelection = _selection;
    return TextEditingValue(text: _base, selection: _selection);
  }

  // ------------------------------------------------------------------ 内部

  String _prefix() => _base.substring(0, _anchor);
  String _suffix() => _base.substring(_anchor);

  /// 把应用前的一个 offset 映射到「替换草稿段后」的位置：
  /// · 草稿段之前（`<= anchor`）：不动；
  /// · 草稿段之后（`>= anchor + oldLen`）：随长度差平移（不回锚点）；
  /// · 在草稿段内：随长度差调整，并夹在草稿段 `[anchor, anchor+newLen]` 内。
  int _mapOffset(int offset, int oldLen, int newLen) {
    if (offset <= _anchor) return offset;
    final draftEnd = _anchor + oldLen;
    if (offset >= draftEnd) return offset + (newLen - oldLen);
    final shifted = offset + (newLen - oldLen);
    return shifted.clamp(_anchor, _anchor + newLen);
  }

  TextSelection _mapSelection(TextSelection sel, int oldLen, int newLen) =>
      TextSelection(
        baseOffset: _mapOffset(sel.baseOffset, oldLen, newLen),
        extentOffset: _mapOffset(sel.extentOffset, oldLen, newLen),
        affinity: sel.affinity,
      );

  TextSelection _clampSelection(TextSelection sel, int maxOffset) =>
      TextSelection(
        baseOffset: sel.baseOffset.clamp(0, maxOffset),
        extentOffset: sel.extentOffset.clamp(0, maxOffset),
        affinity: sel.affinity,
      );
}
