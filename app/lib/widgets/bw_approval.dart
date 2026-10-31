import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

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
/// **上拉抽屉统一抓手**（2026-10-31 用户定版，T2-4）。
///
/// 规格：36×4、pill 圆角、`h.border` 颜色、顶部/底部间距统一。
/// 由 [BwSheetShell] 默认渲染（`showHandle: true`）—— 各抽屉**不要再自绘**
/// 抓手，否则会出现双抓手（`test/bw_sheet_handle_test.dart` 有防回归断言）。
class BwSheetHandle extends StatelessWidget {
  const BwSheetHandle({super.key});

  /// 抓手尺寸（用户定版，别改）
  static const double width = 36;
  static const double height = 4;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      // 顶部/底部间距统一（此前各抽屉 8/10/12/14 混用）
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: Center(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: h.border,
            borderRadius: BorderRadius.circular(HRadius.pill),
          ),
        ),
      ),
    );
  }
}

class BwSheetShell extends StatefulWidget {
  const BwSheetShell({
    super.key,
    required this.onDismissRequest,
    required this.child,
    this.allowDrag = true,
    this.showHandle = true,
  });

  final VoidCallback onDismissRequest;
  final bool allowDrag;

  /// 是否渲染统一抓手（默认 true）。只有**自己已有更合适头部**的极少数
  /// 抽屉才允许关掉 —— 关之前先确认不是"忘了删本地抓手"。
  final bool showHandle;
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
    // ★ 2026-10-31（T2-4）：统一抓手由壳渲染 —— 各抽屉删掉自绘抓手，
    //   否则双抓手。抓手放进被测量的子树里，自然高度才算得准。
    final measured = KeyedSubtree(
      key: _measureKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showHandle) const BwSheetHandle(),
          widget.child,
        ],
      ),
    );
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

/// 审批弹层被"放弃"后给用户的一句交代（2026-10-29 第 4 条）。
///
/// 关闭审批**就是**一次决定（按拒绝处理），必须说出来 ——
/// 用户报的正是"弹层一关，模型就把这件事拒了，而我根本不知道"。
const String kApprovalDismissedToast = '已按拒绝处理';

/// 审批请求弹窗：拒绝 / 允许一次 / 始终允许（可带「停止任务」）。
///
/// 调用方在后端 N1 的 `approval_required` 事件到达时弹出；
/// 用户选「始终允许」后调用方负责写 alwaysAllowedTools。
/// 超时/断线时调用方按 fail-closed 处理（拒绝），本 UI 不擅自决定。
/// [allowStop] 为 true 时多一个「停止任务」入口（返回 [ApprovalDecision.stop]），
/// 解决审批弹窗盖住输入栏停止键、用户物理上停不下来的问题。
///
/// ★ 2026-10-29（第 4 条 P1「弹层误关」）：**系统返回键不再能静默关掉它** ——
/// 走 [_onApprovalBackPressed] 的二次确认（见该函数注释）。
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
  // 返回键处理要读"当前在第几步"、也要能把它退回第一步 ⇒ 需要拿到 body 的 State。
  final bodyKey = GlobalKey<_ApprovalRequestBodyState>();
  return showModalBottomSheet<ApprovalDecision>(
    context: context,
    backgroundColor: Colors.transparent,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => PopScope(
      // ★ canPop:false ⇒ 系统返回键先经过我们，而不是直接 pop 掉弹层。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_onApprovalBackPressed(sheetCtx, bodyKey));
      },
      child: BwSheetShell(
        onDismissRequest: () => Navigator.of(sheetCtx).pop(),
        allowDrag: false,
        child: _ApprovalRequestBody(
          key: bodyKey,
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
    ),
  );
}

