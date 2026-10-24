import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/attachment.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import 'bw_approval.dart';

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
                        placeholder: widget.queuedTexts.isEmpty
                            ? '发送消息或点击 + 上传文件或图片'
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
      decoration: BoxDecoration(
        color: active ? h.accent : h.surface,
        shape: BoxShape.circle,
        border: Border.all(color: active ? h.accent : h.border),
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
            color: active ? const Color(0xFF1A0E08) : h.textFaint,
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
    // ★ 底部弹层（2026-10-12）：与模型框同款交互。
    //   锚点菜单在键盘模式下会弹到屏幕中部（与模型框同一个 bug），
    //   底部弹层不依赖锚点定位 —— 键盘模式也不错位。
    final h = Hue.of(context);
    final picked = await showModalBottomSheet<PermissionMode>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: CupertinoTheme(
          data: CupertinoThemeData(
            brightness: h.dark ? Brightness.dark : Brightness.light,
            primaryColor: h.accent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: HSpace.sm),
              for (final v in PermissionMode.values)
                CupertinoListTile(
                  // 三档三枚图标（用户给的三张参考小图）——
                  // 完全访问用警示色，与其余两档区分
                  leading: Icon(v.icon,
                      size: 23,
                      color: v.requiresElevation
                          ? HColors.warnOn(h.dark)
                          : h.textDim),
                  title: Text(v.label,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: v == permission
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: v == permission ? h.accent : h.text)),
                  subtitle: Text(v.description,
                      style:
                          TextStyle(fontSize: 12, color: h.textFaint)),
                  trailing: v == permission
                      ? Icon(AppIcons.check,
                          size: 19, color: h.accent)
                      : null,
                  onTap: () => Navigator.of(sheetCtx).pop(v),
                ),
              const SizedBox(height: HSpace.sm),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == permission) return;

    // ★★ 切「完全访问」必须二次确认（2026-10-12，用户要求）
    //
    // 这段逻辑原来在旧版 `_pickPermission` 里 —— 输入框改版时我一度把它
    // 随旧类一起删掉了（**安全护栏的回归**，测试抓回来的）。现在它属于
    // 这个图标按钮：**换到 fullAccess 就必须停下来确认，不管入口长什么样**。
    if (picked == PermissionMode.fullAccess) {
      // ★★ 切「完全访问」必须二次确认（2026-10-12，用户要求；
      //   2026-10-24 黑白改版：居中弹窗改为同款上拉抽屉 + 勾选门禁）。
      //
      // 安全语义一字不变：必须显式选择，点遮罩/下滑都不算确认；
      // 只有勾选「我已知晓」并点「确认选择」才算确认，取消/返回 = 不改。
      // （本组件无 mounted 可查；confirm sheet 自带 isDismissible:false，
      //   context 只用来挂载，与旧弹窗的 ignore 理由相同。）
      final confirmed = await showFullAccessConfirmSheet(
        // ignore: use_build_context_synchronously
        context,
      );
      // 取消 = 什么都不改
      if (!confirmed) return;
    }

    onPicked?.call(picked);
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

