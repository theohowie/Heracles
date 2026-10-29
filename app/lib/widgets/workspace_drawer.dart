import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../models/view_options.dart';
import '../models/workspace.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import 'bw_approval.dart';

/// 工作区侧边栏 —— 项目与会话管理。
///
/// ## 概念模型（2026-10-10 修正）
///
/// ```
/// 工作区 = 用户【选择的一个已有文件夹】（不是"新建"出来的）
///    ├── 在里面直接发消息 → 自动新建会话
///    └── 会话 ⋯重命名 / 🗑删除 / ⭐收藏 / 📦归档
/// ```
///
/// ## 视图选项（2026-10-10 新增）
///
/// 「⚙」打开视图选项，三组互斥单选：
/// · 分组方式：按工作区 / 单列表
/// · 排序方式：最近更新 / 手动排序（2026-10-19 曾以假选项删掉手动
///   排序；2026-10-29 用户点名要回，这次连拖拽实现一起落地）
/// · 筛选会话：隐藏已归档 / 全部对话 / 仅显示已归档
///
/// ## 与桌面版的差异（手机适配）
///
/// 桌面版用**悬浮**才显示行内操作。手机没有鼠标，所以**全部常驻显示**。
/// 侧边栏本体也是抽屉式滑出 —— 手机屏幕窄，常驻会挤掉对话区。

/// 手动排序拖拽的数据（会话不换工作区，跨组拖放直接拒绝）。
typedef SessionDragData = ({String workspaceId, String sessionId});

/// **按视图选项给一列会话排序**（纯函数，单测钉住）。
///
/// - 最近更新：收藏置顶，其余按最近活动倒序 —— 分组视图排组内、
///   单列表排全局，两处同规则（2026-10-29 前分组视图根本没排，
///   用的后端返回序；用户点名「选哪个就要按照那个来」后补齐）。
/// - 手动排序：按 [ViewOptions.manualOrder] 里的相对顺序；
///   还没排过的会话（新建的）在已排会话之前、彼此走最近更新
///   规则 —— 下一次拖动落盘整表后顺序稳定。
List<HSession> sortSessionsForView(
  List<HSession> sessions,
  ViewOptions options,
) {
  final list = [...sessions];
  int byRecent(HSession a, HSession b) {
    if (a.starred != b.starred) return a.starred ? -1 : 1;
    final ta = a.lastActivity?.millisecondsSinceEpoch ?? 0;
    final tb = b.lastActivity?.millisecondsSinceEpoch ?? 0;
    return tb.compareTo(ta);
  }

  switch (options.sorting) {
    case SessionSorting.recent:
      list.sort(byRecent);
    case SessionSorting.manual:
      final index = <String, int>{
        for (var i = 0; i < options.manualOrder.length; i++)
          options.manualOrder[i]: i,
      };
      list.sort((a, b) {
        final ia = index[a.id];
        final ib = index[b.id];
        if (ia != null && ib != null) return ia.compareTo(ib);
        if (ia != null) return 1; // 已排的在未排的之后
        if (ib != null) return -1;
        return byRecent(a, b);
      });
  }
  return list;
}

/// **手动排序拖动后的新 manualOrder**（纯函数，单测钉住）。
///
/// 入参是**全部**工作区（未筛选的完整数据）与当前选项：先按
/// 当前手动序算出每个工作区的完整显示顺序，只在被拖会话所属
/// 的工作区内移动它（会话不换工作区 —— 跨组拖放由行上的
/// DragTarget 直接拒绝），最后把各工作区的顺序首尾相接成
/// 新的全局 manualOrder。返回 null = 没产生变化。
List<String>? manualOrderAfterMove(
  List<HWorkspace> workspaces,
  ViewOptions options, {
  required String workspaceId,
  required String draggedId,
  required String targetId,
  required bool before,
}) {
  if (draggedId == targetId) return null;
  final out = <String>[];
  var changed = false;
  for (final w in workspaces) {
    final sorted = sortSessionsForView(w.sessions, options);
    if (w.id != workspaceId) {
      out.addAll(sorted.map((s) => s.id));
      continue;
    }
    final ids = sorted.map((s) => s.id).toList();
    final from = ids.indexOf(draggedId);
    final targetAt = ids.indexOf(targetId);
    if (from < 0 || targetAt < 0) return null;
    ids.removeAt(from);
    final insertAt = ids.indexOf(targetId) + (before ? 0 : 1);
    ids.insert(insertAt, draggedId);
    changed = ids.join() != sorted.map((s) => s.id).join();
    out.addAll(ids);
  }
  return changed ? out : null;
}

/// 工作区抽屉（公开外壳）：本体渲染在 [_WorkspaceDrawerBody]，
/// 这里只持有**多选模式**的状态（是否在选、选了哪些），
/// 这样本体保持无状态、既有构造参数一个不变。
class WorkspaceDrawer extends StatefulWidget {
  const WorkspaceDrawer({
    super.key,
    required this.workspaces,
    required this.onSelectSession,
    required this.onNewSession,
    required this.onOpenSettings,
    required this.viewOptions,
    required this.onViewOptionsChanged,
    required this.searchQuery,
    required this.onSearchChanged,
    this.onAddWorkspace,
    this.onAddAppWorkspace,
    this.onRemoveWorkspace,
    this.onRenameSession,
    this.onDeleteSession,
    this.onToggleStar,
    this.onToggleArchive,
    this.onToggleWorkspace,
    this.onClose,
    this.onOpenWorkspaceFolder,
    this.onBatchArchiveSessions,
    this.onBatchDeleteSessions,
    this.loading = false,
  });

  final List<HWorkspace> workspaces;
  final void Function(String workspaceId, String sessionId) onSelectSession;
  final void Function(String workspaceId) onNewSession;
  final VoidCallback onOpenSettings;
  final ViewOptions viewOptions;
  final void Function(ViewOptions) onViewOptionsChanged;
  final String searchQuery;
  final void Function(String) onSearchChanged;
  final VoidCallback? onAddWorkspace;
  final VoidCallback? onAddAppWorkspace;
  final void Function(String workspaceId)? onRemoveWorkspace;
  final void Function(String workspaceId, String sessionId)? onRenameSession;
  final void Function(String workspaceId, String sessionId)? onDeleteSession;
  final void Function(String workspaceId, String sessionId)? onToggleStar;
  final void Function(String workspaceId, String sessionId)? onToggleArchive;
  final void Function(String workspaceId)? onToggleWorkspace;
  final VoidCallback? onClose;

  /// 在系统文件管理里打开该工作区文件夹（工作区菜单里点路径）。
  final void Function(String workspaceId)? onOpenWorkspaceFolder;

  /// **批量归档 / 取消归档**（多选）：items 为 (工作区id, 会话id) 列表，
  /// archive = 目标状态（true 归档、false 取消归档）。
  final void Function(List<(String, String)> items, bool archive)?
      onBatchArchiveSessions;

