import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';

/// 审批相关弹层（2026-10-24 黑白改版）。
///
/// 两件套：
/// - 完全访问二次确认：与权限选择抽屉同款底部上拉抽屉，勾选
///   「我已知晓」后「确认选择」才可用；取消/返回 = 不改（沿用旧弹窗的安全语义）。
/// - 运行时审批请求：三按钮（拒绝 / 允许一次 / 始终允许），等后端 N1
///   的 `approval_required` 事件落地后再接线 —— 目前只提供 UI，不挂假触发器。

/// 完全访问二次确认抽屉。返回 true = 用户勾选并确认。
Future<bool> showFullAccessConfirmSheet(BuildContext context) async {
  final h = Hue.of(context);
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: h.surfaceAlt,
    // 安全语义不变：必须显式选择，点遮罩/下滑都不算确认
    isDismissible: false,
    enableDrag: false,
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
              '确认切换到「完全访问」？',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              '选这个档位后，agent 的操作不再逐条询问你：\n\n'
              '· 它修改文件、执行命令都不会再确认\n'
              '· 出错或越界时没有拦截点\n'
              '· 这个选择会持续到你自己改回来\n\n'
              '${PermissionMode.fullAccess.description}',
              style: TextStyle(fontSize: 14.5, height: 1.6, color: h.textDim),
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
          ],
        ),
      ),
    );
  }
}

/// 运行时审批请求的决定（与 INTERFACE.md N1 的 replyApproval 对齐）。
enum ApprovalDecision { deny, once, always }

/// 运行时审批请求弹窗：拒绝 / 允许一次 / 始终允许。
///
/// 调用方在后端 N1 的 `approval_required` 事件到达时弹出；
/// 用户选「始终允许」后调用方负责写 alwaysAllowedTools。
/// 超时/断线时调用方按 fail-closed 处理（拒绝），本 UI 不擅自决定。
Future<ApprovalDecision?> showApprovalRequestSheet(
  BuildContext context, {
  required String tool,
  required String argsPreview,
  String? risk,
  bool workspaceInside = true,
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
            Text(
              argsPreview,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: h.textDim),
            ),
            if (risk != null) ...[
              const SizedBox(height: 8),
              Text(
                risk,
                style: TextStyle(
                    fontSize: 13.5, color: HColors.warnOn(h.dark)),
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
          ],
        ),
      ),
    ),
  );
}