/// **模型选择框** —— 参考图：带阴影边框的胶囊，
/// 「◆ 模型名 (4B) ▾」，点击弹出模型/推理等级列表。
///
/// ⚠️ 注意：fullAccess 的**二次风险确认**（`_pickPermission` 里那道）
/// 在这个图标按钮里**没有** —— 因为这里只弹选择框，确认逻辑应在
/// `onPicked` 的上层做（chat_screen 接到回调后判断目标档位再确认）。
/// 本轮先保持"选择即生效"，二次确认的迁移作为遗留记在 WORKLOG。
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

  /// 点击模型框 → 底部弹层（**图二**内容：模型行 + 推理等级行）。
  ///
  /// ## 为什么从「贴锚点的 showMenu」改成 `showModalBottomSheet`
  ///
  /// 真机实测（2026-10-12）：锚点菜单在键盘模式下**弹到屏幕中部**
  /// （定位错位），且换 GestureDetector / anchorKey / 对照结构三轮后
  /// **连 onTapDown 都收不到**（有透明的手势竞争者盖在胶囊区域）。
  /// 底部弹层不依赖锚点定位 —— 没有那两类问题，且在手机上是
  /// 比"贴着小控件弹小菜单"更常见的交互（与参考图二的信息一致）。
  Future<void> _open(BuildContext context) async {
    final h2 = h;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: h2.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        // ★ 可滚动（2026-10-14 修溢出）：provider 多 + 推理等级五档
        //   + 说明文字，总高超屏就是 BOTTOM OVERFLOWED（用户截图：
        //   BY 59 PIXELS）。整个弹层放进单子项滚动的 Column。
        child: SingleChildScrollView(
          child: CupertinoTheme(
            // 弹层里的 Cupertino 控件按 App 深浅色解析（默认跟系统，会错）
            data: CupertinoThemeData(
              brightness: h2.dark ? Brightness.dark : Brightness.light,
              primaryColor: h2.accent,
            ),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: HSpace.sm),
              // ---- ★ 后端列表（2026-10-12）：点选即切换 ----
              //
              // ★ 2026-10-14 改（用户反馈）：
              //   「上面只显示配置好的模型，没配置好的不显示」——
              //   未配置的 provider **直接不渲染**（不是置灰 ——
              //   置灰还是会把"去设置页填 Key"这种噪音混进选择列表）。
              //
              //   「选择基元律动来当模型用是可以点进去选择模型的」——
              //   配了**模型目录**的 provider 点进去是**二级页**：
              //   选它目录里的具体模型。
              for (final p in providers)
                if (p.isConfigured || AppSettings.isLocalConfig(p))
                  CupertinoListTile(
                    title: Text(p.name, style: const TextStyle(fontSize: 15)),
                    subtitle: Text(
                      // 显示当前用的模型（或目录数量）
                      (p.id == activeProviderId && p.model.isNotEmpty)
                          ? p.model
                          : (p.modelCatalog.isNotEmpty
                              ? '模型目录 · ${p.modelCatalog.length} 个'
                              : p.model),
                      style: TextStyle(fontSize: 12, color: h2.textFaint),
                    ),
                    // ★ 尾部图标：对勾与箭头**不是二选一**（2026-10-15 修 BUG-6）
                    //
                    // ## 修的是什么（真机实测）
                    //
                    // 用户实测：`tokenrhythm` **没有显示 `›` 箭头**，
                    // 但点它确实能进入二级菜单（25 个模型）——
                    // 用户不知道这个能点进去。
                    //
                    // ## 根因（逻辑错误）
                    //
                    // 旧代码把"选中态"与"可进入"做成了三元互斥：
                    //     trailing: (p.id == activeProviderId)
                    //         ? Icon(对勾)          ← 选中的只显示对勾
                    //         : (有目录 ? Icon(箭头) : null)
                    // 而**当前选中的 provider 恰恰是最需要提示"能点进去"的那个**
                    // （用户刚用它聊过，最可能想换它下面的模型）。
                    //
                    // ## 修法：两个语义都表达
                    //
                    // 对勾 = "当前选中"，箭头 = "可进入选模型" —— 同时显示。
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (p.id == activeProviderId)
                          Icon(AppIcons.check, size: 19, color: h2.accent),
                        if (p.modelCatalog.isNotEmpty) ...[
                          if (p.id == activeProviderId)
                            const SizedBox(width: HSpace.xs),
                          Icon(AppIcons.chevronRight,
                              size: 19, color: h2.textFaint),
                        ],
                      ],
                    ),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      // ★ 配了模型目录的 provider → **进目录选模型**
                      //   （用户原话：「选择基元律动来当模型用是可以
                      //   点进去选择模型的」）—— 选中即切 provider + 换模型
                      if (p.modelCatalog.isNotEmpty) {
                        onOpenModelCatalog?.call(p.id);
                      } else {
                        onProviderSelected?.call(p.id);
                      }
                    },
                  ),
              const Divider(height: 1),
            // ---- 推理等级：就地展开五档 ----
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: HSpace.md, vertical: HSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(AppIcons.think,
                          size: 21, color: h2.textDim),
                      const SizedBox(width: HSpace.md),
                      const Text('推理等级', style: TextStyle(fontSize: 15)),
                      const Spacer(),
                      Text(reasoningLevel.label,
                          style: TextStyle(
                              fontSize: 13, color: h2.textDim)),
                    ],
                  ),
                  const SizedBox(height: HSpace.sm),
                  Wrap(
                    spacing: HSpace.sm,
                    runSpacing: HSpace.sm,
                    children: [
                      for (final v in ReasoningLevel.values)
                        _PillOption(
                          label: v.label,
                          selected: v == reasoningLevel,
                          h: h2,
                          onTap: () {
                            Navigator.of(sheetCtx).pop();
                            // ★ 选同一个档位不回调 —— 不产生无意义的写盘
                            //（与旧锚点菜单同语义，测试「同档不回调」钉它）
                            if (v != reasoningLevel) {
                              onReasoningLevelChanged?.call(v);
                            }
                          },
                        ),
                    ],
                  ),
                  // ★ 当前档位的说明（与旧锚点菜单的 detail 同源 ——
                  //   本地三档相同/云端各异的如实说明，信息不能丢）
                  const SizedBox(height: HSpace.sm),
                  Text(
                    _detailFor(reasoningLevel),
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: h2.textDim),
                  ),
                  // ★ 本地两态提示已移除（2026-10-12 用户要求）：
                  //   用户不再用本地模型 —— 云端与电脑后端都真实支持分档，
                  //   那句"只有开/关"反而成了噪音。
                ],
              ),
            ),
            const Divider(height: 1),
            // ---- ★ 最大轮次（2026-10-18，docs/27 P0-1 / ADR-033）----
            //
            // ## 修的是什么
            //
            // 最大轮次此前**硬编码 8**，真机上**云端模型也只在 8 轮内跑** ——
            // 一个要十几步的构建/重构任务会被无理由截断，用户看到的是
            // "模型干到一半就不动了"，而且**没有任何提示**（这不是模型的错）。
            //
            // ## 为什么放在这个弹层里
            //
            // 它和推理等级是同一类东西：**单次运行的成本参数**。
            // 再开一个入口只会让"模型设置"散成好几处。
            //
            // ## 为什么必须写人话提示
            //
            // "8 轮"对用户不是自明的量：轮次 = 工具调用次数 = 请求次数
            // = 云端花的钱 + 用户等的时间。只给数字等于让用户猜。
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: HSpace.md, vertical: HSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(CupertinoIcons.repeat,
                          size: 21, color: h2.textDim),
                      const SizedBox(width: HSpace.md),
                      const Text('最大轮次', style: TextStyle(fontSize: 15)),
                      const Spacer(),
                      Text(_maxTurnsLabel,
                          style: TextStyle(fontSize: 13, color: h2.textDim)),
                    ],
                  ),
                  const SizedBox(height: HSpace.sm),
                  Wrap(
                    spacing: HSpace.sm,
                    runSpacing: HSpace.sm,
                    children: [
                      for (final v in kMaxTurnsOptions)
                        _PillOption(
                          label: v == 0 ? '自动' : '$v',
                          selected: v == maxTurns,
                          h: h2,
                          onTap: () {
                            Navigator.of(sheetCtx).pop();
                            // ★ 选同一档不回调 —— 与上面推理等级同语义
                            //   （不产生无意义的写盘）
                            if (v != maxTurns) {
                              onMaxTurnsChanged?.call(v);
                            }
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: HSpace.sm),
                  // ★ 人话说明（**三个事实都要说**，别只丢一个数字）：
                  //   · 自动 = 本地跟 8、云端跟 40（默认，不用管）
                  //   · 加大轮次 = 单次任务可能跑更久
                  //   · 加大轮次 = 云端花费更多
                  Text(
                    '自动 = 云端 40 轮（默认）。\n'
                    '轮次越多，单次任务能做的步骤越多，但可能跑更久；'
                    '云端按轮计费，花费也更多。',
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: h2.textDim),
                  ),
                ],
              ),
            ),
            const SizedBox(height: HSpace.md),
          ],
        ),
          ), // CupertinoTheme（弹层内 Cupertino 控件的深浅色）
      ),
      ),
    );
  }

  /// 当前最大轮次的**行尾显示**（`0` 要显示成"自动"，不是"0"）。
  ///
  /// 「0 轮」在界面上是**错的**（那等于什么都不能做）——
  /// `0` 的语义是"我不指定，由后端决定"，所以必须写"自动"。
  String get _maxTurnsLabel => maxTurns == 0 ? '自动' : '$maxTurns';

  /// 档位说明。
  ///
  /// ★ 2026-10-18（ADR-035 S4）：原先"本地后端下 Low/High/Max **说明必须
  /// 完全相同**"那条分支随本地后端**整体删除** —— 本地 `llama-server`
  /// 静默忽略 `reasoning_effort`（`docs/25` §10.3），而**云端真的支持分档**，
  /// 所以现在直接给 `ReasoningLevel.description`（各档不同、都是真话）。
  ///
  /// ⚠️ 那段历史不该失传：给本地三档编出"更深/更浅"的差异曾是**假信息**。
  /// 今天的云端不存在这个问题，但**新的后端**接进来时仍要重新问一遍
  /// "它真的支持分档吗"，而不是照抄描述。
  String _detailFor(ReasoningLevel v) => v.description;

  @override
  Widget build(BuildContext context) {
    final name = (label == null || label!.isEmpty) ? '模型' : label!;
    // ★ 结构对齐盾牌按钮（_PermissionIconButton —— 真机已验证可点）：
    //   SizedBox > Material(transparent) > InkWell > 内容。
    //   之前 GestureDetector(opaque)+Container(带 boxShadow) 在真机上
    //   tap 无响应（连 onTapDown 都没到 —— 有透明遮挡/竞技场差异），
    //   widget 测试却通过。改用与**对照组（盾牌）完全相同**的结构。
    return SizedBox(
      height: 38,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _open(context),
          borderRadius: BorderRadius.circular(HRadius.pill),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: HSpace.md),
            decoration: BoxDecoration(
              color: h.surfaceAlt,
              borderRadius: BorderRadius.circular(HRadius.pill),
              border: Border.all(color: h.border),
              boxShadow: [
                // 参考图：模型框有**阴影** —— 轻投影把它从底色上"托"起来
                BoxShadow(
                  color: Colors.black.withValues(alpha: h.dark ? 0.30 : 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ★ 不给模型加前置图标（2026-10-12 用户明确要求）：
                //   「不要给模型前面加一些没有意义的图标，
                //     又不是大模型本身的图标」—— 六边形已移除。
                ConstrainedBox(
                  // 长模型名截断，不把发送键挤出屏幕
                  constraints: const BoxConstraints(maxWidth: 130),
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
            ),
          ),
        ),
      ),
    );
  }
}

/// **iOS 风格单选胶囊**（2026-10-22 Cupertino 化，替换 Material `ChoiceChip`）。
///
/// 选中 = 主色实心，未选 = 描边 —— iOS 没有"底色加深+对勾"的 chip，
/// 用胶囊填充是最接近的视觉语言。排布（Wrap）与语义（点选、
/// 同档不回调）和旧 ChoiceChip 完全一致。
class _PillOption extends StatelessWidget {
  const _PillOption({
    required this.label,
    required this.selected,
    required this.h,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Hue h;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: HSpace.md, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? h.accent : h.surface,
          borderRadius: BorderRadius.circular(HRadius.pill),
          border: Border.all(color: selected ? h.accent : h.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? (h.dark
                    ? const Color(0xFF1A0E08)
                    : const Color(0xFFFFFFFF))
                : h.textDim,
          ),
        ),
      ),
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