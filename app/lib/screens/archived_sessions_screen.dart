import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/workspace.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../widgets/bw_approval.dart';

/// **已归档对话**（设置二级页，2026-10-27 用户定）。
///
/// ## 为什么归档会话搬来设置
///
/// 抽屉是"正在用的会话"的地方：归档在那里默认隐藏、且**不能多选**
/// （防误删误操作）。归档的找回与清理归设置管。
///
/// ## 展示：文件树式（2026-10-27 图一，用户要求改）
/// 
/// 按工作区分组（组头可折叠，与抽屉里的工作区分组同一套形态），
/// 会话缩进挂在组下；组内按最近活动倒序，组按各自最近一条排序。
///
/// ## 行为
///
/// · 点一条 = 打开它（回到聊天页并切换过去，由调用方处理导航）
/// · 每行右侧有「回档」按钮 = 取消归档（点即生效、行就地消失）
/// · 长按 = 上拉抽屉：打开 / 取消归档 / 删除
/// · 取消归档、删除成功后该行就地消失（页面持有传入列表的本地副本；
///   真实状态由调用方的回调落盘并刷新聊天页数据）
class ArchivedSessionsScreen extends StatefulWidget {
  const ArchivedSessionsScreen({
    super.key,
    required this.items,
    required this.onOpen,
    required this.onUnarchive,
    required this.onDelete,
  });

  /// (工作区, 已归档会话) 快照，进页时由调用方算好。
  final List<(HWorkspace, HSession)> items;

  /// 打开会话（调用方负责退回聊天页并切换）。
  final void Function(String workspaceId, String sessionId) onOpen;

  /// 取消归档（无确认，调用即生效）。
  final void Function(String workspaceId, String sessionId) onUnarchive;

  /// 删除（调用方弹确认）；返回 true = 真删了。
  final Future<bool> Function(String workspaceId, String sessionId) onDelete;

  @override
  State<ArchivedSessionsScreen> createState() =>
      _ArchivedSessionsScreenState();
}

class _ArchivedSessionsScreenState extends State<ArchivedSessionsScreen> {
  late final List<(HWorkspace, HSession)> _items = [...widget.items]..sort(
      (a, b) => (b.$2.lastActivity?.millisecondsSinceEpoch ?? 0)
          .compareTo(a.$2.lastActivity?.millisecondsSinceEpoch ?? 0));

  /// 折叠的工作区组（默认全展开）。
  final Set<String> _collapsed = {};

  /// 文件树分组：组 = 工作区；组序按各自最近一条归档的时间倒序。
  List<(HWorkspace, List<HSession>)> get _groups {
    final byId = <String, (HWorkspace, List<HSession>)>{};
    for (final (w, s) in _items) {
      byId.putIfAbsent(w.id, () => (w, <HSession>[])).$2.add(s);
    }
    final groups = byId.values.toList();
    int latest((HWorkspace, List<HSession>) g) => g.$2
        .map((s) => s.lastActivity?.millisecondsSinceEpoch ?? 0)
        .fold(0, (a, b) => a > b ? a : b);
    groups.sort((a, b) => latest(b).compareTo(latest(a)));
    return groups;
  }

  void _remove(String workspaceId, String sessionId) {
    setState(() => _items.removeWhere(
        (e) => e.$1.id == workspaceId && e.$2.id == sessionId));
  }

  void _unarchive(HWorkspace w, HSession s) {
    widget.onUnarchive(w.id, s.id);
    _remove(w.id, s.id);
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('已归档对话'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(HSpace.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.archivebox,
                        size: 40, color: h.textFaint),
                    const SizedBox(height: HSpace.md),
                    Text('没有已归档的对话',
                        style: TextStyle(fontSize: 15, color: h.text)),
                    const SizedBox(height: HSpace.sm),
                    Text(
                      '在抽屉里长按会话可以归档，\n归档后到这里找回或清理。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12.5, height: 1.6, color: h.textFaint),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  HSpace.sm, HSpace.md, HSpace.sm, HSpace.lg),
              children: [
                for (final (w, sessions) in _groups) ...[
                  _GroupHeader(
                    workspace: w,
                    count: sessions.length,
                    collapsed: _collapsed.contains(w.id),
                    h: h,
                    onToggle: () => setState(() {
                      if (!_collapsed.remove(w.id)) _collapsed.add(w.id);
                    }),
                  ),
                  if (!_collapsed.contains(w.id))
                    for (final s in sessions)
                      _ArchivedRow(
                        session: s,
                        h: h,
                        onTap: () => widget.onOpen(w.id, s.id),
                        onMenu: () => _menu(context, h, w, s),
                        onUnarchive: () => _unarchive(w, s),
                      ),
                ],
              ],
            ),
    );
  }

  void _menu(BuildContext context, Hue h, HWorkspace w, HSession s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => BwSheetShell(
        onDismissRequest: () => Navigator.of(ctx).pop(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: h.text),
              ),
            ),
            _MenuRow(
              h: h,
              icon: CupertinoIcons.chat_bubble_fill,
              label: '打开',
              onTap: () {
                Navigator.of(ctx).pop();
                widget.onOpen(w.id, s.id);
              },
            ),
            _MenuRow(
              h: h,
              icon: CupertinoIcons.archivebox,
              label: '取消归档',
              onTap: () {
                Navigator.of(ctx).pop();
                _unarchive(w, s);
              },
            ),
            _MenuRow(
              h: h,
              icon: CupertinoIcons.trash_fill,
              label: '删除',
              danger: true,
              onTap: () async {
                Navigator.of(ctx).pop();
                final ok = await widget.onDelete(w.id, s.id);
                if (ok && mounted) _remove(w.id, s.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.workspace,
    required this.count, this.collapsed = false,
    required this.h,
    required this.onToggle,
  });

  final HWorkspace workspace;
  final int count;
  final bool collapsed;
  final Hue h;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HSpace.md, vertical: 10),
        child: Row(
          children: [
            Icon(collapsed ? AppIcons.chevronRight : AppIcons.chevronDown,
                size: 15, color: h.textFaint),
            const SizedBox(width: 6),
            Icon(CupertinoIcons.folder_fill, size: 19, color: h.textDim),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                workspace.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600, color: h.text),
              ),
            ),
            Text('$count 条',
                style: TextStyle(fontSize: 11.5, color: h.textFaint)),
          ],
        ),
      ),
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({
    required this.session,
    required this.h,
    required this.onTap,
    required this.onMenu,
    required this.onUnarchive,
  });

  final HSession session;
  final Hue h;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  /// 「回档」= 取消归档（行右侧常驻按钮，不必长按进菜单）。
  final VoidCallback onUnarchive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 左缩进与组头的文件夹对齐 —— 树形从属感
      padding: const EdgeInsets.only(left: 30, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          onLongPress: onMenu,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: HSpace.md, vertical: 10),
            child: Row(
              children: [
                Icon(CupertinoIcons.archivebox, size: 15, color: h.textFaint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: h.text),
                  ),
                ),
                if (session.relativeTime.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(session.relativeTime,
                      maxLines: 1,
                      style: TextStyle(fontSize: 11.5, color: h.textFaint)),
                ],
                const SizedBox(width: 10),
                // 回档按钮：独立点击区，不触发整行打开
                Material(
                  color: h.surfaceAlt,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onUnarchive,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Text('回档',
                          style: TextStyle(fontSize: 12, color: h.text)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.h,
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final Hue h;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? HColors.errorOn(h.dark) : h.text;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(fontSize: 15, color: color)),
          ],
        ),
      ),
    );
  }
}

