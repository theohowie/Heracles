import 'package:flutter/material.dart';

import '../models/view_options.dart';
import '../models/workspace.dart';
import '../theme/app_theme.dart';

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
/// · 排序方式：最近更新（2026-10-19 删掉「按工作区树」与「手动排序」两个假选项）
/// · 筛选会话：隐藏已归档 / 全部对话 / 仅显示已归档
///
/// ## 与桌面版的差异（手机适配）
///
/// 桌面版用**悬浮**才显示行内操作。手机没有鼠标，所以**全部常驻显示**。
/// 侧边栏本体也是抽屉式滑出 —— 手机屏幕窄，常驻会挤掉对话区。
class WorkspaceDrawer extends StatelessWidget {
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
            const SizedBox(height: HSpace.md),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
              child: _NewSessionButton(
                h: h,
                onTap: () {
                  if (workspaces.isEmpty) {
                    onAddWorkspace?.call();
                    return;
                  }
                  onNewSession(workspaces.first.id);
                },
              ),
            ),
            const SizedBox(height: HSpace.md),

            // ⚠️ 2026-10-19：这里原有「插件 / 自动化任务 / 上下文洞察」三个入口，
            //   但它们的 `onTap` 都是空实现 —— 界面上承诺了、点了没反应。
            //   在真有功能之前**不画**（假入口比没有入口更伤信任）。
            const SizedBox(height: HSpace.sm),
            const Divider(height: 1),

            _SectionHeader(
              h: h,
              searching: searchQuery.isNotEmpty,
              onAdd: onAddWorkspace,
              onAddApp: onAddAppWorkspace,
              onSearch: () => _openSearch(context, h),
              onViewOptions: () => _openViewOptions(context, h),
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
                    Icon(Icons.settings_outlined, size: 18, color: h.textDim),
                    const SizedBox(width: HSpace.md + 2),
                    Text('设置',
                        style: TextStyle(fontSize: 14, color: h.textDim)),
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

  /// 应用搜索与筛选后的工作区列表
  List<HWorkspace> get _visible {
    final q = searchQuery.toLowerCase();
    final out = <HWorkspace>[];
    for (final w in workspaces) {
      final sessions = w.sessions.where((s) {
        if (!viewOptions.shows(s.archived)) return false;
        if (q.isEmpty) return true;
        return s.title.toLowerCase().contains(q);
      }).toList();
      out.add(w.copyWith(sessions: sessions));
    }
    return out;
  }

  Widget _body(BuildContext context, Hue h) {
    if (loading) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: h.textFaint),
        ),
      );
    }
    if (workspaces.isEmpty) return _empty(h);

    final visible = _visible;
    final hasAny = visible.any((w) => w.sessions.isNotEmpty);
    if (!hasAny) return _noResults(h);

    switch (viewOptions.grouping) {
      case SessionGrouping.flatList:
        return _flatList(context, visible, h);
      case SessionGrouping.byWorkspace:
        return _groupedList(context, visible, h);
    }
  }

  Widget _groupedList(BuildContext context, List<HWorkspace> visible, Hue h) {
    final rows = visible.where((w) => w.sessions.isNotEmpty).toList();
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
          onSelectSession: (sid) => onSelectSession(w.id, sid),
          onRename: (sid) => onRenameSession?.call(w.id, sid),
          onDelete: (sid) => onDeleteSession?.call(w.id, sid),
          onStar: (sid) => onToggleStar?.call(w.id, sid),
          onArchive: (sid) => onToggleArchive?.call(w.id, sid),
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
      padding: const EdgeInsets.only(bottom: HSpace.lg),
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final (w, s) = rows[i];
        return _SessionRow(
          session: s,
          h: h,
          subtitle: w.name,
          onTap: () => onSelectSession(w.id, s.id),
          onMenu: () => _sessionMenu(
            context,
            h,
            w,
            s,
            (wid, sid) => onToggleStar?.call(wid, sid),
            (wid, sid) => onRenameSession?.call(wid, sid),
            (wid, sid) => onToggleArchive?.call(wid, sid),
            (wid, sid) => onDeleteSession?.call(wid, sid),
          ),
          onDelete: () => onDeleteSession?.call(w.id, s.id),
          onStar: () => onToggleStar?.call(w.id, s.id),
        );
      },
    );
  }

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
              Icon(Icons.create_new_folder_outlined,
                  size: 34, color: h.textFaint),
              const SizedBox(height: HSpace.md),
              Text('还没有工作区',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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
              FilledButton.icon(
                onPressed: onAddWorkspace,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('选择文件夹'),
                style: FilledButton.styleFrom(
                  backgroundColor: h.accent,
                  foregroundColor: h.dark
                      ? const Color(0xFF1A0E08)
                      : const Color(0xFFFFFFFF),
                  padding: const EdgeInsets.symmetric(
                      horizontal: HSpace.xl, vertical: HSpace.md),
                ),
              ),
              // ★ 次要入口：内置「应用工作区」（2026-10-17）
              //
              // 空态是用户**第一次**进来的地方 —— 正好是解释
              // "为什么会有两种工作区"的最佳时机，而不是等他
              // 选了 /sdcard 的项目、构建失败了才去猜。
              if (onAddAppWorkspace != null) ...[
                const SizedBox(height: HSpace.md),
                TextButton.icon(
                  onPressed: onAddAppWorkspace,
                  icon: const Icon(Icons.android_rounded, size: 17),
                  label: const Text('使用默认工作区',
                      style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    foregroundColor: h.accent,
                    padding: const EdgeInsets.symmetric(
                        horizontal: HSpace.lg, vertical: HSpace.sm),
                  ),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _header(BuildContext context, Hue h) => Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.sm, 0),
        child: Row(
          children: [
            Icon(Icons.bolt_rounded, size: 20, color: h.accent),
            const SizedBox(width: HSpace.sm),
            Text(
              'Heracles',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: h.text,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.close_rounded, size: 20, color: h.textFaint),
              onPressed: onClose ?? () => Navigator.of(context).pop(),
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
                child: Icon(Icons.close_rounded, size: 14, color: h.textFaint),
              ),
            ),
          ],
        ),
      );

  // ------------------------------------------------------------ 搜索

  Future<void> _openSearch(BuildContext context, Hue h) async {
    final controller = TextEditingController(text: searchQuery);
    final q = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: h.surfaceAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HRadius.lg),
          side: BorderSide(color: h.border),
        ),
        title: Text('搜索会话', style: TextStyle(color: h.text, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: h.text),
          decoration: InputDecoration(
            hintText: '输入标题关键词',
            hintStyle: TextStyle(color: h.textFaint),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(''),
            style: TextButton.styleFrom(foregroundColor: h.textDim),
            child: const Text('清除'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            style: FilledButton.styleFrom(backgroundColor: h.accent),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    if (q != null) onSearchChanged(q.trim());
  }

  // ------------------------------------------------------------ 视图选项

  Future<void> _openViewOptions(BuildContext context, Hue h) async {
    var draft = viewOptions;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HRadius.lg)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget check(bool on) => on
              ? Icon(Icons.check_rounded, size: 18, color: h.accent)
              : const SizedBox(width: 18);

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _groupLabel(h, '分组方式'),
                  _opt(h, '按工作区', Icons.folder_outlined,
                      draft.grouping == SessionGrouping.byWorkspace, () {
                    setSheet(() => draft = draft.copyWith(
                        grouping: SessionGrouping.byWorkspace));
                  }, check),
                  _opt(h, '单列表', Icons.format_list_bulleted_rounded,
                      draft.grouping == SessionGrouping.flatList, () {
                    setSheet(() => draft = draft.copyWith(
                        grouping: SessionGrouping.flatList));
                  }, check),

                  const Divider(height: 1),
                  // ⚠️ 2026-10-19：删掉「按工作区树」（与「按工作区」行为完全相同）
                  //   与「手动排序」（没有拖拽实现）—— 两个**假选项**。
                  _groupLabel(h, '排序方式'),
                  _opt(h, '最近更新', Icons.schedule_rounded,
                      draft.sorting == SessionSorting.recent, () {
                    setSheet(() => draft =
                        draft.copyWith(sorting: SessionSorting.recent));
                  }, check),

                  const Divider(height: 1),
                  _groupLabel(h, '筛选会话'),
                  _opt(h, '隐藏已归档', Icons.archive_outlined,
                      draft.filter == SessionFilter.hideArchived, () {
                    setSheet(() => draft = draft.copyWith(
                        filter: SessionFilter.hideArchived));
                  }, check),
                  _opt(h, '全部对话（显示已归档）', Icons.forum_outlined,
                      draft.filter == SessionFilter.all, () {
                    setSheet(() => draft =
                        draft.copyWith(filter: SessionFilter.all));
                  }, check),
                  _opt(h, '仅显示已归档', Icons.inventory_2_outlined,
                      draft.filter == SessionFilter.onlyArchived, () {
                    setSheet(() => draft = draft.copyWith(
                        filter: SessionFilter.onlyArchived));
                  }, check),
                  const SizedBox(height: HSpace.sm),
                ],
              ),
            ),
          );
        },
      ),
    );

    // 关闭即提交 —— 单选无需"确定"按钮
    if (draft.grouping != viewOptions.grouping ||
        draft.sorting != viewOptions.sorting ||
        draft.filter != viewOptions.filter) {
      onViewOptionsChanged(draft);
    }
  }

  Widget _groupLabel(Hue h, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(
            HSpace.xl, HSpace.lg, HSpace.xl, HSpace.xs),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: h.textFaint,
            letterSpacing: 0.5,
          ),
        ),
      );

  Widget _opt(
    Hue h,
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
    Widget Function(bool) check,
  ) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HSpace.xl, vertical: HSpace.md),
          child: Row(
            children: [
              Icon(icon, size: 18, color: selected ? h.text : h.textDim),
              const SizedBox(width: HSpace.md + 2),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? h.text : h.textDim,
                  ),
                ),
              ),
              check(selected),
            ],
          ),
        ),
      );
}

