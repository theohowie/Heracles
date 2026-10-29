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
  final GlobalKey _measureKey = GlobalKey();

  /// 内容的自然高度（实测）。测得前为 null（不约束、按自然渲染）。
  double? _natural;

  /// 当前抽屉高度（px）。表面由本壳自带并**恒铺满这个高度** ——
  /// 上拉只是把高度加大，下方永远是抽屉自己的白色表面，
  /// 不会露出底下的页面（2026-10-27 图三，用户原话「下面直接透明了」）。
  double _extent = 0;

  /// 当前停在"自然高度"档（内容增高时跟着长）。
  bool _atNatural = true;
  bool _dragging = false;
  bool _dismissing = false;
  double _dragExtent = 0;
  double _availH = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController.unbounded(vsync: this)
      ..addListener(() {
        if (mounted) setState(() => _extent = _anim.value);
      });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// 测内容自然高度（只在静止时采信：拖动/动画中内容的高度会被
  /// 当前 extent 影响，量出来是假的）。
  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dragging || _anim.isAnimating) return;
      final box =
          _measureKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final hgt = box.size.height;
      if (hgt <= 0) return;
      final old = _natural;
      if (old != null && (hgt - old).abs() < 0.5) return;
      setState(() {
        _natural = hgt;
        if (_atNatural || _extent <= 0) {
          _extent = hgt;
          _atNatural = true;
        }
      });
    });
  }

  /// 停靠点：自然高度 + 屏高 66% / 80%（只收比自然高度大的，
  /// 矮抽屉拉到 66% 就够、不会有空档点）。
  List<double> _detents() {
    final n = _natural ?? 0;
    final out = <double>[n];
    for (final f in const [0.66, 0.80]) {
      final d = _availH * f;
      if (d > n + 8 && d <= _availH * 0.98) out.add(d);
    }
    return out;
  }

  void _snapTo(double target, double velocity) {
    _anim
        .animateWith(SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 320, damping: 27),
          _extent,
          target,
          velocity,
        ))
        .whenComplete(() {
      if (mounted) {
        setState(() => _atNatural = _natural != null && target == _natural);
      }
    });
  }

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    _anim
        .animateTo(0,
            duration: const Duration(milliseconds: 190), curve: Curves.easeIn)
        .whenComplete(() {
      if (mounted) widget.onDismissRequest();
    });
  }

  void _onDragEnd(double velocity) {
    _dragging = false;
    final n = _natural ?? _extent;
    final detents = _detents();
    if (velocity > 620) {
      // 快速下滑：在高档先回自然档（误触保护），已在自然档就关闭
      if (_extent > n + 4 && detents.length > 1) {
        _snapTo(n, velocity);
      } else {
        _dismiss();
      }
      return;
    }
    if (_extent < n - 110) {
      _dismiss();
      return;
    }
    if (velocity < -620) {
      // 向上甩 → 进上一档
      var target = detents.last;
      for (final d in detents) {
        if (d > _extent + 4) {
          target = d;
          break;
        }
      }
      _snapTo(target, velocity);
      return;
    }
    // 就近停靠
    var target = detents.first;
    var best = double.infinity;
    for (final d in detents) {
      final diff = (d - _extent).abs();
      if (diff < best) {
        best = diff;
        target = d;
      }
    }
    _snapTo(target, velocity);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    // ★ 表面必须由本壳自带（2026-10-27 真机 bug「上拉就字动」）：
    //   表面（色+圆角+裁剪）与内容是同一个盒子，要动一起动；
    //   调用点 modal 已改透明底 + 直角 shape 配合。
    //
    // ★ 高度模型（2026-10-27 图三）：盒子高度 = _extent，表面铺满它；
    //   内容按自然高度摆在顶部（OverflowBox 允许超出、由盒子裁剪）——
    //   上拉 = 盒子变高（停靠 66%/80%），下方始终是白色表面。
    final h = Hue.of(context);
    final measured = KeyedSubtree(key: _measureKey, child: widget.child);
    final Widget body = LayoutBuilder(
      builder: (context, constraints) {
        _availH = constraints.maxHeight;
        final height = (_natural == null || _extent <= 0)
            ? null
            : _extent.clamp(0.0, _availH);
        final surface = Container(
          decoration: BoxDecoration(
            color: h.surfaceAlt,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          clipBehavior: Clip.antiAlias,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: double.infinity,
            child: measured,
          ),
        );
        if (height == null) return surface;
        return SizedBox(height: height, child: surface);
      },
    );
    if (!widget.allowDrag) return body;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) {
        _anim.stop();
        _dragging = true;
        _dragExtent = _extent;
      },
      onVerticalDragUpdate: (d) {
        _dragExtent = (_dragExtent - d.delta.dy)
            .clamp(0.0, _availH > 0 ? _availH : double.infinity);
        setState(() {
          _extent = _dragExtent;
          _atNatural = _natural != null && (_extent - _natural!).abs() < 1;
        });
      },
      onVerticalDragEnd: (d) => _onDragEnd(d.primaryVelocity ?? 0),
      onVerticalDragCancel: () {
        _dragging = false;
        _snapTo(_natural ?? _extent, 0);
      },
      child: body,
    );
  }
}

