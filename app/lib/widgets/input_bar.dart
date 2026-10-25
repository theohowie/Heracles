import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/attachment.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import 'bw_approval.dart';
import 'bw_model_sheet.dart';

/// 底部输入区 —— 固定，始终可见。
///
/// 设计意图（ADR-014）：输入区是唯一"常驻交互"，不随消息流滚动。
///
/// ## 附件
///
/// 左侧 `+` 按钮添加文件/照片。附件以 chip 形式显示在输入框上方，
/// 发送时随请求一起带给 LLM。
///
/// ## 输入框上方那一行开关（2026-10-12，S4）
///
/// ```
/// [+]  ⚠ 完全权限 ▾          Auto ▾
///      ↑ 权限开关              ↑ 推理等级（新增）
/// ```
class InputBar extends StatefulWidget {
  const InputBar({
    super.key,
    required this.onSend,
    this.onPickAttachment,
    this.onRemoveAttachment,
    this.attachments = const [],
    this.enabled = true,
    this.busy = false,
    this.stopLabel = true,
    this.permission = PermissionMode.workspaceAuto,
    this.onPermissionChanged,
    this.providerLabel,
    this.providers = const [],
    this.activeProviderId,
    this.onProviderSelected,
    this.onOpenModelCatalog,
    this.onModelTap,
    this.onStop,
    this.inputController,
    this.queuedTexts = const [],
    this.onQueuedSendNow,
    this.onQueuedRemove,
    this.onQueuedPin,
    this.reasoningLevel = ReasoningLevel.auto,
    this.onReasoningLevelChanged,
    this.maxTurns = 0,
    this.onMaxTurnsChanged,
  });

  final void Function(String text) onSend;

  /// 点 `+` —— 由上层弹选择器（相册 / 文件）
  final VoidCallback? onPickAttachment;

  final void Function(String attachmentId)? onRemoveAttachment;

  /// 已选附件
  final List<HAttachment> attachments;

  final bool enabled;

  /// 正在跑 —— 显示停止按钮
  final bool busy;

  /// 按钮是否显示**停止**语义（2026-10-11 t14）。
  ///
  /// ## 为什么要区分
  ///
  /// 只有**当前会话**在跑时，"停止"才有意义。
  /// 若在会话 B 显示停止按钮（实际跑的是会话 A），用户会以为
  /// "能停 B 的东西"或"B 卡住了" —— 那是误导。
  ///
  /// 所以别的会话在跑时按钮显示**等待**语义（沙漏），
  /// 并配一条说明横幅（`_RunningBanner`）。
  final bool stopLabel;

  // ---- 上方那一行开关（2026-10-12，S4）----

  /// 当前权限档位（`PermissionMode`）
  final PermissionMode permission;

  /// 用户改了权限 —— null 表示这一行只读展示（测试/预览时用）
  final ValueChanged<PermissionMode>? onPermissionChanged;

  /// 当前推理等级
  final ReasoningLevel reasoningLevel;

  /// 用户改了推理等级
  final ValueChanged<ReasoningLevel>? onReasoningLevelChanged;

  /// **单次任务最大轮次**（2026-10-18，`docs/27` P0-1 / ADR-033）。
  ///
  /// `0` = 自动跟随当前后端（本地 8 / 云端 40）。
  final int maxTurns;

  /// 用户改了最大轮次 —— null 表示这一块只读展示（测试/预览时用）。
  final ValueChanged<int>? onMaxTurnsChanged;

  // ---- 模型选择框（2026-10-12，仿 llama.cpp Web UI）----

  /// 当前 provider 的展示名（如「本地模型 (llama.cpp)」→ 取短名）
  final String? providerLabel;

  /// 全部 provider（弹层列出）
  final List<ModelProviderConfig> providers;

  /// 当前选中的 provider id
  final String? activeProviderId;

  /// 用户选中某个 provider
  final ValueChanged<String>? onProviderSelected;

  /// **点进中转站的模型目录**（2026-10-14，两层菜单结构）：
  /// 第一层里点配了目录的厂商 → 触发本回调 → 打开第二层（厂商的模型列表）
  /// → 点模型即切换成功。
  final ValueChanged<String>? onOpenModelCatalog;

