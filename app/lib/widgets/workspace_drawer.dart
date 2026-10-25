import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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
            const SizedBox(height: HSpace.sm),

            // ⚠️ 2026-10-19：这里原有「插件 / 自动化任务 / 上下文洞察」三个入口，
            //   但它们的 `onTap` 都是空实现 —— 界面上承诺了、点了没反应。
            //   在真有功能之前**不画**（假入口比没有入口更伤信任）。
            _SectionHeader(
              h: h,
              searching: searchQuery.isNotEmpty,
              onAdd: onAddWorkspace,
              onAddApp: onAddAppWorkspace,
              onSearch: () => _openSearch(context),
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
                      Icon(CupertinoIcons.phone, size: 18, color: h.accent),
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

  // ------------------------------------------------------------ 搜索

  Future<void> _openSearch(BuildContext context) async {
    // 2026-10-25：居中弹窗改上拉输入抽屉（清除 = 返回空串，沿用旧语义）
    final q = await showBwTextInputSheet(
      context,
      title: '搜索会话',
      initial: searchQuery,
      placeholder: '输入标题关键词',
      confirmLabel: '搜索',
      clearLabel: '清除',
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
              ? Icon(AppIcons.check, size: 19, color: h.accent)
              : const SizedBox(width: 19);

          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _groupLabel(h, '分组方式'),
                  _opt(h, '按工作区', AppIcons.folder,
                      draft.grouping == SessionGrouping.byWorkspace, () {
                    setSheet(() => draft = draft.copyWith(
                        grouping: SessionGrouping.byWorkspace));
                  }, check),
                  _opt(h, '单列表', CupertinoIcons.list_bullet,
                      draft.grouping == SessionGrouping.flatList, () {
                    setSheet(() => draft = draft.copyWith(
                        grouping: SessionGrouping.flatList));
                  }, check),

                  const Divider(height: 1),
                  // ⚠️ 2026-10-19：删掉「按工作区树」（与「按工作区」行为完全相同）
                  //   与「手动排序」（没有拖拽实现）—— 两个**假选项**。
                  _groupLabel(h, '排序方式'),
                  _opt(h, '最近更新', AppIcons.clock,
                      draft.sorting == SessionSorting.recent, () {
                    setSheet(() => draft =
                        draft.copyWith(sorting: SessionSorting.recent));
                  }, check),

                  const Divider(height: 1),
                  _groupLabel(h, '筛选会话'),
                  _opt(h, '隐藏已归档', CupertinoIcons.archivebox,
                      draft.filter == SessionFilter.hideArchived, () {
                    setSheet(() => draft = draft.copyWith(
                        filter: SessionFilter.hideArchived));
                  }, check),
                  _opt(h, '全部对话（显示已归档）', CupertinoIcons.chat_bubble_2,
                      draft.filter == SessionFilter.all, () {
                    setSheet(() => draft =
                        draft.copyWith(filter: SessionFilter.all));
                  }, check),
                  _opt(h, '仅显示已归档', CupertinoIcons.archivebox_fill,
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
            fontWeight: FontWeight.w500,
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
              Icon(icon, size: 19, color: selected ? h.text : h.textDim),
              const SizedBox(width: HSpace.md + 2),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
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
    backgroundColor: h.surfaceAlt,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
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

/// 统一抽屉菜单行：填充图标 + 标题（+ 可选副标题）；
/// [danger] = 图标与文字一起语义红（删除类）。
Widget _bwMenuRow(
  Hue h, {
  required IconData icon,
  required String label,
  String? subtitle,
  Color? iconColor,
  bool danger = false,
  required VoidCallback onTap,
}) {
  final err = HColors.errorOn(h.dark);
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        children: [
          Icon(icon,
              size: 20, color: danger ? err : (iconColor ?? h.textDim)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style:
                        TextStyle(fontSize: 15, color: danger ? err : h.text)),
                if (subtitle != null)
                  Text(subtitle,
                      style: TextStyle(fontSize: 11.5, color: h.textFaint)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------ 小组件

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
              fontWeight: FontWeight.w500,
              color: h.textFaint,
              letterSpacing: 0.6,
            ),
          ),
          const Spacer(),
          _MiniAction(
            icon: AppIcons.search,
            h: h,
            color: searching ? h.accent : null,
            onTap: onSearch,
          ),
          // ★ 视图选项 —— 之前是空实现，现在真的能改分组/排序/筛选
          _MiniAction(icon: CupertinoIcons.slider_horizontal_3, h: h, onTap: onViewOptions),
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
          icon: CupertinoIcons.folder_open,
          title: '选择文件夹',
        ),
        _item(
          value: 'app',
          icon: CupertinoIcons.phone,
          title: '默认工作区',
        ),
      ],
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(CupertinoIcons.folder_badge_plus,
            size: 18, color: h.textFaint),
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
            Icon(icon, size: 19, color: h.textDim),
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
                      _SessionRow(
                        session: ss,
                        h: h,
                        onTap: () => onSelectSession(ss.id),
                        onMenu: () => _sessionMenu(
                          context,
                          h,
                          workspace,
                          ss,
                          (wid, sid) => onStar(sid),
                          (wid, sid) => onRename(sid),
                          (wid, sid) => onArchive(sid),
                          (wid, sid) => onDelete(sid),
                        ),
                      ),
                ],
              ),
            ),
      ],
    );
  }


  void _workspaceMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _bwSheetHandle(h),
              const SizedBox(height: 8),
              // 路径（只读信息行，不可点）
              Padding(
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
                  ],
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
  });

  final HSession session;
  final Hue h;
  final VoidCallback onTap;

  /// 长按 → 会话菜单（收藏 / 重命名 / 归档 / 删除都在里面）。
  /// 行面上不再摆一排图标 —— 原型 04（2026-10-25 用户指定式样）。
  final VoidCallback onMenu;

  /// 单列表模式下显示归属工作区
  final String? subtitle;

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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