  /// **批量删除**（多选）：删除确认由调用方统一弹一次（带数量），
  /// 不逐条确认。
  final void Function(List<(String, String)> items)? onBatchDeleteSessions;

  final bool loading;

  @override
  State<WorkspaceDrawer> createState() => _WorkspaceDrawerState();
}

class _WorkspaceDrawerState extends State<WorkspaceDrawer> {
  bool _selecting = false;
  final Set<(String, String)> _selected = {};

  void _enterSelect() => setState(() => _selecting = true);

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggleKey(String wid, String sid) => setState(() {
        final k = (wid, sid);
        if (!_selected.remove(k)) _selected.add(k);
      });

  @override
  Widget build(BuildContext context) {
    final batchWired = widget.onBatchArchiveSessions != null ||
        widget.onBatchDeleteSessions != null;
    return _WorkspaceDrawerBody(
      workspaces: widget.workspaces,
      onSelectSession: widget.onSelectSession,
      onNewSession: widget.onNewSession,
      onOpenSettings: widget.onOpenSettings,
      viewOptions: widget.viewOptions,
      onViewOptionsChanged: widget.onViewOptionsChanged,
      searchQuery: widget.searchQuery,
      onSearchChanged: widget.onSearchChanged,
      onAddWorkspace: widget.onAddWorkspace,
      onAddAppWorkspace: widget.onAddAppWorkspace,
      onRemoveWorkspace: widget.onRemoveWorkspace,
      onRenameSession: widget.onRenameSession,
      onDeleteSession: widget.onDeleteSession,
      onToggleStar: widget.onToggleStar,
      onToggleArchive: widget.onToggleArchive,
      onToggleWorkspace: widget.onToggleWorkspace,
      onClose: widget.onClose,
      onOpenFolder: widget.onOpenWorkspaceFolder,
      loading: widget.loading,
      selecting: _selecting,
      selectedKeys: _selected,
      onEnterSelect: batchWired ? _enterSelect : null,
      onExitSelect: _exitSelect,
      onToggleSelectKey: _toggleKey,
      onSelectKeys: (items) => setState(() => _selected.addAll(items)),
      onBatchArchiveTap: (archive) {
        final items = _selected.toList();
        _exitSelect();
        widget.onBatchArchiveSessions?.call(items, archive);
      },
      onBatchDeleteTap: () {
        final items = _selected.toList();
        _exitSelect();
        widget.onBatchDeleteSessions?.call(items);
      },
    );
  }
}

class _WorkspaceDrawerBody extends StatelessWidget {
  const _WorkspaceDrawerBody({
    required this.workspaces,
    required this.onSelectSession,
    required this.onNewSession,
    required this.onOpenSettings,
    required this.viewOptions,
    required this.onViewOptionsChanged,
    required this.searchQuery,
    required this.onSearchChanged,
    this.onAddWorkspace,
    this.onAddAppWorkspace,
    this.onRemoveWorkspace,
    this.onRenameSession,
    this.onDeleteSession,
    this.onToggleStar,
    this.onToggleArchive,
    this.onToggleWorkspace,
    this.onClose,
    this.loading = false,
    this.onOpenFolder,
    this.selecting = false,
    this.selectedKeys = const {},
    this.onEnterSelect,
    this.onExitSelect,
    this.onToggleSelectKey,
    this.onSelectKeys,
    this.onBatchArchiveTap,
    this.onBatchDeleteTap,
  });

  final List<HWorkspace> workspaces;

  final void Function(String workspaceId, String sessionId) onSelectSession;
  final void Function(String workspaceId) onNewSession;
  final VoidCallback onOpenSettings;

  final ViewOptions viewOptions;
  final void Function(ViewOptions) onViewOptionsChanged;

  final String searchQuery;
  final void Function(String) onSearchChanged;

  /// **选一个已有文件夹**（不是创建目录）
  final VoidCallback? onAddWorkspace;

  /// **登记内置「应用工作区」**（2026-10-17）—— SAF 选不到 `Android/data`，
  /// 而那正是真机上唯一 App 与 shell 都能写（因而**能构建**）的位置。
  ///
  /// 与 [onAddWorkspace] 是**两个独立入口**，互不兜底：
  /// 用户明确知道自己在选"我自己的项目"还是"能构建的内置目录"。
  final VoidCallback? onAddAppWorkspace;

  final void Function(String workspaceId)? onRemoveWorkspace;
  final void Function(String workspaceId, String sessionId)? onRenameSession;
  final void Function(String workspaceId, String sessionId)? onDeleteSession;
  final void Function(String workspaceId, String sessionId)? onToggleStar;
  final void Function(String workspaceId, String sessionId)? onToggleArchive;
  final void Function(String workspaceId)? onToggleWorkspace;

  final VoidCallback? onClose;
  final bool loading;

  /// 在系统文件管理里打开工作区文件夹（按工作区 id）。
  final void Function(String workspaceId)? onOpenFolder;

  // ---- 多选模式（2026-10-27）：状态由外层 WorkspaceDrawer 持有 ----
  final bool selecting;
  final Set<(String, String)> selectedKeys;
  final VoidCallback? onEnterSelect;
  final VoidCallback? onExitSelect;
  final void Function(String workspaceId, String sessionId)? onToggleSelectKey;
  final void Function(List<(String, String)> items)? onSelectKeys;
  final void Function(bool archive)? onBatchArchiveTap;
  final VoidCallback? onBatchDeleteTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final width = MediaQuery.of(context).size.width;
    final drawerWidth = width < 400 ? width * 0.88 : 340.0;

    return Drawer(
      width: drawerWidth,
      backgroundColor: h.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(HRadius.lg),
          bottomRight: Radius.circular(HRadius.lg),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, h),
            const SizedBox(height: HSpace.sm),

            // ⚠️ 2026-10-19：这里原有「插件 / 自动化任务 / 上下文洞察」三个入口，
            //   但它们的 `onTap` 都是空实现 —— 界面上承诺了、点了没反应。
            //   在真有功能之前**不画**（假入口比没有入口更伤信任）。
            if (selecting)
              _selectionHeader(h)
            else
              _SectionHeader(
                h: h,
                searchQuery: searchQuery,
                onSearchChanged: onSearchChanged,
                onAdd: onAddWorkspace,
                onAddApp: onAddAppWorkspace,
                onViewOptions: () => _openViewOptions(context, h),
                onSelectMode: onEnterSelect,
              ),

            if (searchQuery.isNotEmpty) _searchBanner(h),

            Expanded(child: _body(context, h)),

