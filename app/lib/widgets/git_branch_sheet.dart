/// **「选择分支」面板**（2026-10-28）—— 对齐 Trae 移动端的交互。
///
/// ## 布局（标题左对齐，与「选择仓库」统一）
///
/// ```
/// ┌──────────────────────────────┐
/// │  选择分支                     │  ← 左对齐
/// │  ┌────────────────────────┐  │
/// │  │ 🔍 搜索                 │  │  ← 有边框
/// │  └────────────────────────┘  │
/// │  ○ frontend                  │
/// │  ○ gh-pages                  │
/// │  ✓ master                    │
/// └──────────────────────────────┘
/// ```
///
/// ## ★ 打开必须"立刻出现"（2026-10-28 用户反馈"弹抽屉有点慢"）
///
/// 第一版是**先把分支全查完再弹面板**：
///
/// ```
/// 点第三格 → 过通道拿工作区 → 打开仓库读分支 → 打 GitHub API → 才弹面板
/// ```
///
/// 仓库没下载时最后那步是**网络请求**（几百毫秒到一秒），用户看到的是
/// "点了没反应"。这是典型的**把等待放在交互前面**。
///
/// 现在反过来：**面板立刻弹**（骨架已在），分支数据由 [loader] 在面板里
/// 异步加载 —— 用户马上看见搜索框和标题，列表位置先显示"读取中…"。
///
/// 另外 `current` 由调用方**同步传入**（它已经在状态里）⇒ 当前分支的 ✓
/// 不需要等加载就能显示。
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/bw_approval.dart';

/// 弹出「选择分支」面板。
///
/// @param loader 异步取分支名（本地读仓库 / 远端打 API 都行）
/// @param current 当前分支名（**同步**传入，用于显示 ✓）
/// @return 用户点选的分支名；`null` = 取消
Future<String?> showGitBranchSheet(
  BuildContext context, {
  required Future<List<String>> Function() loader,
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
        loader: loader,
        current: current,
      ),
    ),
  );
}

class _GitBranchSheet extends StatefulWidget {
  const _GitBranchSheet({
    required this.h,
    required this.loader,
    required this.current,
  });

  final Hue h;
  final Future<List<String>> Function() loader;
  final String? current;

  @override
  State<_GitBranchSheet> createState() => _GitBranchSheetState();
}

class _GitBranchSheetState extends State<_GitBranchSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  List<String> _all = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text.trim();
      if (q != _query) setState(() => _query = q);
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final r = await widget.loader();
      if (!mounted) return;
      setState(() {
        _all = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _all = const [];
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _visible {
    if (_query.isEmpty) return _all;
    final k = _query.toLowerCase();
    return [
      for (final b in _all)
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
            // 标题左对齐（与「选择仓库」统一）
            Text(
              '选择分支',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
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
                // 有边框（与「选择仓库」同一套样式）
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

            // ---- 分支列表（高度恒定，避免面板忽高忽矮）----
            SizedBox(
              height: 320,
              child: _loading
                  ? Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: h.accent),
                          ),
                          const SizedBox(width: HSpace.sm),
                          Text('读取分支…',
                              style:
                                  TextStyle(fontSize: 13, color: h.textDim)),
                        ],
                      ),
                    )
                  : _visible.isEmpty
                      ? Center(
                          child: Text(
                            _all.isEmpty
                                ? '这个仓库还没有分支'
                                : '没有匹配「$_query」的分支',
                            style:
                                TextStyle(fontSize: 13.5, color: h.textDim),
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
            SizedBox(
              width: 22,
              child: isCurrent
                  ? Icon(CupertinoIcons.checkmark, size: 19, color: h.text)
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