  /// 点击模型框里「模型 ›」行 —— 跳设置页管理/新增
  final VoidCallback? onModelTap;

  /// **停止当前运行**（2026-10-13）—— 只在"当前会话在跑"时被点击。
  ///
  /// 与 `onSend` 分开：原来是同一个 `_send`，导致停止图标点下去
  /// 反而是再发一条（用户报的「暂停不了」）。
  final VoidCallback? onStop;

  /// **外部输入控制器**（2026-10-13，「编辑重发」用）——
  ///
  /// 长按用户消息 → 编辑 → 上层把原文写进这个控制器。
  /// 传了就用外部的（上层能读写输入框文本）；不传就内部自建
  /// （既有调用方零改动）。
  final TextEditingController? inputController;

  // ---- ★ 排队待发（2026-10-13，用户参考图）----
  //
  // 排队内容显示在**输入框上方**的一条圆角栏里，每行：
  //   💬 文本            ⧉(置顶) 🗑(删除) ↑(立即发送)
  // 用户原话：「排队的消息要在输入框上面显示……
  //           不是在工作步骤里显示已排队」。

  /// 排队中消息的文本（按顺序，第一行最先发出）
  final List<String> queuedTexts;

  /// 立即发送某条（参考图的 ↑）—— 会打断当前运行
  final ValueChanged<int>? onQueuedSendNow;

  /// 删除某条（参考图的 🗑）
  final ValueChanged<int>? onQueuedRemove;

