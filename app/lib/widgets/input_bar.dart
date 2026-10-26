import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/attachment.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/pressable.dart';
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
    this.workspaceLabel,
    this.onWorkspaceTap,
    this.onGithubTap,
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
  });

  final void Function(String text) onSend;

  /// 点 `+` —— 由上层弹选择器（相册 / 文件）
  final VoidCallback? onPickAttachment;

  final void Function(String attachmentId)? onRemoveAttachment;

  /// 已选附件
  final List<HAttachment> attachments;

  /// 底部信息条显示的工作区名（2026-10-26 TRAE 式输入区）；null 显示「工作区」
  final String? workspaceLabel;

  /// 点信息条的工作区项（外层打开抽屉换区）
  final VoidCallback? onWorkspaceTap;

  /// 点信息条的「连接 Github」—— 功能未接入，先占位前端
  /// （用户 2026-10-26 定：先把前端做好，后续不做再撤）
  final VoidCallback? onGithubTap;

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

  // 最大轮次不在输入区改（2026-10-25 用户定）：唯一入口在
  // 通用设置页，输入区不再透传 maxTurns。

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

class _InputBarState extends State<InputBar>
    with SingleTickerProviderStateMixin {
  /// 内部自建的控制器 —— 仅当上层**没有**传 [InputBar.inputController]
  /// 时才创建/销毁（外部控制器由上层持有，dispose 归上层管）
  TextEditingController? _ownController;
  late final TextEditingController _controller =
      widget.inputController ?? (_ownController = TextEditingController());
  final _focus = FocusNode();
  bool _hasText = false;

  /// 生成中流光动画（6s 一圈）：旋转描边 + 呼吸光晕共用
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  /// 当前会话正在生成时才发光（别的会话在跑不算）
  bool get _glowActive => widget.busy && widget.stopLabel;

  @override
  void initState() {
    super.initState();
    if (_glowActive) _glow.repeat();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void didUpdateWidget(InputBar old) {
    super.didUpdateWidget(old);
    if (_glowActive && !_glow.isAnimating) {
      _glow.repeat();
    } else if (!_glowActive && _glow.isAnimating) {
      _glow.stop();
    }
  }

  @override
  void dispose() {
    _glow.dispose();
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

            // ---- ★ 输入大卡 + 托盘（2026-10-26，用户对图三修正）----
            //
            // 轮廓 6 个圆角（用户数过）：白卡左上/右上 2 个 + 灰色托盘
            // 比白卡宽一圈、在卡下沿两侧探出「台阶角」2 个 + 托盘左下/
            // 右下 2 个。托盘灰要够灰（旧版信息条和卡同白、色对不上）：
            // 浅色用 surface 再压一层 7% 黑，深色直接用 surface（本就
            // 比卡面 surfaceAlt 深一档）。信息条透明坐在托盘露出的
            // 下沿带上，无分隔线（图三靠色阶分层）。不要麦克风。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HSpace.md, HSpace.sm + 2, HSpace.md, HSpace.md,
              ),
              child: Stack(
                children: [
                  // ---- 生成中弥散光晕（卡背后，呼吸）----
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -8,
                    height: 118,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _glowActive ? 1 : 0,
                        duration: const Duration(milliseconds: 350),
                        child: AnimatedBuilder(
                          animation: _glow,
                          builder: (context, _) {
                            final breathe =
                                0.55 + 0.30 * math.sin(_glow.value * 2 * math.pi);
                            final base = h.glowColors.isNotEmpty
                                ? h.glowColors.first
                                : h.text;
                            return Opacity(
                              opacity: breathe,
                              child: ImageFiltered(
                                imageFilter: ui.ImageFilter.blur(
                                    sigmaX: 24, sigmaY: 24),
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: RadialGradient(
                                      center: const Alignment(0, 0.9),
                                      radius: 1.1,
                                      colors: [
                                        base.withValues(
                                            alpha: h.dark ? 0.30 : 0.20),
                                        base.withValues(alpha: 0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    // 信息条高 44 + 与白卡重叠 12
                    height: 56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: h.dark
                            ? h.surface
                            : Color.alphaBlend(
                                Colors.black.withValues(alpha: 0.12),
                                h.surface),
                        // ★ 6 圆角要「读得出」：台阶角必须在重叠带内
                        // 走完弧线 —— 上圆角 14（小、完整露在台阶上），
                        // 下圆角 28；旧版全 28 时弧线大半被白卡盖住，
                        // 台阶看起来是直角（用户实报）。阴影同步放软，
                        // 让托盘颜色退后、不抢轮廓。
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          topRight: Radius.circular(14),
                          bottomLeft: Radius.circular(28),
                          bottomRight: Radius.circular(28),
                        ),
                        boxShadow: [
                          // 阴影只留一层很淡的：卡与托盘各挂一层时，
                          // 两层方形晕叠在托盘带上，用户连着两次看成
                          // 「圆角外面还有直角」——这次托盘靠填充色
                          // 本身立轮廓（对齐图二的灰度差），阴影退后。
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: h.dark ? 0.30 : 0.05),
                            blurRadius: 18,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: Container(
                          decoration: BoxDecoration(
                            // 图二的卡是纯白（浅色 surfaceAlt=#F0F0F0 显灰）；
                            // 深色沿用 surfaceAlt（比底色亮一档即是它的白）
                            color: h.dark ? h.surfaceAlt : Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: h.border),
                            // 无阴影：见托盘处注释（双层方形晕的问题）
                            boxShadow: const [],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                    // ---- 附件 tile 区（卡内顶部，图二形态）----
                    if (widget.attachments.isNotEmpty)
                      _AttachmentRow(
                        attachments: widget.attachments,
                        h: h,
                        onRemove: widget.onRemoveAttachment,
                      ),
                    // ---- 文本区 ----
                    // ★ ConstrainedBox maxHeight 130：maxLines:null 的
                    //   TextField 会随内容无限长 —— 限高后多行内部滚动，
                    //   容器高度封顶（不设上限会 BOTTOM OVERFLOWED）。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 130),
                      child: CupertinoTextField.borderless(
                        controller: _controller,
                        focusNode: _focus,
                        enabled: widget.enabled,
                        maxLines: null,
                        minLines: 1,
                        // ★ 回车 = 发送（真机习惯与全部测试的既有语义）
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.45,
                          color: h.text,
                        ),
                        placeholder: widget.queuedTexts.isEmpty
                            ? '给 Heracles 发消息…'
                            : '发送将排在队尾；↑ 可插队立即发送',
                        placeholderStyle:
                            TextStyle(color: h.textFaint, fontSize: 15),
                        padding: const EdgeInsets.fromLTRB(
                          HSpace.lg, HSpace.md, HSpace.lg, HSpace.sm,
                        ),
                      ),
                    ),
                    // ---- 底行：＋(小) / 模型胶囊 / 权限盾 / 发送 ----
                    //
                    // 2026-10-26 对图二（TRAE）再对齐：＋是小圆钮带灰底；
                    // 权限盾挪到人家麦克风的位置（发送键左边），麦克风
                    // 不做（用户早已明说不要）；发送键恒黑底白箭头。
                    //
                    // ★ 发送键语义与图标一致（2026-10-13 定）：
                    //   空闲 → 发送；忙 + 无内容 → 停止；忙 + 有内容 →
                    //   发送/排队（用户原话「有字时暂停按钮变发送」）。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Row(
                        children: [
                          _CircleButton(
                            icon: AppIcons.add,
                            h: h,
                            onTap:
                                widget.enabled ? widget.onPickAttachment : null,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: _ModelSelector(
                              label: widget.providerLabel,
                              reasoningLevel: widget.reasoningLevel,
                              h: h,
                              onTap: widget.onModelTap,
                              onReasoningLevelChanged:
                                  widget.onReasoningLevelChanged,
                              providers: widget.providers,
                              activeProviderId: widget.activeProviderId,
                              onProviderSelected: widget.onProviderSelected,
                              onOpenModelCatalog: widget.onOpenModelCatalog,
                            ),
                          ),
                          const SizedBox(width: 10),
_PermissionIconButton(
                            permission: widget.permission,
                            h: h,
                            enabled: widget.enabled,
                            onPicked: widget.onPermissionChanged,
                          ),
                          const SizedBox(width: 8),
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
                      // ---- 信息条（坐在托盘下沿带上）----
                      _EnvStrip(
                        h: h,
                        workspaceLabel: widget.workspaceLabel,
                        onWorkspaceTap: widget.onWorkspaceTap,
                        onGithubTap: widget.onGithubTap,
                      ),
                    ],
                  ),
                  // ---- 生成中旋转流光描边（贴白卡轮廓）----
                  Positioned(
                    left: 5,
                    right: 5,
                    top: 0,
                    bottom: 44,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _glowActive ? 1 : 0,
                        duration: const Duration(milliseconds: 350),
                        child: CustomPaint(
                          painter: _FlowBorderPainter(
                            progress: _glow,
                            radius: 24,
                            colors: h.glowColors.isNotEmpty
                                ? h.glowColors
                                : [h.text],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件展示行（2026-10-25 晚按用户给的参考图定）：
///
/// · **图片** ⇒ 直接显示缩略图（圆角 + 右上角圆形 ×）—— 发之前能看清
///   发的是哪张图，而不是一个文件名 chip；
/// · **文件** ⇒ 文件卡（图标砖 + 文件名 + 大小 + 右上角圆形 ×）。
///
/// 横向滚动，多个附件不挤压输入框；参考图底部的「分析一下」快捷
/// 建议胶囊**不做**（用户明确说不需要）。
/// 输入大卡下沿的信息条（2026-10-26，用户按 TRAE 参考图定）：
/// 工作区 · 连接 Github · 选择分支。
///
/// - 工作区：显示当前工作区名，点按由外层打开抽屉换区；
/// - 连接 Github：功能未接入 —— 用户定「先把前端做好，后续不做再撤」，
///   点按由外层给占位提示，不假装已连通；
/// - 选择分支：未连 Github 前置灰不可用（与参考图一致）。
class _EnvStrip extends StatelessWidget {
  const _EnvStrip({
    required this.h,
    this.workspaceLabel,
    this.onWorkspaceTap,
    this.onGithubTap,
  });

  final Hue h;
  final String? workspaceLabel;
  final VoidCallback? onWorkspaceTap;
  final VoidCallback? onGithubTap;

  @override
  Widget build(BuildContext context) {
    // 透明：底色是身后的托盘（比卡宽一圈的灰盘），条带高 44 与
    // 输入卡 Stack 里托盘的高度常量（58 = 44 + 14 重叠）对应。
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        children: [
          // 三段等分（中段更宽）：工作区左对齐、Github 居中、分支右对齐。
          // 标签都是 Flexible —— 窄屏先缩可变的工作区名，固定文案
          // （连接 Github / 选择分支）在 360dp 以上不截断（溢出回归守着）。
          Expanded(
            flex: 3,
            child: _item(CupertinoIcons.folder_fill, workspaceLabel ?? '工作区',
                onWorkspaceTap, dim: false, align: Alignment.centerLeft),
          ),
          Expanded(
            flex: 4,
            child: _item(CupertinoIcons.link, '连接 Github', onGithubTap,
                dim: false, align: Alignment.center),
          ),
          Expanded(
            flex: 3,
            child: _item(CupertinoIcons.arrow_branch, '选择分支', null,
                dim: true, align: Alignment.centerRight),
          ),
        ],
      ),
    );
  }

  Widget _item(IconData icon, String label, VoidCallback? onTap,
      {required bool dim, required Alignment align}) {
    return Align(
      alignment: align,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: dim ? null : onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: dim ? h.textFaint : h.textDim),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: dim ? h.textFaint : h.text,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(AppIcons.chevronDown, size: 11, color: h.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.attachments,
    required this.h,
    this.onRemove,
  });

  final List<HAttachment> attachments;
  final Hue h;
  final void Function(String id)? onRemove;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < attachments.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            if (attachments[i].isImage)
              _ImageThumb(a: attachments[i], h: h, onRemove: onRemove)
            else
              _FileTile(a: attachments[i], h: h, onRemove: onRemove),
          ],
        ],
      ),
    );
  }
}

/// 图片附件：缩略图本体（读不到文件时退回图标砖，绝不崩）
class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.a, required this.h, this.onRemove});

  final HAttachment a;
  final Hue h;
  final void Function(String id)? onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.file(
            File(a.path),
            width: 92,
            height: 92,
            fit: BoxFit.cover,
            // 未解码完先占位 88×88：否则宽度塌成 0，右上角的 × 会
            // 落到 Stack 边界外（画得出来但点不中 —— hitTest 先查边界）
            frameBuilder: (_, child, frame, _) => frame == null
                ? Container(
                    width: 92,
                    height: 92,
                    color: h.surface,
                    alignment: Alignment.center,
                    child: Icon(AppIcons.image, size: 26, color: h.textDim),
                  )
                : child,
            errorBuilder: (_, _, _) => Container(
              width: 92,
              height: 92,
              color: h.surface,
              alignment: Alignment.center,
              child: Icon(AppIcons.image, size: 26, color: h.textDim),
            ),
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: 4,
            right: 4,
            child: _RemoveBadge(h: h, onTap: () => onRemove!(a.id)),
          ),
      ],
    );
  }
}