Future<bool> showFullAccessConfirmSheet(BuildContext context) async {
  final h = Hue.of(context);
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    // 安全语义不变：必须显式选择，点遮罩/下滑都不算确认
    isDismissible: false,
    enableDrag: false,
    // 矮屏（小屏/横屏/分屏）下内容可滚，不溢出
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
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
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
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
/// **通用单选抽屉**（2026-10-26）：与审批模式同一套单选卡行，
/// 给短列表选择器用（替代 CupertinoActionSheet 的旧弹窗 ——
/// 用户报「添加提供商 · API 协议」选择器还是古老 UI）。
Future<T?> showBwRadioSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<T> options,
  required T current,
  required String Function(T) labelOf,
}) async {
  final h = Hue.of(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: SafeArea(
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
              Text(title,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: h.text)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(fontSize: 12, color: h.textFaint)),
              ],
              const SizedBox(height: 12),
              for (final o in options) ...[
                BwOptionCard(
                  h: h,
                  selected: o == current,
                  title: labelOf(o),
                  onTap: () => Navigator.of(sheetCtx).pop(o),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// **抽屉边框选项卡**（2026-10-29 用户定版，全 App 唯一单选形态）：
/// 圆角 18、边框 2、内距 16×14、左侧单选圆圈 22（选中实心点）；
/// 未选中 = 灰边框（h.border）+ 透明底，选中 = 主文本色边框
/// （浅色下黑边框）+ 卡面转页面底色。审批模式（图一）就是这张卡，
/// 其余抽屉里的单选（模型、分支、分组/排序/筛选、通用单选抽屉）
/// 一律用它，不再各画各的。
class BwOptionCard extends StatelessWidget {
  const BwOptionCard({
    super.key,
    required this.h,
    required this.selected,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  final Hue h;
  final bool selected;
  final String title;
  final String? subtitle;
  final Widget? trailing;
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
          crossAxisAlignment: subtitle != null
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Container(
              width: 22,
              height: 22,
              margin: EdgeInsets.only(top: subtitle != null ? 1 : 0),
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: h.text,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: h.textFaint),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// **抽屉边框动作卡**（2026-10-29 用户定版）：动作类行（附件来源、
/// 添加工作区、会话/工作区菜单）不用单选圆圈，同样收进边框卡 ——
/// 平时灰边框（h.border），**按下时边框变主文本色**（浅色下黑边框），
/// 松开恢复。[danger] 时图标与文字语义红、按下边框也走红色。
class BwActionCard extends StatefulWidget {
  const BwActionCard({
    super.key,
    required this.h,
    required this.icon,
    required this.label,
    this.subtitle,
    this.iconColor,
    this.danger = false,
    required this.onTap,
  });

  final Hue h;
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? iconColor;
  final bool danger;
  final VoidCallback onTap;

  @override
  State<BwActionCard> createState() => _BwActionCardState();
}

class _BwActionCardState extends State<BwActionCard> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    final err = HColors.errorOn(h.dark);
    final accent = widget.danger ? err : h.text;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          border: Border.all(
            color: _pressed ? accent : h.border,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Icon(
              widget.icon,
              size: 20,
              color:
                  widget.danger ? err : (widget.iconColor ?? h.textDim),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 15,
                      color: widget.danger ? err : h.text,
                    ),
                  ),
                  if (widget.subtitle != null)
                    Text(
                      widget.subtitle!,
                      style: TextStyle(fontSize: 11.5, color: h.textFaint),
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
    backgroundColor: Colors.transparent,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
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
                    // ★ 2026-10-27 真机 bug「审批抽屉整片空白」：
                    //   旧实现用 LayoutBuilder + OverflowBox 把两步横排
                    //   再位移 —— OverflowBox 在滚动视图里拿到**无界高**，
                    //   布局直接断言失败，release 下整片内容不渲染、
                    //   只剩一张空抽屉。改 AnimatedSwitcher 横滑：
                    //   第 2 步从右滑入、返回时第 1 步从左滑入，
                    //   布局始终有界。回归测试 approval_sheet_render_test。
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeInOutCubic,
                      switchOutCurve: Curves.easeInOutCubic,
                      layoutBuilder: (currentChild, previousChildren) =>
                          Stack(
                        alignment: Alignment.topCenter,
                        children: <Widget>[
                          ...previousChildren,
                          ?currentChild,
                        ],
                      ),
                      transitionBuilder: (child, animation) {
                        final fromRight = child.key == const ValueKey<int>(1);
                        return ClipRect(
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: Offset(fromRight ? 1 : -1, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey<int>(_step),
                        child:
                            _step == 0 ? _step0(context) : _step1(context),
                      ),
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
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(),
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
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
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
