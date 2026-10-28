/// Cupertino 设计语言基础件（2026-10-22，用户要求："设计语言改成 cupertino，不要 material"）。
///
/// ## 这个文件是什么
///
/// 全 App 从 Material 视觉语言迁到 iOS 风格的**共享地基**：
/// 图标对照表、无波纹点击、iOS 弹窗 / 吐司 / 按钮 / 开关。
/// 各屏的迁移只引用这里的常量与包装件，**不在各文件里散写映射** ——
/// 两处真相迟早漂移（本仓库的老规矩）。
///
/// ## 迁移原则（改任何界面都按这五条）
///
/// 1. **图标**：`Icons.xxx` ⇒ [AppIcons] 里对照的 `CupertinoIcons.xxx`（见下表）。
///    表里没有的图标，从 `package:flutter/cupertino.dart` 直接选语义相同的那个，
///    并把新条目**补进 [AppIcons]**（保持唯一映射源）。
/// 2. **点击反馈**：iOS 没有波纹。全局主题已把 `splashFactory` 设为
///    [kNoSplash]（`app_theme.dart`），`InkWell` 可以保留不动；
///    需要"按下变暗"的地方用 [IosTap]。
/// 3. **弹层**：确认与文本输入一律底部上拉抽屉（`bw_approval.dart` 的
///    `showBwConfirmSheet` / `showBwTextInputSheet`）；居中弹窗已退役。
/// 4. **消息条**：`SnackBar` ⇒ [showIosToast]（底部毛玻璃悬浮胶囊，
///    2026-10-28 用户在四案预览中选定 D 案；旧顶部灰胶囊已退役）。
/// 5. **表单件**：`FilledButton` ⇒ [IosButton.filled]；`Switch` ⇒ `ElasticSwitch`（弹性开关，`elastic_switch.dart`）；
///    `CircularProgressIndicator` ⇒ `CupertinoActivityIndicator`；
///    `TextField` ⇒ `CupertinoTextField`；`Slider` ⇒ `CupertinoSlider`；
///    `PopupMenuButton` ⇒ `showCupertinoMenu`；`ListTile` ⇒ `CupertinoListTile`。
///
/// ## 图标对照表（Material → Cupertino）
///
/// | 语义 | 旧（Material） | 新（Cupertino） |
/// |---|---|---|
/// | 完成/成功 | `check_rounded` | `CupertinoIcons.check` |
/// | 失败/错误 | `error_outline_rounded` | `exclamationmark_circle` |
/// | 展开（下箭头） | `keyboard_arrow_down_rounded` | `chevron_down` |
/// | 收起/右箭头 | `chevron_right_rounded` | `chevron_forward` |
/// | 上箭头 | `keyboard_arrow_up_rounded` | `chevron_up` |
/// | 复制 | `copy_rounded` | `doc_on_doc` |
/// | 点赞 | `thumb_up_alt_rounded/outlined` | `hand_thumbsup_fill/_solid` |
/// | 点踩 | `thumb_down_alt_rounded/outlined` | `hand_thumbsdown_fill/_solid` |
/// | 分支 | `call_split_rounded` | `arrowshape_turn_up_right` |
/// | 用量/统计 | `data_usage_rounded` | `chart_bar` |
/// | 刷新 | `refresh` | `arrow_clockwise` |
/// | 菜单 | `menu` | `line_horizontal_3` |
/// | 关闭 | `close` | `xmark` |
/// | 加号 | `add` | `add` |
/// | 发送（上箭头） | `arrow_upward` | `arrow_up` |
/// | 停止 | `stop_rounded` | `stop_fill` |
/// | 代码 | `code_rounded` | `chevron_left_slash_chevron_right` |
/// | 思考/分析 | `psychology_alt` | `lightbulb` |
/// | 盾牌/权限 | `shield_outlined` | `lock_shield` |
/// | 信息 | `info_outline` | `info_circle` |
/// | 警告 | `warning_amber` | `exclamationmark_triangle` |
/// | 星（加精） | `star` | `star_fill` |
/// | 文件夹 | `folder_outlined` | `folder` |
/// | 文档 | `description_outlined` | `doc_text` |
/// | 图片 | `image_outlined` | `photo` |
/// | 搜索 | `search` | `search` |
/// | 设置 | `settings_outlined` | `gearshape_2` |
/// | 垃圾桶 | `delete_outline` | `trash` |
/// | 编辑 | `edit_outlined` | `pencil` |
/// | 返回 | `arrow_back` | `left_chevron` / `back` |
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';

