import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';

/// 审批相关弹层（2026-10-24 黑白改版；2026-10-25 按原型 10/11 重做）。
///
/// 三件套：
/// - 审批模式抽屉（原型 10）：三档自定义行，输入框权限按钮打开；
/// - 完全访问二次确认（原型 10 下半）：叠在模式抽屉之上的同款上拉
///   抽屉，勾选「我已知晓以上风险」后「确认选择」才可用；取消/返回
///   = 不改（沿用旧弹窗的安全语义）；
/// - 运行时审批请求（原型 11）：拒绝 / 允许一次 / 始终允许 + 停止任务，
///   接后端 N1 的 `approval_required` 事件。

/// 完全访问二次确认抽屉。返回 true = 用户勾选并确认。

/// **抽屉动效壳**（2026-10-26，用户按 TRAE 级动效定）：
///
/// - **弹性入场**：弹簧把面板从下方 16px 推到位、轻微过冲再回落
///   稳定（route 自带的匀速滑入之上再叠这一层回弹）；
/// - **橡皮筋拖拽**（allowDrag 的抽屉）：整块面板跟手上下动，
///   往上拖过头只剩 0.32 倍位移（阻尼拉伸感），往下拖是自由行程；
/// - **速度吸附**：松手时下拖超过 110px 或下甩速度 > 620px/s →
///   滑出关闭（等同该抽屉的取消语义，由 onDismissRequest 决定
///   pop 的值）；否则弹簧吸回原位。
///
/// 安全抽屉（审批请求、完全访问二次确认）allowDrag=false：
/// 只能按钮决策，下滑/点外都不构成决定——只保留入场弹性。
class BwSheetShell extends StatefulWidget {
  const BwSheetShell({
    super.key,
    required this.onDismissRequest,
    required this.child,
    this.allowDrag = true,
  });

  final VoidCallback onDismissRequest;
  final bool allowDrag;
  final Widget child;

  @override
  State<BwSheetShell> createState() => _BwSheetShellState();
}

class _BwSheetShellState extends State<BwSheetShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  double _dy = 16;
  double _dragTotal = 0;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (mounted) setState(() => _dy = _anim.value);
      });
    _anim.value = 16;
    _anim.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 200, damping: 19),
      16,
      0,
      0,
    ));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  double get _visualDy => _dy < 0 ? _dy * 0.32 : _dy;

  void _springBack(double velocity) {
    _anim.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 320, damping: 27),
      _dy,
      0,
      velocity,
    ));
  }

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    _anim
        .animateTo(480, duration: const Duration(milliseconds: 190), curve: Curves.easeIn)
        .whenComplete(() {
      if (mounted) widget.onDismissRequest();
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Transform.translate(
      offset: Offset(0, _visualDy),
      child: widget.child,
    );
    if (!widget.allowDrag) return body;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) {
        _anim.stop();
        _dragTotal = _dy;
      },
      onVerticalDragUpdate: (d) {
        _dragTotal += d.delta.dy;
        setState(() => _dy = _dragTotal);
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_dragTotal > 110 || v > 620) {
          _dismiss();
        } else {
          _springBack(v);
        }
      },
      onVerticalDragCancel: () => _springBack(0),
      child: body,
    );
  }
}

Future<bool> showFullAccessConfirmSheet(BuildContext context) async {
  final h = Hue.of(context);
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: h.surfaceAlt,
    // 安全语义不变：必须显式选择，点遮罩/下滑都不算确认
    isDismissible: false,
    enableDrag: false,
    // 矮屏（小屏/横屏/分屏）下内容可滚，不溢出
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(false),
      allowDrag: false,
      child: _FullAccessConfirmSheet(h: h),
    ),
  );
  return confirmed == true;
}

class _FullAccessConfirmSheet extends StatefulWidget {
  const _FullAccessConfirmSheet({required this.h});

  final Hue h;

  @override
  State<_FullAccessConfirmSheet> createState() =>
      _FullAccessConfirmSheetState();
}