            const Divider(height: 1),
            InkWell(
              onTap: onOpenSettings,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: HSpace.xl, vertical: HSpace.lg),
                child: Row(
                  children: [
                    // 原型 04：齿轮放浅灰圆角方砖里，文字用正色
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: h.surface,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(AppIcons.settings, size: 17, color: h.text),
                    ),
                    const SizedBox(width: HSpace.md),
                    Text('设置',
                        style: TextStyle(fontSize: 15, color: h.text)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 主体

  /// 应用搜索、筛选与**排序**后的工作区列表。
  ///
  /// 排序在这里统一生效（2026-10-29）：此前只有单列表模式排了
  /// 「最近更新」，分组模式用的是后端返回序 —— 用户选了排序
  /// 却不生效。单列表的全局时间线排序仍在 [_flatList] 里另做
  /// 一次（跨工作区混排是那个视图的本意），手动排序不混排、
  /// 就按这里的工作区内顺序首尾相接。
  List<HWorkspace> get _visible {
    final q = searchQuery.toLowerCase();
    final out = <HWorkspace>[];
    for (final w in workspaces) {
      final filtered = w.sessions.where((s) {
        if (!viewOptions.shows(s.archived)) return false;
        if (q.isEmpty) return true;
        return s.title.toLowerCase().contains(q);
      }).toList();
      out.add(w.copyWith(sessions: sortSessionsForView(filtered, viewOptions)));
    }
    return out;
  }

  /// 手动排序是否正在生效（多选模式下不给拖，免得手势打架）。
  bool get _manualSort =>
      viewOptions.sorting == SessionSorting.manual && !selecting;

  /// 拖动落点后把新顺序写回视图选项（持久化在选项的存储里）。
  void _applyManualMove(
    SessionDragData dragged,
    String targetSessionId,
    bool before,
  ) {
    final next = manualOrderAfterMove(
      workspaces,
      viewOptions,
      workspaceId: dragged.workspaceId,
      draggedId: dragged.sessionId,
      targetId: targetSessionId,
      before: before,
    );
    if (next != null) {
      onViewOptionsChanged(viewOptions.copyWith(manualOrder: next));
    }
  }

  /// 给一行套上手动排序的落点（同工作区才接、自己不接自己）。
  Widget _rowDropTarget(
    String workspaceId,
    HSession target,
    Widget child,
  ) {
    return _ManualDropRow(
      workspaceId: workspaceId,
      target: target,
      onMove: _applyManualMove,
      child: child,
    );
  }

  Widget _body(BuildContext context, Hue h) {
    if (loading) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CupertinoActivityIndicator(radius: 10, color: h.textFaint),
        ),
      );
    }
    if (workspaces.isEmpty) return _empty(h);

    final visible = _visible;

    // ★★ 工作区**永远要显示**，哪怕它一个会话都没有（2026-10-20 真机 bug）★★
    //
    // ## 用户报的现象
    //
    // 「我选了一个文件夹做工作区，但是左侧边栏看不到工作区。」
    // 真机复现（e35e48c6）：`heracles_workspaces.xml` 里**确实登记了**两个工作区，
    // 但抽屉里显示「这个筛选下没有会话」，**一条工作区都看不到**。
    //
    // ## 根因
    //
    // 这里原来是 `if (!hasAny) return _noResults(h)`，而 `_groupedList` 里又有
    // `visible.where((w) => w.sessions.isNotEmpty)` —— 两处都要求"工作区里必须有会话"。
    // ⇒ 用户刚选一个**空文件夹**当工作区（会话数 = 0）⇒ 整个抽屉判定为"无结果"
    // ⇒ 既看不到工作区，也**没有入口给它新建会话**（鸡生蛋：没会话就不显示，
    //    不显示就没法建会话）。
    //
    // ## 修法
    //
    // 工作区是**容器**，会话是容器里的内容 —— 容器空着也得显示，
    // 否则用户永远没法往里放第一个会话。
    //
    // ## ⚠️ 第一版修错了（2026-10-20 用户复现打回）
    //
    // 第一版写成「用户搜索过 或 `filter != all` 就算在筛选 ⇒ 全空时显示『没有匹配』」。
    // 但 `hideArchived` 是**默认值**（不是用户主动选的）⇒ 用户把默认工作区的会话
    // 全删掉之后，**两个工作区一起消失**，抽屉又变成"这个筛选下没有会话"。
    //
    // ⇒ 判据只能是**用户是否真的在搜索**。归档筛选不影响"工作区该不该显示"
    //   —— 一个工作区的会话全被归档时，工作区本身当然还在，只是里面暂时没内容。
    //   那种情况由 `_WorkspaceGroup` 自然渲染成"空分组"，**不该把整个抽屉判成无结果**。
    final searching = searchQuery.isNotEmpty;
    if (searching && visible.every((w) => w.sessions.isEmpty)) {
      // 搜索确实没命中 —— 这时提示"没有匹配"是对的，但要让人知道**工作区还在**、
      // 只是搜索结果为空（所以文案里点明搜索词，而不是笼统说"这个筛选下没有会话"）。
      return _noResults(h);
    }