// ------------------------------------------------------------ 会话菜单

/// 会话的底部菜单。
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
    backgroundColor: h.surfaceAlt,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(HRadius.lg)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              s.starred ? Icons.star_rounded : Icons.star_border_rounded,
              color: s.starred ? HColors.warnOn(h.dark) : h.textDim,
            ),
            title: Text(s.starred ? '取消收藏' : '收藏',
                style: TextStyle(color: h.text)),
            onTap: () {
              Navigator.of(ctx).pop();
              onStar(w.id, s.id);
            },
          ),
          ListTile(
            leading: Icon(Icons.drive_file_rename_outline_rounded,
                color: h.textDim),
            title: Text('重命名', style: TextStyle(color: h.text)),
            onTap: () {
              Navigator.of(ctx).pop();
              onRename(w.id, s.id);
            },
          ),
          ListTile(
            leading: Icon(Icons.archive_outlined, color: h.textDim),
            title: Text(s.archived ? '取消归档' : '归档',
                style: TextStyle(color: h.text)),
            subtitle: Text('归档后默认隐藏',
                style: TextStyle(fontSize: 11, color: h.textFaint)),
            onTap: () {
              Navigator.of(ctx).pop();
              onArchive(w.id, s.id);
            },
          ),
          ListTile(
            leading:
                Icon(Icons.delete_outline_rounded, color: HColors.errorOn(h.dark)),
            title: Text('删除',
                style: TextStyle(color: HColors.errorOn(h.dark))),
            onTap: () {
              Navigator.of(ctx).pop();
              onDelete(w.id, s.id);
            },
          ),
          const SizedBox(height: HSpace.sm),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------ 小组件