import 'pressable.dart';
import 'package:flutter/material.dart'
    show NoSplash, SnackBar, ScaffoldMessenger, Theme, Widget, BuildContext, Color;

// ============================================================================
// 图标对照（唯一映射源）
// ============================================================================

/// Material → Cupertino 的图标对照。**所有界面只从这里取图标**，
/// 不要再写 `Icons.*`（那是 Material 设计语言的最后痕迹）。
///
/// ⚠️ 名字都对着 SDK 的 `cupertino/icons.dart`（1322 个）逐个核过 ——
/// `check`/`terminal`/`cpu`/`download`/`upload`/`gearshape`/`send`/`wave`
/// 这些**不存在**（SF Symbols 用 `checkmark`/`command`/`speedometer`/…），
/// 新增条目时先 `Select-String` 核名字，别猜。
abstract final class AppIcons {
  // ---- 状态 ----
  static const check = CupertinoIcons.checkmark;
  static const error = CupertinoIcons.exclamationmark_circle;
  static const warning = CupertinoIcons.exclamationmark_triangle;
  static const info = CupertinoIcons.info_circle;

  // ---- 折叠箭头（工具行 / 步骤行的命脉）----
  static const chevronDown = CupertinoIcons.chevron_down;
  static const chevronRight = CupertinoIcons.chevron_forward;
  static const chevronUp = CupertinoIcons.chevron_up;

  // ---- 回答操作行 ----
  static const copy = CupertinoIcons.doc_on_doc;
  static const thumbUp = CupertinoIcons.hand_thumbsup_fill;
  static const thumbUpOutline = CupertinoIcons.hand_thumbsup;
  static const thumbDown = CupertinoIcons.hand_thumbsdown_fill;
  static const thumbDownOutline = CupertinoIcons.hand_thumbsdown;
  // （branch 曾用 arrowshape_turn_up_right —— 与分享箭头分不清，
  //   2026-10-27 退役；分支图标改用 brand_icons 的 GitBranchIcon）
  static const usage = CupertinoIcons.chart_bar;

  // ---- 顶栏 / 导航 ----
  static const refresh = CupertinoIcons.arrow_clockwise;
  static const menu = CupertinoIcons.line_horizontal_3;
  static const close = CupertinoIcons.xmark;
  static const back = CupertinoIcons.back;

  // ---- 输入区 ----
  static const add = CupertinoIcons.add;
  static const send = CupertinoIcons.arrow_up;
  static const mic = CupertinoIcons.mic_solid;
  static const stop = CupertinoIcons.stop_fill;
  static const attach = CupertinoIcons.paperclip;
  static const camera = CupertinoIcons.camera;

  // ---- 内容类型 ----
  static const code = CupertinoIcons.chevron_left_slash_chevron_right;
  static const think = CupertinoIcons.lightbulb;
  static const shield = CupertinoIcons.lock_shield;
  static const star = CupertinoIcons.star_fill;
  static const folder = CupertinoIcons.folder;
  static const file = CupertinoIcons.doc_text;
  static const image = CupertinoIcons.photo;
  static const search = CupertinoIcons.search;
  static const settings = CupertinoIcons.gear;
  static const trash = CupertinoIcons.trash;
  static const edit = CupertinoIcons.pencil;
  static const share = CupertinoIcons.share;
  static const clock = CupertinoIcons.clock;
  static const bolt = CupertinoIcons.bolt;
  static const terminal = CupertinoIcons.command;
  static const globe = CupertinoIcons.globe;
  static const wifi = CupertinoIcons.wifi;
  static const battery = CupertinoIcons.battery_100;
  static const cpu = CupertinoIcons.speedometer;
  static const eye = CupertinoIcons.eye;
  static const play = CupertinoIcons.play;
  static const pause = CupertinoIcons.pause;
  static const download = CupertinoIcons.arrow_down_circle;
  static const upload = CupertinoIcons.arrow_up_circle;
  static const more = CupertinoIcons.ellipsis;
  static const moreCompact = CupertinoIcons.ellipsis_circle;
}