  /// 置顶某条（参考图的 ⧉）—— 当前运行结束后它先发，**不**打断
  final ValueChanged<int>? onQueuedPin;

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  /// 内部自建的控制器 —— 仅当上层**没有**传 [InputBar.inputController]
  /// 时才创建/销毁（外部控制器由上层持有，dispose 归上层管）
  TextEditingController? _ownController;
  late final TextEditingController _controller =
      widget.inputController ?? (_ownController = TextEditingController());
  final _focus = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _ownController?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    // 允许「只发附件不发文字」
    if ((text.isEmpty && widget.attachments.isEmpty) || !widget.enabled) return;
    widget.onSend(text);
    _controller.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    // ★ 悬浮容器（2026-10-12，用户强调"悬浮悬浮悬浮"）：
    //   · **去掉顶部分隔线**（参考图输入框上方没有线 —— 那根线让容器
    //     看起来"焊死"在底部）
    //   · 底色透明（不自己垫一块底）—— 容器圆角+阴影浮在页面背景上
    //   · 容器四周留边距 —— 与参考图一致（离屏幕左右下都有距离）
    return Container(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---- ★ 排队待发栏（2026-10-13，用户参考图）----
            //
            // 位置：**输入框正上方**。用户原话：
            // 「排队的消息要在输入框上面显示……不是在工作步骤里显示已排队」。
            //
            // 每行：💬 文本  +  右侧三个动作（置顶 / 删除 / 立即发送）
            // 视觉与输入容器同宽同圆角，看起来是"输入区的一部分"。
            for (var i = 0; i < widget.queuedTexts.length; i++)
              _QueuedRow(
                h: h,
                text: widget.queuedTexts[i],
                onSendNow:
                    widget.onQueuedSendNow == null ? null : () => widget.onQueuedSendNow!(i),
                onRemove:
                    widget.onQueuedRemove == null ? null : () => widget.onQueuedRemove!(i),
                onPin: widget.onQueuedPin == null ? null : () => widget.onQueuedPin!(i),
                // 只有队首那条有"置顶"的意义（已在最前就不显示）
                canPin: i > 0,
              ),

            // ---- 附件 chip 行 ----
            if (widget.attachments.isNotEmpty)
              _AttachmentRow(
                attachments: widget.attachments,
                h: h,
                onRemove: widget.onRemoveAttachment,
              ),

            // ---- ★ 悬浮大容器输入框（2026-10-12，仿 llama.cpp Web UI）----
            //
            //   ╭──────────────────────────────────╮
            //   │ 描述你要做什么…                    │
            //   │ (+)  🛡  [模型 ▾]          (↑)   │
            //   ╰──────────────────────────────────╯
            // 悬浮感三要素（用户："悬浮悬浮悬浮"）：
            //   · 四周留边距（离屏幕左右下各有一段距离）
            //   · 容器自带投影（浮在页面背景之上）
            //   · 无顶部焊线（旧版的 Border(top) 已去掉）
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HSpace.md, HSpace.sm + 2, HSpace.md, HSpace.md,
              ),
              child: Container(
                // ★ 不设 maxHeight —— 多行文本由 Flexible+内部滚动约束，
                //   设上限反而会 BOTTOM OVERFLOWED（实测 144px 黄条：
                //   maxLines:null 的 TextField 无限长，ConstrainedBox
                //   只约束不裁剪）
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(HRadius.xl),
                  border: Border.all(color: h.border),
                  boxShadow: [
                    // 悬浮投影 —— 与模型胶囊同款，让容器从背景上浮起
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: h.dark ? 0.30 : 0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ---- 文本区（容器上半部）----
                    // ★ ConstrainedBox maxHeight 130（2026-10-12 修溢出）：
                    //   maxLines:null 的 TextField 会随内容无限长 ——
                    //   长文本直接撑破容器（实测 BOTTOM OVERFLOWED 144px）。
                    //   限高后多行**内部滚动**，容器高度封顶。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 130),
                      // ★ borderless：外层容器已有胶囊圆角+边框（iOS Messages 输入条），
                      //   文本区不再套第二层装饰。Material 的 border:InputBorder.none /
                      //   isDense 在这里没有对应参数 —— 内边距由 padding 承担。
                      child: CupertinoTextField.borderless(
                        controller: _controller,
                        focusNode: _focus,
                        enabled: widget.enabled,
                        maxLines: null,
                        minLines: 1,
                        // ★ 保持 send（2026-10-12 回归修复）：改成 newline 会让
                        //   键盘回车不再发送 —— 真机习惯与全部测试都基于
                        //   「回车=发送」。容器形态变了，交互语义不能变。
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.45,
                          color: h.text,
                        ),
                        // 空态占位（2026-10-12，用户指定）——
                        // 与 llama.cpp Web UI 的 "Type a message..." 同位。
                        // ★ 有排队时的占位（2026-10-13 参考图）：
                        //   此时输入新内容 + 点发送 = 再排一条（追加队尾）；
                        //   想插队用排队条上的 ↑（打断当前）。
                        //   ⚠️ 措辞按用户反馈修正（"发送消息时引导不是截断"）：
                        //   原文案"继续输入排队"没说清"发送 = 排队"。
                        // 2026-10-25：空态文案改原型 01 的「给 Heracles
                        // 发消息…」（2026-10-12 的长文案被原型定稿覆盖）；
                        // 排队态保留功能说明（说清发送 = 排队）。
                        placeholder: widget.queuedTexts.isEmpty
                            ? '给 Heracles 发消息…'
                            : '发送将排在队尾；↑ 可插队立即发送',
                        placeholderStyle:
                            TextStyle(color: h.textFaint, fontSize: 15),
                        // 容器已有圆角与边框 —— 文本区只留内边距
                        padding: const EdgeInsets.fromLTRB(
                          HSpace.lg, HSpace.md, HSpace.lg, HSpace.sm,
                        ),
                      ),
                    ), // ConstrainedBox
                    // ---- 底部一行（2026-10-12，按用户参考图重排）----
                    //
                    //  (＋)      🛡  [模型 ▾]        (↑ 最右)
                    //   ↑圆       ↑图标  ↑阴影胶囊     ↑贴容器右缘
                    //
                    // · + 与发送键是**圆形**（参考图明确）
                    // · 发送键无内容时**置灰不可点**（ChoiceChip 同款）
                    // · 发送键在**容器最右**、垂直居中于底行
                    // · 模型框紧贴发送键左侧（中间不留大空隙 —— 参考图
                    //   里两者是一组，靠右放置）
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HSpace.sm + 2, 0, HSpace.sm + 4, HSpace.sm + 2,
                      ),
                      child: Row(
                        children: [
                          // ---- ＋（圆形）----
                          _CircleButton(
                            icon: AppIcons.add,
                            h: h,
                            onTap:
                                widget.enabled ? widget.onPickAttachment : null,
                          ),
                          const SizedBox(width: HSpace.md),

                          // ---- 权限（只显示图标，点击弹选择框）----
                          _PermissionIconButton(
                            permission: widget.permission,
                            h: h,
                            enabled: widget.enabled,
                            onPicked: widget.onPermissionChanged,
                          ),
                          const Spacer(),

                          // ---- 模型选择框（带阴影的胶囊，紧贴发送键）----
                          _ModelSelector(
                            label: widget.providerLabel,
                            reasoningLevel: widget.reasoningLevel,
                            h: h,
                            onTap: widget.onModelTap,
                            onReasoningLevelChanged:
                                widget.onReasoningLevelChanged,
                            // ★ 最大轮次（2026-10-18，ADR-033）——
                            //   与推理等级同一弹层，避免又多一个入口
                            maxTurns: widget.maxTurns,
                            onMaxTurnsChanged: widget.onMaxTurnsChanged,
                            providers: widget.providers,
                            activeProviderId: widget.activeProviderId,
                            onProviderSelected: widget.onProviderSelected,
                            // ★ 两层菜单：点中转站 → 进它的模型目录
                            onOpenModelCatalog: widget.onOpenModelCatalog,
                          ),
                          const SizedBox(width: HSpace.sm),

                          // ---- 发送/停止（圆形，容器最右）----
                          //
                          // ★ 点击行为**与图标一致**（2026-10-13，两次迭代）：
                          //   · 空闲 → 发送
                          //   · 忙 + **无内容** → 停止（当前会话）—— 用户要停
                          //   · 忙 + **有内容** → 发送/排队 —— 用户在排下一条
                          //     （用户原话："输入框里有字的时候，
                          //       暂停按钮变成发送按钮"）
                          //
                          // 视觉与行为必须同步：图标是发送，点下去就是发送。
                          _SendButton(
                            enabled: (_hasText ||
                                    widget.attachments.isNotEmpty) &&
                                widget.enabled,
                            busy: widget.busy,
                            stopLabel: widget.stopLabel,
                            hasContent: _hasText ||
                                widget.attachments.isNotEmpty,
                            h: h,
                            onTap: (widget.busy &&
                                    !_hasText &&
                                    widget.attachments.isEmpty)
                                ? (widget.onStop ?? _send)
                                : _send,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件 chip 行 —— 横向滚动，避免多个附件挤压输入框
class _AttachmentRow extends StatelessWidget {  const _AttachmentRow({
    required this.attachments,
    required this.h,
    this.onRemove,
  });

  final List<HAttachment> attachments;
  final Hue h;
  final void Function(String id)? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: HSpace.sm),
        itemBuilder: (_, i) {
          final a = attachments[i];
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.only(left: HSpace.sm, right: 2),
            decoration: BoxDecoration(
              color: h.surface,
              borderRadius: BorderRadius.circular(HRadius.sm),
              border: Border.all(color: h.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  a.isImage ? AppIcons.image : AppIcons.file,
                  size: 15,
                  color: h.accent,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: h.textDim),
                  ),
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: onRemove == null ? null : () => onRemove!(a.id),
                  borderRadius: BorderRadius.circular(HRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(AppIcons.close,
                        size: 14, color: h.textFaint),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}


class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.busy,
    required this.stopLabel,
    required this.h,
    required this.onTap,
    this.hasContent = false,
  });

  final bool enabled;
  final bool busy;

  /// true = 显示**停止**（当前会话在跑）；false = 显示**等待**（别的会话在跑）
  final bool stopLabel;

  final Hue h;
  final VoidCallback onTap;

  /// **输入框里有没有内容**（2026-10-13 用户要求）。
  ///
  /// 用户原话：「上面消息在处理的时候，我要发送第二轮消息，
  /// 但是这个发送按钮还是暂停按钮，所以要有一个逻辑，
  /// **输入框里有字的时候，暂停按钮变成发送按钮**」。
  ///
  /// 忙 + 有内容 = 用户在**排队**，不是想停 → 显示**发送**；
  /// 忙 + 无内容 = 用户想**停止** → 显示**停止**。
  /// 视觉与点击行为必须一致 —— 图标说了什么，点下去就做什么。
  final bool hasContent;

  @override
  Widget build(BuildContext context) {
    final active = enabled || busy;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 46,
      height: 46,
      // ★ 圆形（2026-10-12，参考图：发送键是圆的）
      // 2026-10-25：原型 01 发送键 = 实心圆 + 反色箭头。旧版 accent 底
      // 配深棕图标，在黑白主题下糊成一团（真机截图：黑圆里一团黑）。
      decoration: BoxDecoration(
        color: active ? h.text : h.surface,
        shape: BoxShape.circle,
        border: Border.all(color: active ? h.text : h.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Icon(
            // ★ 三态（2026-10-13，用户要求"有字时变发送"）：
            //   · 忙 + 输入框有内容 → **发送**（这条会排队/插话，不是停止）
            //   · 忙 + 无内容 + 当前会话在跑 → **停止**
            //   · 忙 + 无内容 + 别的会话在跑 → **沙漏**（不是这里在跑）
            //   · 空闲 → 发送
            busy && !hasContent
                ? (stopLabel
                    ? AppIcons.stop
                    : CupertinoIcons.hourglass)
                : AppIcons.send,
            size: 21,
            color: active
                ? (h.dark ? const Color(0xFF0A0A0B) : Colors.white)
                : h.textFaint,
          ),
        ),
      ),
    );
  }
}