    switch (viewOptions.grouping) {
      case SessionGrouping.flatList:
        return _flatList(context, visible, h);
      case SessionGrouping.byWorkspace:
        return _groupedList(context, visible, h);
    }
  }

  Widget _groupedList(BuildContext context, List<HWorkspace> visible, Hue h) {
    // ★ 不再按 `sessions.isNotEmpty` 过滤（2026-10-20）：空工作区也要列出来，
    //   否则用户新建的工作区在侧边栏不可见、也没法给它建第一个会话。
    final rows = visible;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: HSpace.lg),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final w = rows[i];
        return _WorkspaceGroup(
          workspace: w,
          h: h,
          onToggle: () => onToggleWorkspace?.call(w.id),
          onNewSession: () => onNewSession(w.id),
          onRemove: () => onRemoveWorkspace?.call(w.id),
          onOpenFolder: onOpenFolder == null
              ? null
              : () => onOpenFolder!.call(w.id),
          onSelectSession: (sid) => onSelectSession(w.id, sid),
          onRename: (sid) => onRenameSession?.call(w.id, sid),
          onDelete: (sid) => onDeleteSession?.call(w.id, sid),
          onStar: (sid) => onToggleStar?.call(w.id, sid),
          onArchive: (sid) => onToggleArchive?.call(w.id, sid),
          selecting: selecting,
          selectedKeys: selectedKeys,
          onToggleSelect: (sid) => onToggleSelectKey?.call(w.id, sid),
          onBatchMenu: (sid) => _batchMenu(
              context, h, w, w.sessions.firstWhere((x) => x.id == sid)),
          manualSort: _manualSort,
          onReorderSession: (draggedId, targetId, before) =>
              _applyManualMove(
            (workspaceId: w.id, sessionId: draggedId),
            targetId,
            before,
          ),
        );
      },
    );
  }

  /// 单列表 —— 所有会话平铺，必须标注归属工作区
  Widget _flatList(BuildContext context, List<HWorkspace> visible, Hue h) {
    final rows = <(HWorkspace, HSession)>[];
    for (final w in visible) {
      for (final s in w.sessions) {
        rows.add((w, s));
      }
    }

    // ★ 空列表兜底（2026-10-20）：
    //
    // 「单列表」是按**会话**平铺的（每行 = 一个会话，右侧标注它属于哪个工作区），
    // 所以 0 个会话时它天然就是空列表 —— 这在数据上没错，**但用户会以为工作区丢了**
    // （和本轮修的那个 bug 同一个症状）。
    //
    // 这里给一条**能自救**的提示：告诉他工作区还在、只是这个视图不按工作区列，
    // 并给一个直接切回分组视图的按钮。**不要让用户自己去猜怎么切回来。**
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                visible.isEmpty
                    ? '还没有工作区'
                    : '工作区还在，但「单列表」只按会话铺行，\n现在一个会话都没有。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, height: 1.6, color: h.textFaint),
              ),
              if (visible.isNotEmpty) ...[
                const SizedBox(height: HSpace.md),
                CupertinoButton(
                  onPressed: () => onViewOptionsChanged(
                    viewOptions.copyWith(grouping: SessionGrouping.byWorkspace),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text('切回「按工作区分组」',
                      style: TextStyle(fontSize: 12.5, color: h.accent)),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (viewOptions.sorting == SessionSorting.recent) {
      rows.sort((a, b) {
        // 收藏置顶，然后按时间倒序
        if (a.$2.starred != b.$2.starred) return a.$2.starred ? -1 : 1;
        final ta = a.$2.lastActivity?.millisecondsSinceEpoch ?? 0;
        final tb = b.$2.lastActivity?.millisecondsSinceEpoch ?? 0;
        return tb.compareTo(ta);
      });
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          HSpace.sm, 0, HSpace.sm, HSpace.lg),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final (w, s) = rows[i];
        final row = _SessionRow(
          session: s,
          h: h,
          subtitle: w.name,
          selecting: selecting,
          selected: selectedKeys.contains((w.id, s.id)),
          dragHandle:
              _manualSort ? buildSessionDragHandle(h, w.id, s) : null,
          onTap: selecting
              ? (s.archived
                  ? () {}
                  : () => onToggleSelectKey?.call(w.id, s.id))
              : () => onSelectSession(w.id, s.id),
          onMenu: selecting
              ? (s.archived ? () {} : () => _batchMenu(context, h, w, s))
              : () => _sessionMenu(
            context,
            h,
            w,
            s,
            (wid, sid) => onToggleStar?.call(wid, sid),
            (wid, sid) => onRenameSession?.call(wid, sid),
            (wid, sid) => onToggleArchive?.call(wid, sid),
            (wid, sid) => onDeleteSession?.call(wid, sid),
          ),
        );
        if (!_manualSort) return row;
        return _rowDropTarget(w.id, s, row);
      },
    );
  }

  // ------------------------------------------------------------ 多选模式

  /// 多选时**长按**任意一条可选项 → 上拉抽屉里选归档 / 删除
  /// （用户定：不要底部常驻操作条，沿用全 App 的长按出抽屉习惯）。
  /// 长按的那条若还没勾上，先自动勾上，计数含它。
  void _batchMenu(BuildContext context, Hue h, HWorkspace w, HSession s) {
    final key = (w.id, s.id);
    final already = selectedKeys.contains(key);
    // ★ 先算 n 再勾：selectedKeys 与外壳状态是同一个 Set 对象，
    //   onToggleSelectKey 一调它就同步变了，顺序反了会多算一个。
    final n = selectedKeys.length + (already ? 0 : 1);
    if (!already) onToggleSelectKey?.call(w.id, s.id);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => BwSheetShell(
        onDismissRequest: () => Navigator.of(ctx).pop(),
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _bwSheetHandle(h),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  '已选 $n 个会话',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: h.text),
                ),
              ),
              _bwMenuRow(
                h,
                icon: CupertinoIcons.archivebox_fill,
                label: '归档',
                subtitle: '归档后在设置中查看',
                onTap: () {
                  Navigator.of(ctx).pop();
                  onBatchArchiveTap?.call(true);
                },
              ),
              _bwMenuRow(
                h,
                icon: CupertinoIcons.trash_fill,
                label: '删除',
                danger: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onBatchDeleteTap?.call();
                },
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _selectionHeader(Hue h) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.xl, HSpace.md, HSpace.sm, 0),
      child: Row(
        children: [
          Text(
            '已选 ${selectedKeys.length} 个',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: h.text,
              letterSpacing: 0.6,
            ),
          ),
          const Spacer(),
          _textAction(h, '全选', () {
            // 全选 = 当前筛选下**看得见**的会话（_visible 已应用筛选/搜索）
            final items = <(String, String)>[
              for (final w in _visible)
                for (final s in w.sessions)
                  if (!s.archived) (w.id, s.id),
            ];
            onSelectKeys?.call(items);
          }),
          _textAction(h, '取消', onExitSelect),
        ],
      ),
    );
  }

  Widget _textAction(Hue h, String label, VoidCallback? onTap) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(label, style: TextStyle(fontSize: 13, color: h.text)),
        ),
      );

  Widget _noResults(Hue h) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HSpace.xl),
          child: Text(
            searchQuery.isNotEmpty
                ? '没有匹配「$searchQuery」的会话'
                : '这个筛选下没有会话',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.6, color: h.textFaint),
          ),
        ),
      );

  Widget _empty(Hue h) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.folder_badge_plus,
                  size: 35, color: h.textFaint),
              const SizedBox(height: HSpace.md),
              Text('还没有工作区',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: h.text)),
              const SizedBox(height: HSpace.sm),
              Text(
                '工作区是你要让智能体操作的\n那个项目文件夹。\n\n'
                '点右上角 ⊕ 选择一种工作区。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, height: 1.65, color: h.textFaint),
              ),
              const SizedBox(height: HSpace.xl),
              IosButton(
                label: '选择文件夹',
                onPressed: onAddWorkspace,
                color: h.accent,
              ),
              // ★ 次要入口：内置「应用工作区」（2026-10-17）
              //
              // 空态是用户**第一次**进来的地方 —— 正好是解释
              // "为什么会有两种工作区"的最佳时机，而不是等他
              // 选了 /sdcard 的项目、构建失败了才去猜。
              if (onAddAppWorkspace != null) ...[
                const SizedBox(height: HSpace.md),
                CupertinoButton(
                  onPressed: onAddAppWorkspace,
                  padding: const EdgeInsets.symmetric(
                      horizontal: HSpace.lg, vertical: HSpace.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.house_fill, size: 18, color: h.accent),
                      const SizedBox(width: HSpace.sm),
                      Text('使用默认工作区',
                          style: TextStyle(fontSize: 12.5, color: h.accent)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );

  // 头部（原型 04，2026-10-25 按用户指定式样重做）：App 图标 +
  // Heracles / 端侧智能体两行标题，右上角黑方钮 = 新建会话
  // （不再单占一整行描边大按钮，也没有 × —— 关抽屉靠滑/点遮罩）。
  Widget _header(BuildContext context, Hue h) => Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.lg, 0),
        child: Row(
          children: [
            // ★ 真实 App 图标（2026-10-24 黑白改版）：不再用字母/符号占位
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Image.asset(
                'assets/branding/app_icon_source.png',
                width: 34,
                height: 34,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: HSpace.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Heracles',
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w600,
                    color: h.text,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '端侧智能体',
                  style: TextStyle(fontSize: 11.5, color: h.textFaint),
                ),
              ],
            ),
            const Spacer(),
            Material(
              color: h.text,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                // 语义沿用旧大按钮：无工作区时先去加工作区
                onTap: () {
                  if (workspaces.isEmpty) {
                    onAddWorkspace?.call();
                    return;
                  }
                  onNewSession(workspaces.first.id);
                },
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: Icon(
                    AppIcons.add,
                    size: 19,
                    color: h.dark ? const Color(0xFF0A0A0B) : Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _searchBanner(Hue h) => Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, HSpace.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '搜索：$searchQuery',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: h.accent),
              ),
            ),
            InkWell(
              onTap: () => onSearchChanged(''),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(AppIcons.close, size: 15, color: h.textFaint),
              ),
            ),
          ],
        ),
      );

  // ------------------------------------------------------------ 视图选项

  Future<void> _openViewOptions(BuildContext context, Hue h) async {
    var draft = viewOptions;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => BwSheetShell(
        onDismissRequest: () => Navigator.of(ctx).pop(),
        child: StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ★ 2026-10-29 用户定：抽屉里做选择一律用带
                    // 边框的选项卡（与审批模式/单选抽屉同款），
                    // 选中 = 主文本色边框（浅色下黑边框）；旧版
                    // 「纯文字行 + 右侧对勾」与抓手一起补齐。
                    _bwSheetHandle(h),
                    _sheetGroupLabel(h, '分组方式'),
                    _optionCard(h, '按工作区',
                        draft.grouping == SessionGrouping.byWorkspace, () {
                      setSheet(() => draft = draft.copyWith(
                          grouping: SessionGrouping.byWorkspace));
                    }),
                    _optionCard(h, '单列表',
                        draft.grouping == SessionGrouping.flatList, () {
                      setSheet(() => draft = draft.copyWith(
                          grouping: SessionGrouping.flatList));
                    }),
                    // ⚠️ 2026-10-19 曾删掉「手动排序」（没有拖拽实现
                    // 的假选项）；2026-10-29 用户点名要回，连拖拽
                    // 实现一起补上（行尾手柄 + manualOrder 持久化）。
                    _sheetGroupLabel(h, '排序方式'),
                    _optionCard(h, '最近更新',
                        draft.sorting == SessionSorting.recent, () {
                      setSheet(() => draft =
                          draft.copyWith(sorting: SessionSorting.recent));
                    }),
                    _optionCard(h, '手动排序',
                        draft.sorting == SessionSorting.manual, () {
                      setSheet(() => draft =
                          draft.copyWith(sorting: SessionSorting.manual));
                    }),
                    _sheetGroupLabel(h, '筛选会话'),
                    _optionCard(h, '隐藏已归档',
                        draft.filter == SessionFilter.hideArchived, () {
                      setSheet(() => draft = draft.copyWith(
                          filter: SessionFilter.hideArchived));
                    }),
                    _optionCard(h, '全部对话（显示已归档）',
                        draft.filter == SessionFilter.all, () {
                      setSheet(() => draft =
                          draft.copyWith(filter: SessionFilter.all));
                    }),
                    _optionCard(h, '仅显示已归档',
                        draft.filter == SessionFilter.onlyArchived, () {
                      setSheet(() => draft = draft.copyWith(
                          filter: SessionFilter.onlyArchived));
                    }),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      ),
    );

    // 关闭即提交 —— 单选无需"确定"按钮
    if (draft.grouping != viewOptions.grouping ||
        draft.sorting != viewOptions.sorting ||
        draft.filter != viewOptions.filter) {
      onViewOptionsChanged(draft);
    }
  }

  Widget _sheetGroupLabel(Hue h, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: h.textFaint,
            letterSpacing: 0.5,
          ),
        ),
      );

  /// **抽屉选项卡**（2026-10-29 用户定版，规格写进 DESIGN.md）：
  /// 实现收敛到全 App 唯一的 [BwOptionCard]（bw_approval.dart），
  /// 这里只补卡片间距。
  Widget _optionCard(
    Hue h,
    String label,
    bool selected,
    VoidCallback onTap,
  ) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: BwOptionCard(
          h: h,
          selected: selected,
          title: label,
          onTap: onTap,
        ),
      );
}