/// 文件附件：方形 tile（2026-10-26 TRAE 图二式）——
/// 顶部一行扩展名徽标 + 右上 ×，文件名沉到底部一行省略。
/// 不显大小：tile 就这么大，信息密度向参考图看齐。
class _FileTile extends StatelessWidget {
  const _FileTile({required this.a, required this.h, this.onRemove});

  final HAttachment a;
  final Hue h;
  final void Function(String id)? onRemove;

  String get _ext {
    final dot = a.name.lastIndexOf('.');
    if (dot <= 0 || dot == a.name.length - 1) return 'FILE';
    final e = a.name.substring(dot + 1).toUpperCase();
    return e.length > 4 ? e.substring(0, 4) : e;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          width: 92,
          height: 96,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: h.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: h.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: h.border),
                  borderRadius: BorderRadius.circular(HRadius.pill),
                ),
                child: Text(
                  _ext,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: h.textDim,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: h.text),
              ),
            ],
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: 4,
            right: 4,
            child: _RemoveBadge(h: h, onTap: () => onRemove!(a.id)),
          ),
      ],
    );
  }
}

/// 附件右上角的圆形删除钮（深底白叉，与参考图同式；深色主题自动反色）
class _RemoveBadge extends StatelessWidget {
  const _RemoveBadge({required this.h, required this.onTap});