/// **圆形按钮**（`+`）—— 参考图：加号是圆的。
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.h,
    this.onTap,
  });

  final IconData icon;
  final Hue h;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return SizedBox(
      width: 46,
      height: 46,
      child: Material(
        color: h.surface,
        shape: const CircleBorder(
          side: BorderSide(color: Colors.transparent),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Icon(
            icon,
            size: 23,
            color: active ? h.textDim : h.textFaint,
          ),
        ),
      ),
    );
  }
}

/// **权限图标按钮** —— 参考图：只显示图标，点击弹权限选择框。
///
/// 图标随档位变化（盾牌 / 警告），需要提权的档位用警示色 ——
/// 一眼看出"当前状态要不要小心"，不用点开才知道。
class _PermissionIconButton extends StatelessWidget {
  const _PermissionIconButton({
    required this.permission,
    required this.h,
    required this.enabled,
    required this.onPicked,
  });

  final PermissionMode permission;
  final Hue h;
  final bool enabled;
  final ValueChanged<PermissionMode>? onPicked;

  Future<void> _open(BuildContext context) async {
    // ★ 审批模式抽屉（原型 10，2026-10-25 重做）：三档自定义行 +
    //   点「完全访问」在同一位置叠出二次确认抽屉（不先关再开）。
    //   实现在 bw_approval.dart 的 showApprovalModeSheet —— 安全
    //   语义不变：确认前不回调、取消 = 什么都不改。
    await showApprovalModeSheet(
      context,
      current: permission,
      onPicked: (m) => onPicked?.call(m),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 46,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? () => _open(context) : null,
          customBorder: const CircleBorder(),
          child: Icon(
            // 三档三枚图标（用户指定）—— 与权限菜单每行的图标一致。
            // 完全访问额外用警示色：一眼看出"当前状态要小心"。
            permission.icon,
            size: 22,
            color: permission.requiresElevation
                ? HColors.warnOn(h.dark)
                : h.textDim,
          ),
        ),
      ),
    );
  }
}