// ------------------------------------------------------------ 会话菜单

/// 会话的底部菜单。
///
/// 用**文件级函数**而不是 widget 方法 —— 因为它需要 workspace 上下文
/// 才能把回调传给上层，做成 widget 会多一层无意义的 prop 传递。
/// 会话的底部菜单（2026-10-25 改统一抽屉样式：抓手 + 填充图标行，
/// 与审批 / 确认抽屉同一套视觉。旧版 CupertinoListTile + 描边图标
/// 与新抽屉语言不一致，用户真机指出后退役）。
///
/// 用**文件级函数**而不是 widget 方法 —— 因为它需要 workspace 上下文
/// 才能把回调传给上层，做成 widget 会多一层无意义的 prop 传递。
void _sessionMenu(
  BuildContext context,
  Hue h,
  HWorkspace w,
  HSession s,
  void Function(String workspaceId, String sessionId) onStar,
  void Function(String workspaceId, String sessionId) onRename,
  void Function(String workspaceId, String sessionId) onArchive,
  void Function(String workspaceId, String sessionId) onDelete,
) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (ctx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(ctx).pop(),
      child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _bwSheetHandle(h),
            const SizedBox(height: 8),
            _bwMenuRow(
              h,
              icon: AppIcons.star,
              label: s.starred ? '取消收藏' : '收藏',
              iconColor: s.starred ? HColors.warnOn(h.dark) : null,
              onTap: () {
                Navigator.of(ctx).pop();
                onStar(w.id, s.id);
              },
            ),
            _bwMenuRow(
              h,
              icon: CupertinoIcons.square_pencil_fill,
              label: '重命名',
              onTap: () {
                Navigator.of(ctx).pop();
                onRename(w.id, s.id);
              },
            ),
            _bwMenuRow(
              h,
              icon: CupertinoIcons.archivebox_fill,
              label: s.archived ? '取消归档' : '归档',
              subtitle: '归档后默认隐藏',
              onTap: () {
                Navigator.of(ctx).pop();
                onArchive(w.id, s.id);
              },
            ),
            _bwMenuRow(
              h,
              icon: CupertinoIcons.trash_fill,
              label: '删除',
              danger: true,
              onTap: () {
                Navigator.of(ctx).pop();
                onDelete(w.id, s.id);
              },
            ),
          ],
        ),
      ),
    ),
    ),
  );
}