  final Hue h;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(color: h.text, shape: BoxShape.circle),
        child: Icon(AppIcons.close, size: 12, color: h.bg),
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
    return Pressable(
      borderRadius: BorderRadius.circular(999),
      enabled: active,
      child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      // 图二的发送圆与 ＋/麦克风同量级（约 40）；46 在小底行里
      // 明显抢眼（用户实报「怎么还这么大」）
      width: 40,
      height: 40,
      // ★ 圆形 + 恒黑底白箭头（2026-10-26 对图二定）：不再随可用态
      // 变灰 —— 图二的发送键永远是主色实心圆。深色下 h.text 是白，
      // 即白底黑箭头（反色），同样恒定。
      decoration: BoxDecoration(
        color: h.text,
        shape: BoxShape.circle,
        border: Border.all(color: h.text),
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
            size: 19,
            color: h.dark ? const Color(0xFF0A0A0B) : Colors.white,
          ),
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
    return Pressable(
      borderRadius: BorderRadius.circular(999),
      enabled: active,
      child: SizedBox(
      // 图二的 ＋ 是小圆钮（38）带浅灰底，与白色卡面拉开层次
      width: 38,
      height: 38,
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
            size: 19,
            color: active ? h.textDim : h.textFaint,
          ),
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
    return Pressable(
      borderRadius: BorderRadius.circular(999),
      enabled: enabled,
      child: SizedBox(
      width: 38,
      height: 38,
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
  });

  final String? label;
  final ReasoningLevel reasoningLevel;
  final Hue h;
  final VoidCallback? onTap;

  /// 用户在弹出列表里改了推理等级
  final ValueChanged<ReasoningLevel>? onReasoningLevelChanged;


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
      onProviderSelected: onProviderSelected,
      onOpenModelCatalog: onOpenModelCatalog,
      onReasoningLevelChanged: onReasoningLevelChanged,
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
    // 胶囊外形（2026-10-26 TRAE 式）：浅灰实心、无边框无投影 ——
    // 卡面是 surfaceAlt，胶囊用 surface 正好沉一档。
    BoxDecoration pillDeco() => BoxDecoration(
          color: h.surface,
          borderRadius: BorderRadius.circular(HRadius.pill),
        );
    // 单枚胶囊：模型名 + ⌄（思考等级在模型抽屉里调，胶囊上不再显）。
    // 名字躺在 Flexible 里才能真收缩，宽度不足走省略号。
    return Pressable(
      borderRadius: BorderRadius.circular(999),
      child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(HRadius.pill),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: pillDeco(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: h.text),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(AppIcons.chevronDown, size: 16, color: h.textDim),
            ],
          ),
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
/// **旋转流光描边**（2026-10-26，用户定：输入框在会话生成时带
/// 动态弥散光晕边框）：一条渐变光弧沿圆角矩形边框缓慢旋转
/// （SweepGradient + GradientRotation），黑白主题下是单色微光，
/// 极光/活力主题下用主题的光晕色组。
class _FlowBorderPainter extends CustomPainter {
  _FlowBorderPainter({
    required this.progress,
    required this.radius,
    required this.colors,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final double radius;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c0 = colors.first;
    final sweep = colors.length >= 2
        ? [
            c0.withValues(alpha: 0),
            c0.withValues(alpha: 0.55),
            colors[1].withValues(alpha: 0.55),
            colors[1].withValues(alpha: 0),
            c0.withValues(alpha: 0.30),
            c0.withValues(alpha: 0),
          ]
        : [
            c0.withValues(alpha: 0),
            c0.withValues(alpha: 0.50),
            c0.withValues(alpha: 0),
            c0.withValues(alpha: 0.26),
            c0.withValues(alpha: 0),
          ];
    final gradient = SweepGradient(
      transform: GradientRotation(progress.value * 2 * math.pi),
      colors: sweep,
    );
    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_FlowBorderPainter old) =>
      old.radius != radius || old.colors != colors;
}