/// **模型选择框** —— 两枚并排胶囊（原型 01）：[模型名 ▾] [思考 · 高]，
/// 点任意一枚都打开模型与思考半抽屉（原型 09，见 bw_model_sheet.dart）。
class _ModelSelector extends StatelessWidget {
  const _ModelSelector({
    required this.label,
    required this.reasoningLevel,
    required this.h,
    required this.onTap,
    required this.onReasoningLevelChanged,
    required this.providers,
    required this.activeProviderId,
    required this.onProviderSelected,
    this.onOpenModelCatalog,
    this.maxTurns = 0,
    this.onMaxTurnsChanged,
  });

  final String? label;
  final ReasoningLevel reasoningLevel;
  final Hue h;
  final VoidCallback? onTap;

  /// 用户在弹出列表里改了推理等级
  final ValueChanged<ReasoningLevel>? onReasoningLevelChanged;

  /// **单次任务最大轮次**（2026-10-18，ADR-033）。`0` = 自动跟随当前后端。
  final int maxTurns;

  /// 用户在弹出列表里改了最大轮次
  final ValueChanged<int>? onMaxTurnsChanged;

  /// 全部 provider（弹层里列出；已配置的才可选中）
  final List<ModelProviderConfig> providers;

  /// 当前选中的 provider id
  final String? activeProviderId;