/// 抽屉抓手（与 bw 系列抽屉一致的样式）
Widget _bwSheetHandle(Hue h) => Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: h.border,
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );

/// 统一抽屉菜单行 = 边框动作卡（BwActionCard，2026-10-29 用户
/// 定版）：灰边框、无单选圆圈，按下时边框变主文本色；
/// [danger] = 图标与文字一起语义红（删除类）。
/// 卡片自带 8 的下间距，调用处直接竖排即可。
Widget _bwMenuRow(
  Hue h, {
  required IconData icon,
  required String label,
  String? subtitle,
  Color? iconColor,
  bool danger = false,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: BwActionCard(
      h: h,
      icon: icon,
      label: label,
      subtitle: subtitle,
      iconColor: iconColor,
      danger: danger,
      onTap: onTap,
    ),
  );
}

// ------------------------------------------------------------ 小组件

class _SectionHeader extends StatefulWidget {
  const _SectionHeader({
    required this.h,
    required this.searchQuery,
    required this.onSearchChanged,
    this.onAdd,
    this.onAddApp,
    this.onViewOptions,
    this.onSelectMode,
  });

  final Hue h;

  /// 当前已生效的搜索词（点「搜索」/ 键盘搜索键才提交，不是边打边搜）
  final String searchQuery;
  final void Function(String) onSearchChanged;

  final VoidCallback? onAdd;

  /// 登记内置「应用工作区」（可构建）—— 与 [onAdd] 并列的第二项
  final VoidCallback? onAddApp;

  final VoidCallback? onViewOptions;

  /// 进入多选模式（批量归档 / 删除）；未接批量回调时不画这个入口。
  final VoidCallback? onSelectMode;

  @override
  State<_SectionHeader> createState() => _SectionHeaderState();
}

