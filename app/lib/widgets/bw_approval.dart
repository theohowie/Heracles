import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
    builder: (sheetCtx) => _FullAccessConfirmSheet(h: h),
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

/// 审批模式三档的图标（与 input_bar 的 PermissionModeIcon 同一套
/// Cupertino 盾族；那边是 extension，这边抽屉独立成文件，用函数）。
IconData permissionModeIcon(PermissionMode mode) => switch (mode) {
      PermissionMode.manual => CupertinoIcons.checkmark_shield,
      PermissionMode.workspaceAuto => CupertinoIcons.lock_shield,
      PermissionMode.fullAccess => CupertinoIcons.exclamationmark_shield,
    };

/// 审批模式抽屉（原型 10，2026-10-25 按用户「严格按原型图」重做）。
///
/// 结构：抓手 + 标题「审批模式」+ 副标题「危险操作执行前如何确认」
/// + 三档自定义行（图标 + 名称 + 原型文案说明，当前档高亮带对勾）。
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
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => SafeArea(
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
  );
  if (picked != null && picked != current) {
    onPicked(picked);
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
    final warn = mode == PermissionMode.fullAccess;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? h.surface : Colors.transparent,
          border: Border.all(color: h.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              permissionModeIcon(mode),
              size: 23,
              color: warn ? HColors.warnOn(h.dark) : h.textDim,
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
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: h.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: h.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(CupertinoIcons.checkmark, size: 18, color: h.text),
            ],
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
  return showModalBottomSheet<ApprovalDecision>(
    context: context,
    backgroundColor: h.surfaceAlt,
    isDismissible: false,
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => SafeArea(
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
              '需要你的批准',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              tool,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            // 参数全文不截断（审批的意义是看清再签字）；过长时内部滚动
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.35,
              ),
              child: SingleChildScrollView(
                child: Text(
                  argsPreview,
                  style: TextStyle(
                      fontSize: 13.5, height: 1.6, color: h.textDim),
                ),
              ),
            ),
            if (risk != null) ...[
              const SizedBox(height: 8),
              Text(
                risk,
                style: TextStyle(
                    fontSize: 13.5, color: HColors.warnOn(h.dark)),
              ),
            ],
            if (note != null && note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                note,
                style: TextStyle(fontSize: 13, height: 1.5, color: h.textDim),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              workspaceInside ? '在工作区内操作' : '超出工作区范围',
              style: TextStyle(fontSize: 12, color: h.textFaint),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: () => Navigator.of(sheetCtx)
                        .pop(ApprovalDecision.deny),
                    child: Text('拒绝',
                        style: TextStyle(fontSize: 15, color: h.textDim)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    color: h.text,
                    onPressed: () => Navigator.of(sheetCtx)
                        .pop(ApprovalDecision.once),
                    child: Text(
                      '允许一次',
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
                const SizedBox(width: 8),
                Expanded(
                  child: CupertinoButton(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    onPressed: () => Navigator.of(sheetCtx)
                        .pop(ApprovalDecision.always),
                    child: Text('始终允许',
                        style: TextStyle(fontSize: 15, color: h.text)),
                  ),
                ),
              ],
            ),
            if (allowStop) ...[
              const SizedBox(height: 4),
              Center(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  onPressed: () => Navigator.of(sheetCtx)
                      .pop(ApprovalDecision.stop),
                  child: Text(
                    '停止任务',
                    style: TextStyle(
                        fontSize: 14, color: HColors.errorOn(h.dark)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