/// 审批弹层的**系统返回键**处理（2026-10-29 第 4 条 P1「弹层误关」）。
///
/// ## 旧实现的洞（用户报的症状）
///
/// `isDismissible:false` / `enableDrag:false` 只挡住了**点遮罩**和**下滑**，
/// **系统返回键**照样把抽屉 pop 掉 ⇒ 调用方拿到 `null` ⇒ `_ => 'deny'`
/// 静默上行拒绝。用户看到的只是"弹层凭空消失"，并不知道自己刚刚拒绝了操作。
///
/// ## 现在的契约
///
/// · 第二步（「始终允许」的二次确认）⇒ **退一步**回第一步（不弹确认、不关层）；
/// · 第一步 ⇒ 弹二次确认「放弃本次审批？」；
///   · 确认 ⇒ 以 **[ApprovalDecision.deny]** 关闭 + 轻提示「已按拒绝处理」；
///   · 取消 ⇒ 留在原地，什么都不改。
///
/// ⚠️ 关掉**绝不**等于允许：这里只回传 deny。
Future<void> _onApprovalBackPressed(
  BuildContext sheetCtx,
  GlobalKey<_ApprovalRequestBodyState> bodyKey,
) async {
  final body = bodyKey.currentState;
  if (body != null && body.step > 0) {
    body.backToStep0();
    return;
  }
  final discard = await showBwConfirmSheet(
    sheetCtx,
    title: '放弃本次审批？',
    message: '关闭后将按「拒绝」处理这次请求，模型不会执行它。',
    confirmLabel: '放弃并拒绝',
    cancelLabel: '继续审批',
    destructive: true,
  );
  if (!discard || !sheetCtx.mounted) return;
  showIosToast(sheetCtx, kApprovalDismissedToast);
  Navigator.of(sheetCtx).pop(ApprovalDecision.deny);
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
    super.key,
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

  /// 当前在第几步（0 = 批准请求，1 = 「始终允许」二次确认）。
  ///
  /// 系统返回键要据此判断"退一步"还是"二次确认关层"（见
  /// [_onApprovalBackPressed]）。
  int get step => _step;

  /// 返回键在第 2 步时**先回第 1 步** —— 不弹确认、更不关层。
  void backToStep0() {
    if (_step != 0) setState(() => _step = 0);
  }

  @override
  Widget build(BuildContext context) {
    // final h = widget.h;  // 2026-10-31: 抓手已由 BwSheetShell 统一渲染，本 build 不再用 h
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
        // ★ 2026-10-29（第 10 条 P3）：说清**范围**与**可撤销**。
        //   用户原话：「『始终允许』到底允许了什么？换个参数还算不算？」
        //   —— 旧文案「之后再调用这个工具时会直接执行」没写参数范围，
        //   容易被读成"只记住这次这条命令"。现在明确"不论参数"。
        Text(
          '之后调用 ${widget.tool}（不论参数）都会直接执行、不再询问你。'
          '可随时在「通用设置 · 已始终允许的工具」里撤销。',
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

/// **ask_user 提问弹层**（2026-10-29 从 chat_screen 抽到 UI 套件）。
///
/// ## 为什么抽出来
///
/// 第 4 条要求"提问弹层不许误关"，而它原先内联在 300KB 的聊天页里 ——
/// 触发它要跑通一整轮 run，所以**没有任何 widget 测试能钉住它的关闭语义**。
/// 抽成独立函数后：遮罩/返回键/键盘重排都能直接在 widget 测试里验。
/// 行为与抽离前**完全一致**（选项式多题、单选自动跳题、「其他…」自填、
/// 跳过回传已答部分、未答如实回传「未回答」）。
///
/// 提问草稿（2026-10-30 P0）：弹层被**收起**时带走，重新呼出时原样还原。
///
/// 为什么需要它：旧实现里 `picked` / `customOn` / `customCtl` 都是弹层局部状态，
/// 一关就销毁 —— 用户选了半题、在「其他…」里打了字，顺手收起再打开，
/// 全没了，只能从头再选一遍。
class AskDraft {
  const AskDraft({
    this.picked = const <String, Set<String>>{},
    this.customOn = const <String>{},
    this.customTexts = const <String, String>{},
    this.page = 0,
  });

  /// 题目 id → 已选 label 集合
  final Map<String, Set<String>> picked;

  /// 哪些题开着「其他…」自填
  final Set<String> customOn;

  /// 「其他…」里用户打的原文（题目 id → 文本）
  final Map<String, String> customTexts;

  /// 当前页（尽量还原用户看到的位置）
  final int page;
}

/// 提问弹层的结果（2026-10-30 P0）。
///
/// · [answers] 非 null ⇒ 用户「提交 / 跳过」：调用方 `replyAsk(answers)`；
/// · [answers] == null ⇒ 用户只是**收起**（返回键 / 下拉关闭）：
///   调用方**不得 replyAsk**，保留 [draft] 以便从常驻气泡重新呼出。
class AskSheetResult {
  const AskSheetResult({required this.answers, required this.draft});

  final Map<String, List<String>>? answers;
  final AskDraft draft;
}

/// 收起提问后的轻提示文案（2026-10-30 P0：不再按"未回答"回传，只是收起）。
const String kAskCollapsedToast = '已暂时收起，可点「回答」继续';

/// 返回：题目 id → 答案列表；`answers == null` = 弹层被**收起**（不提交，带草稿）。
Future<AskSheetResult?> showAskGateSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> questions,
  AskDraft? initial,
}) async {
  final h = Hue.of(context);
  // ★ 逐题作答的状态：题目 id → 已选 label 集合（可从草稿还原）
  final picked = <String, Set<String>>{
    for (final e in (initial?.picked ?? const <String, Set<String>>{}).entries)
      e.key: <String>{...e.value},
  };
  // 还原「其他…」：开着的题目 + 原文
  final customOn = <String>{...(initial?.customOn ?? const <String>{})};
  final customCtl = <String, TextEditingController>{
    for (final id in customOn)
      id: TextEditingController(text: initial?.customTexts[id] ?? ''),
  };

  // ★ 2026-10-23：每题「其他…」的自填状态（用户原话「或者选其他，然后自己填」）。
  //
  // 用 controller（按题目 id）：用户可能选「其他」后翻到下一题、再翻回来 ——
  // 若只把文本存在 map 里，来回翻页时 TextField 会被销毁重建，
  // 结果就是"界面显示空、提交却带着旧文本"（自相矛盾）。
  //
  // ⚠️ 不主动 dispose：弹窗退场动画期间 TextField 还在树上，立刻 dispose
  //   会撞 "A TextEditingController was used after being disposed"；
  //   这里与 `_renameSession` 的既有处理一致（controller 无原生资源，
  //   弹窗 State 卸载后随 GC 回收）。

  /// 合成回传答案（题目 id → 答案列表）：点选的 label + 自填**原文**。
  ///
  /// · 只收非空项；**留空的自填框 = 未作答**（不编答案，该题不进 map）
  /// · 自填的是用户原文，**不是**"其他…"两个字
  Map<String, List<String>> collect() {
    final out = <String, List<String>>{};
    for (final e in picked.entries) {
      final list = e.value.toList();
      if (list.isNotEmpty) out[e.key] = list;
    }
    for (final id in customOn) {
      final raw = (customCtl[id]?.text ?? '').trim();
      if (raw.isEmpty) continue;
      (out[id] ??= <String>[]).add(raw);
    }
    return out;
  }

  var page = initial?.page ?? 0;
  final total = questions.length;
  if (page < 0 || page >= total) page = 0;

  /// 收起时带走的草稿（选中 / 自填原文 / 当前页）
  AskDraft snapshot() => AskDraft(
        picked: {
          for (final e in picked.entries) e.key: <String>{...e.value},
        },
        customOn: {...customOn},
        customTexts: {
          for (final id in customOn) id: customCtl[id]?.text ?? '',
        },
        page: page,
      );

  // ★ 2026-10-25 晚：居中弹窗改上拉抽屉（用户定：所有弹层统一抽屉式，
  //   高度随问题内容自适应）。语义与弹窗时代一条不变：
  //   · 放弃（null）⇒ 空答案（全部未回答，绝不编造）—— 但**必须先确认**（见下）
  //   · 「跳过」= 回传**已答部分**（collect）；单选点选项自动跳题；
  //     「其他…」自填留空 = 该题未作答；controller 跨翻页保留输入。
  //   高度：内容区 Flexible + 滚动 —— 选项少时抽屉贴合内容，
  //   选项多时抽屉长到上限、内部滚动，按钮行始终钉底。
  //
  // ★★ 2026-10-29（第 4 条 P1「弹层误关」）：
  //   · `isDismissible: false` —— **点遮罩不再关掉它**。旧实现点一下外面
  //     就等于"全部未回答"，用户在真机上最容易碰到的正是这一步（想收键盘 /
  //     手滑碰一下，模型就以为用户拒答了）。
  //   · `PopScope(canPop: false)` —— 系统返回键先走 [_onAskBackPressed] 的
  //     二次确认，确认后才以 null 关闭并给一句轻提示。
  final result = await showModalBottomSheet<AskSheetResult>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: false,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_onAskBackPressed(sheetCtx, snapshot));
      },
      child: BwSheetShell(
        // 下拉关闭 = 收起（不提交，保留草稿给常驻气泡重新呼出）
        onDismissRequest: () => Navigator.of(sheetCtx)
            .pop(AskSheetResult(answers: null, draft: snapshot())),
        child: StatefulBuilder(
        builder: (ctx, setDlgState) {
          final q = questions[page];
          final id = (q['id'] as String?) ?? 'q${page + 1}';
          final title = (q['question'] as String?) ?? '';
          final multi = (q['multi'] as bool?) ?? false;
          final options = (q['options'] as List?) ?? const [];
          final sel = picked.putIfAbsent(id, () => <String>{});
          final isLast = page == total - 1;

          void toggle(String label) {
            setDlgState(() {
              if (multi) {
                // 多选：点了就切换；「其他…」可与普通选项**共存**，不动它
                if (!sel.remove(label)) sel.add(label);
              } else {
                // ★ 单选：替换，并**自动跳下一题**（用户要求"答完自动下一个"）
                sel
                  ..clear()
                  ..add(label);
                // 单选里普通选项与「其他…」互斥 —— 选普通项就收起自填
                customOn.remove(id);
                customCtl[id]?.clear();
                if (!isLast) {
                  // 让当前帧先画出来再跳，避免"点完看不到选中态"
                  Future.microtask(() => setDlgState(() => page++));
                }
              }
            });
          }

          /// ★「其他…」：选中后展开自填框。
          ///
          /// · 单选：与普通选项互斥；**不自动跳题**（用户还没填）
          /// · 多选：只切换自己，普通选项保持不变
          void toggleCustom() {
            setDlgState(() {
              if (customOn.remove(id)) {
                // 取消选中 ⇒ 清空已填内容（否则隐藏的文本会被一起提交）
                customCtl[id]?.clear();
              } else {
                customOn.add(id);
                customCtl.putIfAbsent(id, () => TextEditingController());
                if (!multi) sel.clear();
              }
            });
          }

          return SafeArea(
            child: Padding(
              // 键盘弹起时抽屉整体上移（自填框 autofocus 会拉键盘）
              padding: EdgeInsets.fromLTRB(
                20,
                10,
                20,
                16 + MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(CupertinoIcons.question_circle_fill,
                          size: 20, color: h.text),
                      const SizedBox(width: HSpace.sm),
                      const Expanded(
                        child: Text('模型需要你的回答',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      // 进度：多题时必须让用户知道还有几题
                      if (total > 1)
                        Text('${page + 1}/$total',
                            style:
                                TextStyle(fontSize: 12, color: h.textFaint)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 题目 + 选项：随内容长高，超限内部滚动
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: TextStyle(
                                  fontSize: 15, height: 1.5, color: h.text)),
                          const SizedBox(height: HSpace.xs),
                          Text(
                            multi
                                ? '可多选（也可选「其他」自己填）'
                                : '单选（也可选「其他」自己填）',
                            style: TextStyle(
                                fontSize: 11.5, color: h.textFaint),
                          ),
                          const SizedBox(height: HSpace.md),
                          // ★ 选项：编号 + label + description，整块可点
                          for (var i = 0; i < options.length; i++)
                            _askOptionTile(
                              h: h,
                              index: i + 1,
                              label: (options[i] as Map)['label'] as String? ??
                                  '',
                              description: (options[i]
                                      as Map)['description'] as String? ??
                                  '',
                              selected: sel.contains(
                                  (options[i] as Map)['label'] as String? ??
                                      ''),
                              multi: multi,
                              onTap: () => toggle(
                                  (options[i] as Map)['label'] as String? ??
                                      ''),
                            ),
                          // ★ 每题末尾固定一个「其他…」
                          _askOptionTile(
                            h: h,
                            index: options.length + 1,
                            label: '其他…',
                            description: '自己填写',
                            selected: customOn.contains(id),
                            multi: multi,
                            onTap: toggleCustom,
                          ),
                          // 选中「其他…」才展开自填框；**留空 = 该题未作答**
                          if (customOn.contains(id))
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: HSpace.sm),
                              child: CupertinoTextField(
                                // controller 跨"上一题/下一题"保留用户输入
                                controller: customCtl.putIfAbsent(
                                    id, () => TextEditingController()),
                                autofocus: true,
                                placeholder: '在这里填写你的回答…',
                                minLines: 1,
                                maxLines: 3,
                                padding:
                                    const EdgeInsets.all(HSpace.sm + 2),
                                style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.4,
                                    color: h.text),
                                decoration: BoxDecoration(
                                  color: h.surfaceAlt,
                                  borderRadius:
                                      BorderRadius.circular(HRadius.md),
                                  border: Border.all(color: h.border),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 底部按钮行：跳过在左；翻页 / 提交在右（提交 = 黑钮）
                  Row(
                    children: [
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        color: h.surface,
                        borderRadius: BorderRadius.circular(12),
                        // 跳过 = 已答的仍然回传（别浪费用户已做的选择）
                        onPressed: () => Navigator.of(sheetCtx)
                            .pop(AskSheetResult(
                                answers: collect(), draft: snapshot())),
                        child: Text('跳过',
                            style: TextStyle(fontSize: 14.5, color: h.text)),
                      ),
                      const Spacer(),
                      if (page > 0) ...[
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          color: h.surface,
                          borderRadius: BorderRadius.circular(12),
                          onPressed: () => setDlgState(() => page--),
                          child: Text('上一题',
                              style:
                                  TextStyle(fontSize: 14.5, color: h.text)),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (!isLast)
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          color: h.text,
                          borderRadius: BorderRadius.circular(12),
                          onPressed: () => setDlgState(() => page++),
                          child: Text('下一题',
                              style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                  color: h.bg)),
                        ),
                      if (isLast)
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          color: h.text,
                          borderRadius: BorderRadius.circular(12),
                          onPressed: () => Navigator.of(sheetCtx)
                              .pop(AskSheetResult(
                                  answers: collect(), draft: snapshot())),
                          child: Text('提交',
                              style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                  color: h.bg)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
        ),
      ),
    ),
  );
  return result;
}

/// 提问弹层的**系统返回键**处理（2026-10-29 第 4 条 P1 / 2026-10-30 P0）。
///
/// 旧实现：返回键直接把抽屉 pop 掉 ⇒ 调用方拿到 null ⇒ `replyAsk(const {})`
/// ⇒ 模型被告知"用户没有回答"—— 而用户只是想退回去看一眼。
///
/// 现在：二次确认「暂时收起回答？」；
/// · 确认 ⇒ **不提交**，以 `answers: null` + 当前草稿关闭，调用方保留气泡；
/// · 取消 ⇒ 留在原地，已答的题一个都不丢。
Future<void> _onAskBackPressed(
  BuildContext sheetCtx,
  AskDraft Function() snapshot,
) async {
  final collapse = await showBwConfirmSheet(
    sheetCtx,
    title: '暂时收起回答？',
    message: '收起不会提交；问题会保留在输入框上方，可随时点「回答」继续。',
    confirmLabel: '收起问题',
    cancelLabel: '继续回答',
  );
  if (!collapse || !sheetCtx.mounted) return;
  Navigator.of(sheetCtx)
      .pop(AskSheetResult(answers: null, draft: snapshot()));
}

/// 提问弹层被"收起"后的轻提示（2026-10-30 P0）—— 由聊天页在关闭后弹出。

/// 一条可点击的 ask 选项（编号 + 标题 + 说明 + 选中态）。
///
/// 抽成独立 widget 是为了让"选中态"的视觉在同一处定义 ——
/// 单选/多选只是圆/方的区别，其余一致。
Widget _askOptionTile({
  required Hue h,
  required int index,
  required String label,
  required String description,
  required bool selected,
  required bool multi,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: HSpace.sm),
    // ★★ 必须包 `Material`（2026-10-21 真机 bug：选项点不动）★★
    //
    // ## 现象
    //
    // 弹窗能正常显示，「下一题」「跳过」也都能点 —— **唯独选项卡片点不动**：
    // 点下去没有选中态、也不会自动跳下一题。用户会以为 App 卡死了。
    //
    // ## 根因
    //
    // `InkWell` 的水波纹与**命中测试**都依赖祖先 `Material`。
    // 这里原来是 `Padding → InkWell → Container` —— **没有 Material 祖先**
    //（`AlertDialog` 的 content 在 `SingleChildScrollView` 里，
    //  那层不提供 Material）。于是 `InkWell` 的 `onTap` **根本不触发**，
    //  而旁边的 `TextButton` 自带 Material ⇒ 能点。
    //  这正是"同一个弹窗里有的能点、有的不能点"的原因。
    //
    // 修法：`Material(transparent) → InkWell → 内容`。
    // 用 `type: MaterialType.transparency` 是为了不改变既有的 `Container`
    // 背景色/边框（外观零变化）。
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HSpace.md, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? h.accent.withValues(alpha: 0.12) : h.surface,
            borderRadius: BorderRadius.circular(HRadius.md),
            border: Border.all(
              color: selected ? h.accent : h.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 序号（1/2/3/4 —— 用户要求"一般是 1、2、3、4 等等几个选项"）
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? h.accent : h.surfaceAlt,
                shape: multi ? BoxShape.rectangle : BoxShape.circle,
                borderRadius:
                    multi ? BorderRadius.circular(HRadius.sm) : null,
              ),
              child: Text(
                '$index',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? (h.dark ? const Color(0xFF1A0E08) : Colors.white)
                      : h.textDim,
                ),
              ),
            ),
            const SizedBox(width: HSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 13.5,
                          height: 1.3,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: h.text)),
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(description,
                          style: TextStyle(
                              fontSize: 11.5,
                              height: 1.35,
                              color: h.textFaint)),
                    ),
                ],
              ),
            ),
            if (selected)
              Icon(AppIcons.check, size: 16, color: h.accent),
          ],
        ),
        ),
      ),
    ),
  );
}