// ============================================================================
// 点击与反馈
// ============================================================================

/// 全局主题用的无波纹工厂 —— iOS 上按下**没有水波纹**。
/// `app_theme.dart` 里 `splashFactory: kNoSplash` 一行，
/// 让现存 33 处 `InkWell` 立刻失去 Material 波纹（不必逐个换控件）。
const kNoSplash = NoSplash.splashFactory;

/// iOS 风格的点按：**按下整体降到 0.6 透明度**，抬手恢复。
///
/// 用在"需要明确按下反馈"的地方（列表行、卡片按钮）；
/// 普通 `InkWell`（已被 [kNoSplash] 去波纹）不必替换。
class IosTap extends StatefulWidget {
  const IosTap({required this.onTap, required this.child, super.key});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<IosTap> createState() => _IosTapState();
}

class _IosTapState extends State<IosTap> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _down ? 0.6 : 1.0,
        child: widget.child,
      ),
    );
  }
}

// ============================================================================
// 弹窗 / 吐司 / 按钮
// ============================================================================

/// 居中式确认弹窗（旧 `showIosDialog` / `CupertinoAlertDialog`）已退役
/// （2026-10-25，用户真机反馈「古老弹窗」）：确认与文本输入统一走
/// 底部上拉抽屉 —— `widgets/bw_approval.dart` 的
/// `showBwConfirmSheet` / `showBwTextInputSheet`，不要再引入居中弹窗。