class _FullAccessConfirmSheetState extends State<_FullAccessConfirmSheet> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: h.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '开启完全访问？',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '这是最后一道确认',
              style: TextStyle(fontSize: 12.5, color: h.textFaint),
            ),
            const SizedBox(height: 14),
            const Text(
              '开启后，智能体可以：',
              style: TextStyle(fontSize: 14.5),
            ),
            const SizedBox(height: 6),
            for (final line in [
              '· 直接删除、移动任意文件',
              '· 执行任意命令',
              '· 修改工作区之外的路径',
              '· 以上操作都不再询问，且不可撤销',
            ])
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  line,
                  style:
                      TextStyle(fontSize: 14.5, height: 1.5, color: h.textDim),
                ),
              ),
            const SizedBox(height: 16),
            // 勾选行：44 高可点区域，方框 + 对勾
            GestureDetector(
              onTap: () => setState(() => _checked = !_checked),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: _checked ? h.text : Colors.transparent,
                        border: Border.all(color: h.text, width: 1.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: _checked
                          ? Icon(
                              Icons.check,
                              size: 15,
                              color: h.dark ? const Color(0xFF0A0A0B) : Colors.white,
                            )
                          : null,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      '我已知晓以上风险',
                      style: TextStyle(fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('取消',
                        style: TextStyle(fontSize: 15, color: h.textDim)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: _checked ? h.text : h.border,
                    onPressed: _checked
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: Text(
                      '确认选择',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _checked
                            ? (h.dark
                                ? const Color(0xFF0A0A0B)
                                : Colors.white)
                            : h.textFaint,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '开启后，输入框旁的权限按钮会标示为完全访问，随时可以改回。',
              style: TextStyle(fontSize: 12, height: 1.5, color: h.textFaint),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// 审批模式抽屉（原型 10，2026-10-25 按用户「严格按原型图」重做）。
///
/// 结构：抓手 + 标题「审批模式」+ 副标题「危险操作执行前如何确认」
/// + 三档单选行（圆圈 + 名称 + 原型文案说明，选中深描边 + 实心点）。
/// 点前两档即选即关；点「完全访问」不关本抽屉，直接在其上叠出
/// 二次确认抽屉（原型：「同高度新抽屉覆盖原抽屉」），确认后两层
/// 一起关、取消只关确认层回到三档列表。
///
/// 文案用原型稿，不用 PermissionMode.description（那是设置页
/// 通用说明，语气与信息点都不同）。
Future<void> showApprovalModeSheet(
  BuildContext context, {
  required PermissionMode current,
  required ValueChanged<PermissionMode> onPicked,
}) async {
  final h = Hue.of(context);
  const descriptions = {
    PermissionMode.manual: '删除、执行命令、修改工作区外的文件，每次都先问你。',
    PermissionMode.workspaceAuto: '已授权工作区内的改动自动执行，区外操作仍然询问。',
    PermissionMode.fullAccess: '所有操作直接执行，不再询问。',
  };
  final picked = await showModalBottomSheet<PermissionMode>(
    context: context,
    backgroundColor: h.surfaceAlt,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: SafeArea(
      child: ConstrainedBox(
        // 矮屏上三档卡片放不下时内部滚动，不溢出（单选卡改高后
        // 600 高的测试面溢出过 16px —— 小屏真机同理）
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.88,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: h.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '审批模式',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: h.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '危险操作执行前如何确认',
              style: TextStyle(fontSize: 12, color: h.textFaint),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
            for (final mode in PermissionMode.values) ...[
              _ApprovalModeRow(
                h: h,
                mode: mode,
                description: descriptions[mode]!,
                selected: mode == current,
                onTap: () async {
                  if (mode != PermissionMode.fullAccess) {
                    Navigator.of(sheetCtx).pop(mode);
                    return;
                  }
                  // 完全访问：确认抽屉叠在本抽屉之上（不先关），
                  // 确认 → 两层一起关并回传档位；取消 → 回到本列表。
                  final confirmed =
                      await showFullAccessConfirmSheet(sheetCtx);
                  if (confirmed && sheetCtx.mounted) {
                    Navigator.of(sheetCtx).pop(PermissionMode.fullAccess);
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
                  ],
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    )),
  );
  if (picked != null && picked != current) {
    onPicked(picked);
  }
}

/// 审批档位行（概念图 10 定式）：单选圆圈 + 标题 + 说明的描边卡片，
/// 选中 = 深描边 + 圆圈实心点。不用图标、不用右上对勾（用户对着
/// 真机图一与概念图二拍板改成图二样式）。
class _ApprovalModeRow extends StatelessWidget {
  const _ApprovalModeRow({
    required this.h,
    required this.mode,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final Hue h;
  final PermissionMode mode;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? h.bg : Colors.transparent,
          border: Border.all(
            color: selected ? h.text : h.border,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 单选圆圈：选中 = 深环 + 实心点
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? h.text : h.border,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: h.text,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: h.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.55,
                      color: h.textFaint,
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

/// 运行时审批请求的决定（与 INTERFACE.md N1 的 replyApproval 对齐）。
///
/// `stop` 是前端本地语义：拒绝并停止整个任务 —— 调用方映射为
/// 先回 deny、再停 run，不直接上行后端。
enum ApprovalDecision { deny, once, always, stop }

/// 运行时审批请求弹窗：拒绝 / 允许一次 / 始终允许（可带「停止任务」）。
///
/// 调用方在后端 N1 的 `approval_required` 事件到达时弹出；
/// 用户选「始终允许」后调用方负责写 alwaysAllowedTools。
/// 超时/断线时调用方按 fail-closed 处理（拒绝），本 UI 不擅自决定。
/// [allowStop] 为 true 时多一个「停止任务」入口（返回 [ApprovalDecision.stop]），
/// 解决审批弹窗盖住输入栏停止键、用户物理上停不下来的问题。
Future<ApprovalDecision?> showApprovalRequestSheet(
  BuildContext context, {
  required String tool,
  required String argsPreview,
  String? risk,
  String? note,
  bool workspaceInside = true,
  bool allowStop = false,
}) {
  final h = Hue.of(context);
  final hasArgs = argsPreview.trim().isNotEmpty && argsPreview != '（无参数）';
  return showModalBottomSheet<ApprovalDecision>(
    context: context,
    backgroundColor: h.surfaceAlt,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      allowDrag: false,
      child: _ApprovalRequestBody(
        h: h,
        tool: tool,
        argsPreview: argsPreview,
        hasArgs: hasArgs,
        risk: risk,
        note: note,
        workspaceInside: workspaceInside,
        allowStop: allowStop,
      ),
    ),
  );
}


/// **审批请求抽屉体 · 分步版**（2026-10-26，用户定）：
///
/// 第 1 步 = 批准请求（拒绝 / 允许一次 / 始终允许）；点「始终允许」
/// 不再直接生效，而是**在同一块面板里横滑到第 2 步**二次确认，
/// 面板高度随两步内容平滑变高/变矮（AnimatedSize）。点「返回」
/// 滑回第 1 步；点「确认始终允许」才 pop(ApprovalDecision.always)
/// —— 对外语义与旧版一条不变，只是把长期授权的确认收进同一步
/// 流程，不再是「点完就生效」或另开一层抽屉。
class _ApprovalRequestBody extends StatefulWidget {
  const _ApprovalRequestBody({
    required this.h,
    required this.tool,
    required this.argsPreview,
    required this.hasArgs,
    required this.risk,
    required this.note,
    required this.workspaceInside,
    required this.allowStop,
  });

  final Hue h;
  final String tool;
  final String argsPreview;
  final bool hasArgs;
  final String? risk;
  final String? note;
  final bool workspaceInside;
  final bool allowStop;

  @override
  State<_ApprovalRequestBody> createState() => _ApprovalRequestBodyState();
}

class _ApprovalRequestBodyState extends State<_ApprovalRequestBody> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: h.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final w = c.maxWidth;
                        return ClipRect(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: _step.toDouble()),
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOutCubic,
                            builder: (context, v, _) =>
                                Transform.translate(
                              offset: Offset(-v * w, 0),
                              child: OverflowBox(
                                alignment: Alignment.topLeft,
                                maxWidth: 2 * w,
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(width: w, child: _step0(context)),
                                    SizedBox(width: w, child: _step1(context)),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _step0(BuildContext context) {
    final h = widget.h;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(CupertinoIcons.exclamationmark_shield_fill,
                size: 21, color: h.text),
            const SizedBox(width: 8),
            const Text(
              '需要你的批准',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          widget.tool,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        if (widget.risk != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.risk!,
            style: TextStyle(fontSize: 13.5, height: 1.55, color: h.textDim),
          ),
        ],
        if (widget.note != null &&
            widget.note!.isNotEmpty &&
            !widget.hasArgs) ...[
          const SizedBox(height: 8),
          Text(
            widget.note!,
            style: TextStyle(fontSize: 13, height: 1.5, color: h.textDim),
          ),
        ],
        if (widget.hasArgs) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: h.text,
              borderRadius: BorderRadius.circular(14),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: SingleChildScrollView(
                child: Text(
                  widget.argsPreview,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    fontFamily: kMonoFontFamily,
                    fontFamilyFallback: kMonoFallback,
                    color: h.bg,
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text(
          widget.workspaceInside ? '在工作区内操作' : '超出工作区范围',
          style: TextStyle(fontSize: 12, color: h.textFaint),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _approvalButton(
                  context, h, '拒绝', ApprovalDecision.deny,
                  filled: false),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _approvalButton(
                  context, h, '允许一次', ApprovalDecision.once,
                  filled: false),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 12),
                color: h.text,
                borderRadius: BorderRadius.circular(14),
                // ★ 分步：点它只滑到第 2 步确认，不直接生效
                onPressed: () => setState(() => _step = 1),
                child: Text(
                  '始终允许',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: h.bg,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (widget.allowStop) ...[
          const SizedBox(height: 4),
          Center(
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              onPressed: () =>
                  Navigator.of(context).pop(ApprovalDecision.stop),
              child: Text(
                '停止任务',
                style: TextStyle(
                    fontSize: 14, color: HColors.errorOn(h.dark)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _step1(BuildContext context) {
    final h = widget.h;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(CupertinoIcons.checkmark_shield_fill,
                size: 21, color: h.text),
            const SizedBox(width: 8),
            const Text(
              '始终允许这个工具？',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          widget.tool,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '之后再调用这个工具时会直接执行、不再询问你。随时可在'
          '「通用设置 · 已始终允许的工具」里撤销。',
          style: TextStyle(fontSize: 13.5, height: 1.55, color: h.textDim),
        ),
        if (widget.hasArgs) ...[
          const SizedBox(height: 10),
          Text(
            '本次参数：${widget.argsPreview}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFallback,
              color: h.textFaint,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 12),
                color: h.surface,
                borderRadius: BorderRadius.circular(14),
                onPressed: () => setState(() => _step = 0),
                child: Text(
                  '返回',
                  style: TextStyle(fontSize: 15, color: h.text),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _approvalButton(
                  context, h, '确认始终允许', ApprovalDecision.always,
                  filled: true),
            ),
          ],
        ),
      ],
    );
  }
}

/// 审批抽屉的按钮（灰 / 黑两式，圆角 14 与参数黑块呼应）
Widget _approvalButton(
  BuildContext ctx,
  Hue h,
  String label,
  ApprovalDecision decision, {
  required bool filled,
}) {
  return CupertinoButton(
    padding: const EdgeInsets.symmetric(vertical: 12),
    color: filled ? h.text : h.surface,
    borderRadius: BorderRadius.circular(14),
    onPressed: () => Navigator.of(ctx).pop(decision),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: filled ? FontWeight.w600 : FontWeight.w400,
        color: filled ? h.bg : h.text,
      ),
    ),
  );
}

/// 通用确认抽屉（2026-10-25）：替代居中式 `CupertinoAlertDialog`
/// （用户真机反馈「怎么还有古老弹窗」）。全 App 的确认类交互统一
/// 走底部上拉抽屉：抓手 + 标题 + 说明 + 双按钮；破坏性确认的主
/// 按钮用语义红实心。返回 true = 点了确认；取消/点遮罩/下滑 = false。
Future<bool> showBwConfirmSheet(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String? cancelLabel = '取消',
  bool destructive = false,
}) async {
  final h = Hue.of(context);
  final r = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: h.surfaceAlt,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: h.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            if (message != null && message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(fontSize: 14, height: 1.55, color: h.textDim),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                if (cancelLabel != null) ...[
                  Expanded(
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      onPressed: () => Navigator.of(sheetCtx).pop(false),
                      child: Text(cancelLabel,
                          style: TextStyle(fontSize: 15, color: h.textDim)),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: destructive ? HColors.errorOn(h.dark) : h.text,
                    onPressed: () => Navigator.of(sheetCtx).pop(true),
                    child: Text(
                      confirmLabel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: destructive
                            ? Colors.white
                            : (h.dark
                                ? const Color(0xFF0A0A0B)
                                : Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    )),
  );
  return r == true;
}

/// 通用文本输入抽屉（2026-10-25）：替代带输入框的居中弹窗
/// （重命名会话、抽屉搜索）。返回：保存/回车 → 去空格后的文本；
/// [clearLabel] 非空时多一个清除按钮 → 返回空串；取消/关 = null。
Future<String?> showBwTextInputSheet(
  BuildContext context, {
  required String title,
  String initial = '',
  String placeholder = '',
  String confirmLabel = '保存',
  String? clearLabel,
}) {
  final h = Hue.of(context);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: h.surfaceAlt,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: _BwTextInputSheet(
      h: h,
      title: title,
      initial: initial,
      placeholder: placeholder,
      confirmLabel: confirmLabel,
      clearLabel: clearLabel,
    )),
  );
}

class _BwTextInputSheet extends StatefulWidget {
  const _BwTextInputSheet({
    required this.h,
    required this.title,
    required this.initial,
    required this.placeholder,
    required this.confirmLabel,
    required this.clearLabel,
  });

  final Hue h;
  final String title;
  final String initial;
  final String placeholder;
  final String confirmLabel;
  final String? clearLabel;

  @override
  State<_BwTextInputSheet> createState() => _BwTextInputSheetState();
}

class _BwTextInputSheetState extends State<_BwTextInputSheet> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctl.text.trim());

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: h.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: _ctl,
                autofocus: true,
                placeholder: widget.placeholder,
                style: TextStyle(fontSize: 15, color: h.text),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: h.surface,
                  border: Border.all(color: h.border),
                  borderRadius: BorderRadius.circular(10),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  if (widget.clearLabel != null) ...[
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                      onPressed: () => Navigator.of(context).pop(''),
                      child: Text(widget.clearLabel!,
                          style: TextStyle(fontSize: 15, color: h.textDim)),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('取消',
                          style: TextStyle(fontSize: 15, color: h.textDim)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      color: h.text,
                      onPressed: _submit,
                      child: Text(
                        widget.confirmLabel,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: h.dark
                              ? const Color(0xFF0A0A0B)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