  /// 用户选中了某个 provider
  final ValueChanged<String>? onProviderSelected;

  /// **点进 provider 的模型目录选模型**（2026-10-14，用户要求：
  /// 「选择基元律动来当模型用是可以点进去选择模型的」）——
  /// 弹层里点配了目录的 provider 时触发
  final ValueChanged<String>? onOpenModelCatalog;

  /// 点击模型框 → 模型与思考半抽屉（原型 09，实现在
  /// bw_model_sheet.dart 的 showModelSheet）。旧版弹层是服务商
  /// Cupertino 列表 + 内嵌分段，与原型不是同一套版式，2026-10-25
  /// 按用户「严格按原型图」整体迁出重做；选择语义（点选即生效、
  /// 同档不回调、目录两层、未配置不渲染）一条不变。
  Future<void> _open(BuildContext context) async {
    await showModelSheet(
      context,
      providers: providers,
      activeProviderId: activeProviderId,
      reasoningLevel: reasoningLevel,
      maxTurns: maxTurns,
      onProviderSelected: onProviderSelected,
      onOpenModelCatalog: onOpenModelCatalog,
      onReasoningLevelChanged: onReasoningLevelChanged,
      onMaxTurnsChanged: onMaxTurnsChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = (label == null || label!.isEmpty) ? '模型' : label!;
    // ★ 结构对齐盾牌按钮（_PermissionIconButton —— 真机已验证可点）：
    //   SizedBox > Material(transparent) > InkWell > 内容。
    //   之前 GestureDetector(opaque)+Container(带 boxShadow) 在真机上
    //   tap 无响应（连 onTapDown 都没到 —— 有透明遮挡/竞技场差异），
    //   widget 测试却通过。改用与**对照组（盾牌）完全相同**的结构。
    // 胶囊外形（两枚共用）：浅底 + 边框 + 轻投影"托"起来
    BoxDecoration pillDeco() => BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.pill),
          border: Border.all(color: h.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: h.dark ? 0.30 : 0.08),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        );
    // 思考档位的紧凑中文（原型 01 写法「思考 · 高」）
    final thinkShort = switch (reasoningLevel) {
      ReasoningLevel.auto => '自动',
      ReasoningLevel.off => '关',
      ReasoningLevel.low => '低',
      ReasoningLevel.high => '高',
      ReasoningLevel.max => '最高',
    };
    Widget pill(Widget child) => Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _open(context),
            borderRadius: BorderRadius.circular(HRadius.pill),
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: HSpace.md),
              decoration: pillDeco(),
              child: child,
            ),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ★ 不给模型加前置图标（2026-10-12 用户明确要求）
        pill(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              // 两枚胶囊并排，长模型名截断，不把发送键挤出屏幕
              constraints: const BoxConstraints(maxWidth: 104),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: h.text),
              ),
            ),
            const SizedBox(width: HSpace.xs),
            Icon(AppIcons.chevronDown, size: 18, color: h.textDim),
          ],
        )),
        const SizedBox(width: HSpace.xs),
        pill(Center(
          child: Text(
            '思考 · $thinkShort',
            style: TextStyle(fontSize: 12, color: h.textDim),
          ),
        )),
      ],
    );
  }
}