class _NewSessionButton extends StatelessWidget {
  const _NewSessionButton({required this.onTap, required this.h});

  final VoidCallback onTap;
  final Hue h;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HRadius.lg),
        child: Container(
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HRadius.lg),
            border: Border.all(color: h.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline_rounded, size: 18, color: h.text),
              const SizedBox(width: HSpace.sm),
              Text('新会话',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: h.text)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.h,
    required this.searching,
    this.onAdd,
    this.onAddApp,
    this.onSearch,
    this.onViewOptions,
  });

  final Hue h;
  final bool searching;
  final VoidCallback? onAdd;

  /// 登记内置「应用工作区」（可构建）—— 与 [onAdd] 并列的第二项
  final VoidCallback? onAddApp;

  final VoidCallback? onSearch;
  final VoidCallback? onViewOptions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.xl, HSpace.md, HSpace.sm, 0),
      child: Row(
        children: [
          Text(
            '工作区',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: h.textFaint,
              letterSpacing: 0.6,
            ),
          ),
          const Spacer(),
          _MiniAction(
            icon: Icons.search_rounded,
            h: h,
            color: searching ? h.accent : null,
            onTap: onSearch,
          ),
          // ★ 视图选项 —— 之前是空实现，现在真的能改分组/排序/筛选
          _MiniAction(icon: Icons.tune_rounded, h: h, onTap: onViewOptions),
          // ★★ ⊕ = **两项菜单**（2026-10-17）★★
          //
          // ## 为什么一项不够
          //
          // SAF 选不到 `Android/data`（系统限制），而那里正是真机上
          // **唯一** App 与 shell 都能写 —— 因而**能构建**的位置。
          // 用户如果用 /sdcard 上的项目，构建必然失败（App 写不了）。
          //
          // 所以给两个入口：
          // <br>· 选文件夹 —— 用户自己的项目（不一定能构建）
          // <br>· 应用工作区 —— 内置的、能构建的目录
          _AddWorkspaceMenu(h: h, onPickFolder: onAdd, onAddApp: onAddApp),
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
    return PopupMenuButton<String>(
      tooltip: '添加工作区',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 36),
      color: h.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HRadius.md),
        side: BorderSide(color: h.border),
      ),
      onSelected: (v) {
        if (v == 'folder') onPickFolder?.call();
        if (v == 'app') onAddApp?.call();
      },
      itemBuilder: (_) => [
        _item(
          value: 'folder',
          icon: Icons.folder_open_rounded,
          title: '选择文件夹',
        ),
        _item(
          value: 'app',
          icon: Icons.android_rounded,
          title: '默认工作区',
        ),
      ],
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(Icons.create_new_folder_outlined,
            size: 17, color: h.textFaint),
      ),
    );
  }

  PopupMenuItem<String> _item({
    required String value,
    required IconData icon,
    required String title,
  }) =>
      PopupMenuItem<String>(
        value: value,
        height: 48,
        child: Row(
          children: [
            Icon(icon, size: 18, color: h.textDim),
            const SizedBox(width: HSpace.sm + 2),
            Expanded(
              child: Text(title,
                  style: TextStyle(fontSize: 13.5, color: h.text)),
            ),
          ],
        ),
      );
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.h,
    this.onTap,
    this.color,
    this.size = 36,
  });

  final IconData icon;
  final Hue h;
  final VoidCallback? onTap;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HRadius.sm),
          child: Icon(icon, size: size <= 30 ? 16 : 17, color: color ?? h.textFaint),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(HSpace.sm, 0, HSpace.xs, 0),
            child: Row(
              children: [
                Icon(
                  workspace.expanded
                      ? Icons.arrow_drop_down_rounded
                      : Icons.arrow_right_rounded,
                  size: 22,
                  color: h.textFaint,
                ),
                const SizedBox(width: 2),
                Icon(Icons.folder_rounded, size: 17, color: h.accent),
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
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: h.text),
                      ),
                      if (!workspace.writable)
                        Row(
                          children: [
                            Icon(Icons.lock_outline_rounded,
                                size: 11, color: HColors.warnOn(h.dark)),
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
                        )
                      else
                        // 用户选的文件夹没有真实路径可展示时，如实说明来源
                        Text(
                          workspace.isSaf
                              ? '已授权文件夹'
                              : _tail(workspace.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: h.textFaint),
                        ),
                    ],
                  ),
                ),
                _MiniAction(
                  icon: Icons.more_horiz_rounded,
                  h: h,
                  onTap: () => _workspaceMenu(context),
                ),
                _MiniAction(
                    icon: Icons.add_rounded, h: h, onTap: onNewSession),
              ],
            ),
          ),
        ),

        if (workspace.expanded)
          if (workspace.sessions.isEmpty)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(50, HSpace.sm, HSpace.lg, HSpace.md),
              child: Text(
                '还没有会话\n直接发消息就会新建一个',
                style: TextStyle(
                    fontSize: 11.5, height: 1.55, color: h.textFaint),
              ),
            )
          else
            ...workspace.sessions.map(
              (s) => _SessionRow(
                session: s,
                h: h,
                onTap: () => onSelectSession(s.id),
                onMenu: () => _sessionMenu(
                  context,
                  h,
                  workspace,
                  s,
                  (wid, sid) => onStar(sid),
                  (wid, sid) => onRename(sid),
                  (wid, sid) => onArchive(sid),
                  (wid, sid) => onDelete(sid),
                ),
                onDelete: () => onDelete(s.id),
                onStar: () => onStar(s.id),
              ),
            ),
      ],
    );
  }

  static String _tail(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return path;
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  void _workspaceMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(HRadius.lg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.folder_open_rounded, color: h.textDim),
              title: Text(
                workspace.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: h.textDim),
              ),
            ),
            ListTile(
              leading: Icon(Icons.add_rounded, color: h.accent),
              title: Text('新建会话', style: TextStyle(color: h.text)),
              onTap: () {
                Navigator.of(ctx).pop();
                onNewSession();
              },
            ),
            ListTile(
              leading: Icon(Icons.remove_circle_outline_rounded,
                  color: HColors.errorOn(h.dark)),
              title: Text('从列表移除',
                  style: TextStyle(color: HColors.errorOn(h.dark))),
              subtitle: Text('不会删除文件夹本身',
                  style: TextStyle(fontSize: 11, color: h.textFaint)),
              onTap: () {
                Navigator.of(ctx).pop();
                onRemove();
              },
            ),
            const SizedBox(height: HSpace.sm),
          ],
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.h,
    required this.onTap,
    required this.onMenu,
    required this.onDelete,
    required this.onStar,
    this.subtitle,
  });

  final HSession session;
  final Hue h;
  final VoidCallback onTap;
  final VoidCallback onMenu;
  final VoidCallback onDelete;
  final VoidCallback onStar;

  /// 单列表模式下显示归属工作区
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final active = session.active;
    final grouped = subtitle == null;

    return Padding(
      padding: EdgeInsets.only(left: grouped ? 22 : 0),
      child: Row(
        children: [
          if (grouped)
            Container(
              width: 2,
              height: 42,
              decoration: BoxDecoration(
                color: active ? h.accent : h.border,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          if (grouped) const SizedBox(width: HSpace.sm),

          // 会话主体必须在 Expanded 里，否则右侧图标会被挤出屏幕
          Expanded(
            child: Material(
              color: active ? h.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(HRadius.sm),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(HRadius.sm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: HSpace.md, vertical: HSpace.sm + 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (session.archived)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.inventory_2_outlined,
                                  size: 12, color: h.textFaint),
                            ),
                          Expanded(
                            child: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight:
                                    active ? FontWeight.w600 : FontWeight.w400,
                                color: active ? h.text : h.textDim,
                              ),
                            ),
                          ),
                          if (session.relativeTime.isNotEmpty) ...[
                            const SizedBox(width: HSpace.sm),
                            Text(
                              session.relativeTime,
                              style:
                                  TextStyle(fontSize: 11, color: h.textFaint),
                            ),
                          ],
                        ],
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: h.textFaint),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          _MiniAction(
            icon: session.starred
                ? Icons.star_rounded
                : Icons.star_border_rounded,
            h: h,
            size: 30,
            color: session.starred ? HColors.warnOn(h.dark) : null,
            onTap: onStar,
          ),
          _MiniAction(
            icon: Icons.delete_outline_rounded,
            h: h,
            size: 30,
            onTap: onDelete,
          ),
          _MiniAction(
            icon: Icons.more_horiz_rounded,
            h: h,
            size: 30,
            onTap: onMenu,
          ),
          const SizedBox(width: HSpace.xs),
        ],
      ),
    );
  }
}