/// 区块头 + **弹性搜索**（2026-10-29 用户定版，取代旧「点搜索图标
/// 跳一个搜索抽屉」）：
///
/// - 点搜索图标 → 搜索框就地弹性展开，占满整行：左侧「工作区」
///   标题与其余小按钮淡出消失，框外左侧出现「取消」，光标自动
///   落进输入框，不跳页、不弹抽屉。
/// - 框内右侧是「搜索」按钮（键盘搜索键同义），点它才真正筛选。
/// - 框里有内容时，「搜索」左侧出现一个小 ×，点它清空内容
///   （连已生效的搜索词一起清）。
/// - 点框外左侧「取消」→ 取消搜索：清词、收起、按钮恢复。
/// 展开/收起走与抽屉同一组弹簧参数（320/27），是「弹」不是「切」。
class _SectionHeaderState extends State<_SectionHeader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _expanded = false;
  bool _focused = false;

  static const _spring =
      SpringDescription(mass: 1, stiffness: 320, damping: 27);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, value: 0);
    _ctrl.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void didUpdateWidget(_SectionHeader old) {
    super.didUpdateWidget(old);
    // 外部把搜索清掉（横幅上的 ×）时，展开中的输入框跟着清空
    if (widget.searchQuery.isEmpty &&
        old.searchQuery.isNotEmpty &&
        _ctrl.text.isNotEmpty &&
        !_focused) {
      _ctrl.clear();
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onTextChanged);
    _focus.removeListener(_onFocusChanged);
    _anim.dispose();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openSearch() {
    _ctrl.text = widget.searchQuery;
    setState(() => _expanded = true);
    _anim.animateWith(SpringSimulation(_spring, _anim.value, 1, 0));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _cancelSearch() {
    _focus.unfocus();
    _ctrl.clear();
    if (widget.searchQuery.isNotEmpty) widget.onSearchChanged('');
    setState(() => _expanded = false);
    _anim.animateWith(SpringSimulation(_spring, _anim.value, 0, 0));
  }

  void _submitSearch() => widget.onSearchChanged(_ctrl.text.trim());

  void _clearText() {
    _ctrl.clear();
    if (widget.searchQuery.isNotEmpty) widget.onSearchChanged('');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.xl, HSpace.md, HSpace.sm, 0),
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final t = _anim.value.clamp(0.0, 1.0);
          return SizedBox(
            height: 40,
            child: Stack(
              children: [
                // —— 收起态：分组标题 + 一排小按钮 ——
                Opacity(
                  opacity: 1 - t,
                  child: IgnorePointer(
                    ignoring: t > 0.05,
                    child: Row(
                      children: [
                        Text(
                          '工作区',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: h.textFaint,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const Spacer(),
                        _MiniAction(
                          icon: AppIcons.search,
                          h: h,
                          color:
                              widget.searchQuery.isNotEmpty ? h.accent : null,
                          onTap: _openSearch,
                        ),
                        // ★ 视图选项：分组 / 排序 / 筛选
                        _MiniAction(
                          icon: CupertinoIcons.slider_horizontal_3,
                          h: h,
                          onTap: widget.onViewOptions,
                        ),
                        if (widget.onSelectMode != null)
                          _MiniAction(
                            icon: CupertinoIcons.checkmark_square,
                            h: h,
                            onTap: widget.onSelectMode,
                          ),
                        // ★★ ⊕ = 两项菜单（选文件夹 / 应用工作区，
                        // 理由见 _AddWorkspaceMenu 的说明）
                        _AddWorkspaceMenu(
                          h: h,
                          onPickFolder: widget.onAdd,
                          onAddApp: widget.onAddApp,
                        ),
                      ],
                    ),
                  ),
                ),
                // —— 展开态：框外左侧「取消」+ 搜索框占满整行 ——
                if (t > 0)
                  Opacity(
                    opacity: t,
                    child: IgnorePointer(
                      ignoring: !_expanded,
                      child: Row(
                        children: [
                          ClipRect(
                            child: SizedBox(
                              width: 50 * t,
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                maxWidth: 50,
                                child: GestureDetector(
                                  onTap: _cancelSearch,
                                  behavior: HitTestBehavior.opaque,
                                  child: Text(
                                    '取消',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: h.text,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            // 搜索框按最终宽度排版、靠裁剪「长」出来：
                            // 直接把框压窄会让框内 Row 在动画前几帧
                            // 溢出（真机同理），所以内层恒按整行宽
                            // 布局，外层 ClipRect 只露右侧一段，随 t
                            // 向左展开。
                            child: LayoutBuilder(
                              builder: (context, c) {
                                final fullW = c.maxWidth;
                                final w = fullW * (0.14 + 0.86 * t);
                                return Align(
                                  alignment: Alignment.centerRight,
                                  child: ClipRect(
                                    child: SizedBox(
                                      width: w,
                                      child: OverflowBox(
                                        alignment: Alignment.centerRight,
                                        minWidth: fullW,
                                        maxWidth: fullW,
                                        child: SizedBox(
                                          width: fullW,
                                          child: _searchBox(h),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _searchBox(Hue h) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: h.surface,
        border: Border.all(
          color: _focused ? h.text : h.border,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(HRadius.pill),
      ),
      padding: const EdgeInsets.only(left: 13, right: 6),
      child: Row(
        children: [
          Icon(AppIcons.search, size: 16, color: h.textFaint),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submitSearch(),
              decoration: InputDecoration(
                hintText: '搜索会话',
                hintStyle: TextStyle(fontSize: 14.5, color: h.textFaint),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: TextStyle(fontSize: 14.5, color: h.text),
            ),
          ),
          if (_ctrl.text.isNotEmpty)
            GestureDetector(
              onTap: _clearText,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  CupertinoIcons.xmark_circle_fill,
                  size: 16,
                  color: h.textFaint,
                ),
              ),
            ),
          GestureDetector(
            onTap: _submitSearch,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                '搜索',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: h.text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ⊕ 工作区入口 —— **两项菜单**（2026-10-17）。
///
/// 视觉上与 [_MiniAction] 一致（同尺寸、同图标风格），
/// 但点开后是一个明确的两项菜单，而不是直接触发某一个动作 ——
/// **用户必须知道自己在选哪种工作区**。
class _AddWorkspaceMenu extends StatelessWidget {
  const _AddWorkspaceMenu({
    required this.h,
    this.onPickFolder,
    this.onAddApp,
  });

  final Hue h;
  final VoidCallback? onPickFolder;
  final VoidCallback? onAddApp;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _open(context),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(CupertinoIcons.folder_badge_plus,
            size: 18, color: h.textFaint),
      ),
    );
  }

  /// 两项菜单走全 App 统一的底部抽屉（2026-10-27 旧样式统一；
  /// 此前是 Material 的 PopupMenuButton 锚点菜单，全 App 仅剩这一处）。
  void _open(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => BwSheetShell(
        onDismissRequest: () => Navigator.of(ctx).pop(),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _bwSheetHandle(h),
                const SizedBox(height: 8),
                _bwMenuRow(
                  h,
                  icon: CupertinoIcons.folder_fill,
                  label: '选择文件夹',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onPickFolder?.call();
                  },
                ),
                _bwMenuRow(
                  h,
                  icon: CupertinoIcons.house_fill,
                  label: '默认工作区',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onAddApp?.call();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.h,
    this.onTap,
    this.color,
  });

  final IconData icon;
  final Hue h;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HRadius.sm),
          child: Icon(icon, size: 18, color: color ?? h.textFaint),
        ),
      ),
    );
  }
}

/// 一个工作区 + 它下面的会话列表
class _WorkspaceGroup extends StatelessWidget {
  const _WorkspaceGroup({
    required this.workspace,
    required this.h,
    required this.onToggle,
    required this.onNewSession,
    required this.onRemove,
    required this.onSelectSession,
    required this.onRename,
    required this.onDelete,
    required this.onStar,
    required this.onArchive,
    this.selecting = false,
    this.selectedKeys = const {},
    this.onToggleSelect,
    this.onBatchMenu,
    this.onOpenFolder,
    this.manualSort = false,
    this.onReorderSession,
  });

  final HWorkspace workspace;
  final Hue h;
  final VoidCallback onToggle;
  final VoidCallback onNewSession;
  final VoidCallback onRemove;
  final void Function(String sessionId) onSelectSession;
  final void Function(String sessionId) onRename;
  final void Function(String sessionId) onDelete;
  final void Function(String sessionId) onStar;
  final void Function(String sessionId) onArchive;

  // 多选模式穿线（分组列表）
  final bool selecting;
  final Set<(String, String)> selectedKeys;
  final void Function(String sessionId)? onToggleSelect;
  final void Function(String sessionId)? onBatchMenu;
  final VoidCallback? onOpenFolder;

  // 手动排序穿线（分组列表）：行尾手柄 + 落点回调（参数为被拖
  // 会话 id、目标会话 id、插到目标之前还是之后）。
  final bool manualSort;
  final void Function(String draggedId, String targetId, bool before)?
      onReorderSession;

  @override
  Widget build(BuildContext context) {
    // 「当前」标记 = 含活跃会话的那个工作区（原型 04：行尾小字）
    final isCurrent = workspace.sessions.any((ss) => ss.active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          // 工作区操作（新建会话 / 从列表移除 / 路径）收进长按菜单，
          // 行面保持干净（原型 04，2026-10-25）
          onLongPress: () => _workspaceMenu(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: HSpace.sm, vertical: HSpace.sm + 2),
            child: Row(
              children: [
                Icon(
                  workspace.expanded
                      ? AppIcons.chevronDown
                      : AppIcons.chevronRight,
                  size: 22,
                  color: h.textFaint,
                ),
                const SizedBox(width: 2),
                Icon(
                  CupertinoIcons.folder_fill,
                  size: 19,
                  color: isCurrent ? h.text : h.textDim,
                ),
                const SizedBox(width: HSpace.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        workspace.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: h.text),
                      ),
                      // 常规副标题（已授权文件夹 / 路径尾）按原型去掉；
                      // 异常态仍要明说：失效（红字）与只读（警示色），
                      // 这是 2026-10-20 真机 bug 的教训，不能跟着一起删。
                      if (!workspace.exists)
                        Text(
                          '工作区已失效 · 文件夹不存在',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10.5,
                              color: HColors.errorOn(h.dark)),
                        )
                      else if (!workspace.writable)
                        Row(
                          children: [
                            Icon(CupertinoIcons.lock,
                                size: 12, color: HColors.warnOn(h.dark)),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                '只读（无法写入）',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: HColors.warnOn(h.dark)),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                if (isCurrent)
                  Text(
                    '当前',
                    style: TextStyle(fontSize: 11.5, color: h.textFaint),
                  ),
                const SizedBox(width: HSpace.xs),
              ],
            ),
          ),
        ),
        if (workspace.expanded)
          if (workspace.sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  46, HSpace.sm, HSpace.lg, HSpace.md),
              child: Text(
                '还没有会话\n直接发消息就会新建一个',
                style: TextStyle(
                    fontSize: 11.5, height: 1.55, color: h.textFaint),
              ),
            )
          else
            // 会话挂在工作区下：缩进列表 —— 每条会话前一根独立
            // 短竖，不再连成一条整线（2026-10-25 晚用户改）
            Padding(
              padding: const EdgeInsets.only(left: 33, right: HSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                    for (final ss in workspace.sessions)
                      _groupSessionRow(context, ss),
                ],
              ),
            ),
      ],
    );
  }


  /// 分组里的一行会话：手动排序时带拖拽手柄并套落点，
  /// 其余时候与从前完全一致。
  Widget _groupSessionRow(BuildContext context, HSession ss) {
    final row = _SessionRow(
      session: ss,
      h: h,
      selecting: selecting,
      selected: selectedKeys.contains((workspace.id, ss.id)),
      dragHandle:
          manualSort ? buildSessionDragHandle(h, workspace.id, ss) : null,
      onTap: selecting
          ? (ss.archived ? () {} : () => onToggleSelect?.call(ss.id))
          : () => onSelectSession(ss.id),
      onMenu: selecting
          ? (ss.archived ? () {} : () => onBatchMenu?.call(ss.id))
          : () => _sessionMenu(
                context,
                h,
                workspace,
                ss,
                (wid, sid) => onStar(sid),
                (wid, sid) => onRename(sid),
                (wid, sid) => onArchive(sid),
                (wid, sid) => onDelete(sid),
              ),
    );
    if (!manualSort) return row;
    return _ManualDropRow(
      workspaceId: workspace.id,
      target: ss,
      onMove: (dragged, targetId, before) =>
          onReorderSession?.call(dragged.sessionId, targetId, before),
      child: row,
    );
  }

  void _workspaceMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => BwSheetShell(
        onDismissRequest: () => Navigator.of(ctx).pop(),
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _bwSheetHandle(h),
              const SizedBox(height: 8),
              // 路径行：点按 → 在系统文件管理里打开这个文件夹
              // （宿主 fs.openFolder；打不开时外层 toast 如实提示）
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onOpenFolder == null
                    ? null
                    : () {
                        Navigator.of(ctx).pop();
                        onOpenFolder!.call();
                      },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.folder_fill,
                          size: 20, color: h.textDim),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          workspace.path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: h.textDim),
                        ),
                      ),
                      if (onOpenFolder != null) ...[
                        const SizedBox(width: 8),
                        Icon(AppIcons.chevronRight,
                            size: 14, color: h.textFaint),
                      ],
                    ],
                  ),
                ),
              ),
              _bwMenuRow(
                h,
                icon: AppIcons.add,
                label: '新建会话',
                onTap: () {
                  Navigator.of(ctx).pop();
                  onNewSession();
                },
              ),
              _bwMenuRow(
                h,
                icon: CupertinoIcons.minus_circle_fill,
                label: '从列表移除',
                subtitle: '不会删除文件夹本身',
                danger: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  onRemove();
                },
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// 手动排序的拖拽手柄（只包住手柄本身 —— 整行长按是会话
/// 菜单的地盘，不能抢）。长按手柄拖动，松手落点由行上的
/// [_ManualDropRow] 结算。
Widget buildSessionDragHandle(Hue h, String workspaceId, HSession s) {
  return LongPressDraggable<SessionDragData>(
    data: (workspaceId: workspaceId, sessionId: s.id),
    axis: Axis.vertical,
    feedback: Material(
      color: Colors.transparent,
      child: Container(
        width: 240,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: h.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: h.border),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 12),
          ],
        ),
        child: Text(
          s.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: h.text),
        ),
      ),
    ),
    childWhenDragging: Icon(Icons.drag_handle, size: 20, color: h.border),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Icon(Icons.drag_handle, size: 20, color: h.textFaint),
    ),
  );
}