/// **权限三档的图标**（2026-10-12，用户给的三张参考小图）：
/// - 手动审批 = 纯盾牌（逐条确认，最安全）
/// - 工作区内修改 = 盾牌+月牙（半自动）
/// - 完全访问 = 感叹号（无拦截，风险）
///
/// 放展示层而非 `models/`：图标是 UI 概念，
/// `models/` 不 import Flutter（与 `:core` 不 import android 同理）。
extension PermissionModeIcon on PermissionMode {
  /// 用户给的三张参考小图（盾+勾 / 盾+管理 / 盾+叹号）——
  /// Cupertino 化后仍用同族盾牌图形（2026-10-22）：
  /// · 手动审批  = checkmark_shield（盾+勾）—— 逐条人工批准，图形完全一致
  /// · 工作区内  = lock_shield（盾+锁）—— Cupertino 无"盾+笔"，
  ///   这是语义最近的（受控放行），已向用户说明是近似
  /// · 完全访问  = exclamationmark_shield（盾+叹号）—— 与参考图3完全一致
  IconData get icon => switch (this) {
        PermissionMode.manual => CupertinoIcons.checkmark_shield,
        PermissionMode.workspaceAuto => AppIcons.shield,
        PermissionMode.fullAccess => CupertinoIcons.exclamationmark_shield,
      };
}


/// **一条排队待发的消息**（2026-10-13，按用户参考图）。
///
/// ```
/// ╭────────────────────────────────────────────────╮
/// │ 💬 这是排队任务            ⧉      🗑      ↑    │
/// ╰────────────────────────────────────────────────╯
/// ```
///
/// ## 三个动作的语义（不能混）
///
/// | 图标 | 语义 | 是否打断当前运行 |
/// |---|---|---|
/// | ⧉ | **置顶**（让它下一个发） | ❌ 不打断，等当前跑完 |
/// | 🗑 | 删除这条 | ❌ |
/// | ↑ | **立即发送** | ✅ **打断当前运行**再发 |
///
/// 置顶与立即发送必须区分：前者是"排到最前"，后者是"现在就插话"。
/// 参考图把它们并列放，但含义不同 —— 实现里分成两个回调。
class _QueuedRow extends StatelessWidget {
  const _QueuedRow({
    required this.h,
    required this.text,
    required this.onSendNow,
    required this.onRemove,
    required this.onPin,
    required this.canPin,
  });

  final Hue h;
  final String text;
  final VoidCallback? onSendNow;
  final VoidCallback? onRemove;
  final VoidCallback? onPin;

  /// 已在队首时"置顶"没有意义 —— 不画那个按钮
  final bool canPin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.md, 0, HSpace.md, HSpace.xs),
      child: Container(
        decoration: BoxDecoration(
          color: h.surface,
          borderRadius: BorderRadius.circular(HRadius.xl),
          border: Border.all(color: h.border),
          boxShadow: [
            // 与输入容器同款投影 —— 看起来是输入区的一部分
            BoxShadow(
              color: Colors.black.withValues(alpha: h.dark ? 0.30 : 0.08),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: HSpace.md),
            // 💬 —— 用「排队」语义的图标，不是聊天气泡（避免与消息混淆）
            Icon(AppIcons.clock, size: 16, color: h.textFaint),
            const SizedBox(width: HSpace.sm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: HSpace.md),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: h.text),
                ),
              ),
            ),
            if (canPin && onPin != null)
              _iconBtn(CupertinoIcons.arrow_up_to_line, '置顶（下一个发）', onPin!),
            if (onRemove != null)
              _iconBtn(AppIcons.trash, '删除', onRemove!),
            if (onSendNow != null)
              _iconBtn(AppIcons.send, '立即发送（打断当前任务）',
                  onSendNow!, accent: true),
            const SizedBox(width: HSpace.xs),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {bool accent = false}) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 18,
            color: accent ? h.accent : h.textDim,
          ),
        ),
      ),
    );
  }
}