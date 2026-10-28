/// **「选择分支」面板**（2026-10-28）—— 对齐 Trae 移动端的交互。
///
/// ## 参照样式（用户给的截图）
///
/// ```
/// ┌──────────────────────────────┐
/// │         选择分支               │
/// │  ┌────────────────────────┐  │
/// │  │ 🔍 搜索                 │  │
/// │  └────────────────────────┘  │
/// │  ○ frontend                  │
/// │  ○ gh-pages                  │
/// │  ✓ master                    │  ← 当前分支用 ✓
/// └──────────────────────────────┘
/// ```
///
/// ## 与旧实现的差别（为什么重做）
///
/// 旧的在「版本控制」面板里塞了一个「切换分支（N 个）」折叠区 ——
/// 用户要的是**点第三格直接选分支**，不是先开一个大面板再展开。
///
/// 现在：
/// · 点底部第三格 → 直接弹这个面板
/// · 顶上有搜索框（分支多的时候能搜）
/// · 未选中用空心圆 ○，当前用 ✓ —— 与 Trae 一致
/// · 点一行就切过去（能力层会拒绝脏工作区，原因如实显示）
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/bw_approval.dart';

/// 弹出「选择分支」面板。
///
/// @param current 当前分支名（打 ✓）
/// @param branches 可选分支名
/// @return 用户点选的分支名；`null` = 取消
Future<String?> showGitBranchSheet(
  BuildContext context, {
  required List<String> branches,
  required String? current,
}) async {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: _GitBranchSheet(
        h: Hue.of(context),
        branches: branches,
        current: current,
      ),
    ),
  );
}

class _GitBranchSheet extends StatefulWidget {
  const _GitBranchSheet({
    required this.h,
    required this.branches,
    required this.current,
  });

  final Hue h;
  final List<String> branches;
  final String? current;

  @override
  State<_GitBranchSheet> createState() => _GitBranchSheetState();
}

class _GitBranchSheetState extends State<_GitBranchSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _visible {
    if (_query.isEmpty) return widget.branches;
    final k = _query.toLowerCase();
    return [
      for (final b in widget.branches)
        if (b.toLowerCase().contains(k)) b,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            HSpace.lg, HSpace.xs, HSpace.lg, HSpace.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 抓手
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: HSpace.sm),
                decoration: BoxDecoration(
                  color: h.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 标题居中（与 Trae 一致）
            Text(
              '选择分支',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: h.text,
              ),
            ),
            const SizedBox(height: HSpace.md),

            // ---- 搜索 ----
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索',
                hintStyle: TextStyle(fontSize: 15, color: h.textFaint),
                prefixIcon:
                    Icon(CupertinoIcons.search, size: 18, color: h.textFaint),
                suffixIcon: _query.isEmpty
                    ? null
                    : GestureDetector(
                        onTap: () => _searchCtrl.clear(),
                        child: Icon(CupertinoIcons.clear_circled_solid,
                            size: 17, color: h.textFaint),
                      ),
                filled: true,
                fillColor: h.surfaceAlt,
                isDense: true,
                // 有边框（2026-10-28 用户指出：选择分支的搜索框没边框）
                // 与「选择仓库」面板的搜索框保持同一套样式。
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HRadius.pill),
                  borderSide: BorderSide(color: h.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HRadius.pill),
                  borderSide: BorderSide(color: h.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HRadius.pill),
                  borderSide: BorderSide(color: h.border),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: HSpace.md, vertical: 12),
              ),
              style: TextStyle(fontSize: 15, color: h.text),
            ),
            const SizedBox(height: HSpace.sm),

            // ---- 分支列表 ----
            //
            // 高度恒定：`BwSheetShell` 只在首帧量高度（真机踩过两次），
            // 列表区固定高度，空态/搜索无结果也不会让面板忽高忽矮。
            SizedBox(
              height: 320,
              child: _visible.isEmpty
                  ? Center(
                      child: Text(
                        widget.branches.isEmpty
                            ? '这个仓库还没有分支'
                            : '没有匹配「$_query」的分支',
                        style: TextStyle(fontSize: 13.5, color: h.textDim),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: _visible.length,
                      itemBuilder: (_, i) => _row(h, _visible[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行：未选中 ○ / 当前 ✓ + 分支名。
  Widget _row(Hue h, String name) {
    final isCurrent = name == widget.current;
    return InkWell(
      onTap: isCurrent ? null : () => Navigator.of(context).pop(name),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            // 未选中是空心圆；当前是 ✓（Trae 的样式）
            SizedBox(
              width: 22,
              child: isCurrent
                  ? Icon(CupertinoIcons.checkmark,
                      size: 19, color: h.text)
                  : Container(
                      width: 17,
                      height: 17,
                      margin: const EdgeInsets.only(left: 2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: h.border, width: 1.5),
                      ),
                    ),
            ),
            const SizedBox(width: HSpace.md),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  color: h.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