/// 轻提示（替换 `ScaffoldMessenger.showSnackBar`）。
///
/// **毛玻璃悬浮胶囊**（2026-10-28 用户在四案 HTML 预览里选定
/// D 案，取代旧的 iOS 风顶部深灰胶囊——用户原话：那样式「很不
/// 符合现在的设计语言」）：底部居中悬浮，半透填充 + 背景模糊 +
/// 细描边（深色 rgba(28,28,30,.72)/白描边、浅色 rgba(250,250,252,.78)/
/// 黑描边，与已定的毛玻璃悬浮层语言一致）；淡入 + 轻微上浮，
/// 2.2 秒后淡出，点击立即关闭。不阻塞、不打断输入。
///
/// 位置：无键盘时距底 = 安全区 + 170（正好让开聊天页输入单元）；
/// 键盘弹起时贴键盘上方 16，免得被键盘盖住。[icon] 可选
/// （如麦克风未接入提示带麦克风图标），不传就是纯文字。
void showIosToast(BuildContext context, String message, {IconData? icon}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) {
    // 没有 Overlay（理论上不会发生）⇒ 退回 SnackBar，**绝不静默丢消息**
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
    return;
  }
  final dark = Theme.of(context).brightness == Brightness.dark;
  final mq = MediaQuery.of(context);
  final bottom = mq.viewInsets.bottom > 0
      ? mq.viewInsets.bottom + 16
      : mq.viewPadding.bottom + 170;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _ToastCapsule(
      message: message,
      icon: icon,
      dark: dark,
      bottom: bottom,
      onDismiss: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

/// 毛玻璃轻提示本体：进场（淡入+上浮）→ 停留 → 淡出，全程可点关。
class _ToastCapsule extends StatefulWidget {
  const _ToastCapsule({
    required this.message,
    required this.icon,
    required this.dark,
    required this.bottom,
    required this.onDismiss,
  });

  final String message;
  final IconData? icon;
  final bool dark;
  final double bottom;
  final VoidCallback onDismiss;

  @override
  State<_ToastCapsule> createState() => _ToastCapsuleState();
}

class _ToastCapsuleState extends State<_ToastCapsule>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.35),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
    Future<void>.delayed(const Duration(milliseconds: 2200), _dismiss);
  }

  void _dismiss() {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _ctrl.reverse().whenComplete(() {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark;
    final fg = dark ? const Color(0xFFFFFFFF) : const Color(0xFF111214);
    return Positioned(
      left: 40,
      right: 40,
      bottom: widget.bottom,
      child: FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: _slide,
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x4D000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xB81C1C1E)
                            : const Color(0xC7FAFAFC),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: dark
                              ? const Color(0x24FFFFFF)
                              : const Color(0x12000000),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, size: 16, color: fg),
                            const SizedBox(width: 8),
                          ],
                          Flexible(
                            child: Text(
                              widget.message,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: fg,
                                // ★ 必须显式 none：本提示浮在 Overlay
                                // 里、没有 Material 祖先，框架的兜底
                                // 文案样式带黄色双下划线 —— 用户真机
                                // 实报「下面还有黄色的线」。
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// iOS 主按钮（替换 `FilledButton` / `ElevatedButton`）。
///
/// 全圆角胶囊 + 实心主色，正是 iOS 的 prominent action。
///
/// ## `busy` 与 `leading`（2026-10-22，设置页迁移时补）
///
/// iOS 的按钮在忙态就是**转圈替换文字**（系统"正在检查…"按钮的形态）。
/// 旧代码三处按钮（Shizuku 授权中 / 编码层自检中 / 测试连接中）内联了
/// `CircularProgressIndicator`，`FilledButton.icon` 还带前置图标 ——
/// 没有这两个槽位就会把"按下去了没有"的反馈整个丢掉。
class IosButton extends StatelessWidget {
  const IosButton({
    required this.label,
    this.onPressed,
    this.filled = true,
    this.color,
    this.dense = false,
    this.busy = false,
    this.leading,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? color;
  final bool dense;

  /// 忙态：文字换成小号转圈，且**不可再点**（与旧行为一致）。
  final bool busy;

  /// 文字前的小图标（`FilledButton.icon` 的对应物）。
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = CupertinoTheme.of(context).primaryColor;
    // 填充按钮的文字色按底色明度取：深色主题下 accent 是近白色，
    // 旧版文字恒白 → 白底白字看不见（2026-10-26 真机报：
    // 抽屉/引导页「选择文件夹」）。浅底用黑字、深底用白字。
    final fillColor = color ?? scheme;
    final onFill = fillColor.computeLuminance() > 0.5
        ? CupertinoColors.black
        : CupertinoColors.white;
    // 全局按压反馈（2026-10-26 用户定）：0.96 微缩 + 内阴影 + 回弹
    return Pressable(
      borderRadius: BorderRadius.circular(dense ? 15 : 19),
      enabled: !busy && onPressed != null,
      child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: busy ? null : onPressed,
      child: Container(
        height: dense ? 30 : 38,
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: dense ? 14 : 20),
        decoration: BoxDecoration(
          color: filled
              ? (onPressed == null || busy
                  ? fillColor.withValues(alpha: 0.3)
                  : fillColor)
              : null,
          borderRadius: BorderRadius.circular(dense ? 15 : 19),
          border: filled ? null : Border.all(color: (color ?? scheme)),
        ),
        child: busy
            ? CupertinoActivityIndicator(
                radius: 7,
                color: filled ? onFill : fillColor,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: 6),
                  ],
                  // ★ 长文案必须可缩：裸 Text 在 MainAxisSize.min 的
                  //   Row 里按固有宽度测量，超宽直接溢出报错（真机
                  //   实测「重新向 Shizuku 申请授权…」溢出 1.3px）。
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense ? 13 : 15,
                        fontWeight: FontWeight.w600,
                        color: filled ? onFill : fillColor,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    ),
    );
  }
}