/// 手动排序的落点行：同工作区的拖拽才接、自己不接自己；
/// 落点在行上半 → 插到目标之前，下半 → 之后（按行中心线分）。
class _ManualDropRow extends StatefulWidget {
  const _ManualDropRow({
    required this.workspaceId,
    required this.target,
    required this.onMove,
    required this.child,
  });

  final String workspaceId;
  final HSession target;
  final void Function(
    SessionDragData dragged,
    String targetSessionId,
    bool before,
  ) onMove;
  final Widget child;

  @override
  State<_ManualDropRow> createState() => _ManualDropRowState();
}

class _ManualDropRowState extends State<_ManualDropRow> {
  @override
  Widget build(BuildContext context) {
    return DragTarget<SessionDragData>(
      onWillAcceptWithDetails: (d) =>
          d.data.workspaceId == widget.workspaceId &&
          d.data.sessionId != widget.target.id,
      onAcceptWithDetails: (d) {
        final box = context.findRenderObject() as RenderBox?;
        var before = true;
        if (box != null) {
          final centerY =
              box.localToGlobal(Offset.zero).dy + box.size.height / 2;
          before = (d.offset.dy + 22) < centerY;
        }
        widget.onMove(d.data, widget.target.id, before);
      },
      builder: (_, _, _) => widget.child,
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.h,
    required this.onTap,
    required this.onMenu,
    this.subtitle,
    this.selecting = false,
    this.selected = false,
    this.dragHandle,
  });

  final HSession session;
  final Hue h;
  final VoidCallback onTap;

  /// 长按 → 会话菜单（收藏 / 重命名 / 归档 / 删除都在里面）。
  /// 行面上不再摆一排图标 —— 原型 04（2026-10-25 用户指定式样）。
  final VoidCallback onMenu;

  /// 单列表模式下显示归属工作区
  final String? subtitle;

  /// 多选模式：行首短竖换成勾选圈，点按改为勾选（由调用方换 onTap）。
  final bool selecting;
  final bool selected;

  /// 手动排序模式下行尾的拖拽手柄（调用方用 LongPressDraggable
  /// 包好递进来）；非手动模式为 null，行面与从前完全一致。
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final active = session.active;
    // 右侧小字（与标题同行）：[归属工作区 ·] 时间 [· 当前]。
    // 原来放第二行把行高撑得太高（2026-10-25 晚用户改到右侧）。
    final right = [
      ?subtitle,
      if (session.relativeTime.isNotEmpty) session.relativeTime,
      if (active) '当前',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        // 当前会话 = 整块浅灰高亮（原型 04）
        color: active ? h.surface : Colors.transparent,
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
                if (selecting && !session.archived)
                  // 多选：勾选圈（选中 = 实心 + 对勾，未选 = 描边空圈）。
                  // 已归档的**不给选** —— 归档会话后续归设置里管。
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? h.text : Colors.transparent,
                      border: Border.all(
                          color: selected ? h.text : h.border, width: 1.5),
                    ),
                    child: selected
                        ? Icon(CupertinoIcons.checkmark,
                            size: 12, color: h.bg)
                        : null,
                  )
                else
                  // 每条会话前一根独立短竖：当前 = 深色，其余 = 浅灰，
                  // 段与段之间断开，不连成整线。
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      color: active ? h.text : h.border,
                      borderRadius: BorderRadius.circular(1.5),
                    ),
                  ),
                const SizedBox(width: 10),
                if (session.starred)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(AppIcons.star,
                        size: 11, color: HColors.warnOn(h.dark)),
                  ),
                if (session.archived)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(CupertinoIcons.archivebox,
                        size: 13, color: h.textFaint),
                  ),
                Expanded(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          active ? FontWeight.w500 : FontWeight.w400,
                      color: h.text,
                    ),
                  ),
                ),
                if (right.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    right,
                    maxLines: 1,
                    style: TextStyle(fontSize: 11.5, color: h.textFaint),
                  ),
                ],
                if (dragHandle != null) ...[
                  const SizedBox(width: 2),
                  dragHandle!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
