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
/// │  ◯ frontend   （边框选项卡）  │
/// │  ◉ master     （选中黑边框）  │
/// │  [＋ 新建分支] [提交与推送]   │  ← 并排黑按钮
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

/// 「提交与推送」被点中时，`showGitBranchSheet` 返回这个哨兵值。
///
/// ## 为什么用哨兵而不是回调直接开面板（2026-10-28 真机 bug）
///
/// 第一版是 `onTap: () { Navigator.pop(); onAdvanced!(); }` ——
/// **pop 的动画还没结束就弹下一个抽屉**，Flutter 会忽略后一个
/// `showModalBottomSheet` ⇒ 用户看到"点了没反应"。
///
/// 改成弹哨兵：面板彻底关闭、`await` 返回之后，调用方再开版本控制面板，
/// 顺序确定。同时 `null` 仍然表示"用户取消"，语义不混。
const String gitBranchSheetAdvanced = '\u0000advanced';

/// 「新建分支」被点中时的哨兵。
const String gitBranchSheetCreate = '\u0000create';

/// 弹出「选择分支」面板。
///
/// @param loader 异步取分支名（本地读仓库 / 远端打 API 都行）
/// @param current 当前分支名（**同步**传入，用于显示 ✓）
/// @return 用户点选的分支名；`null` = 取消
Future<String?> showGitBranchSheet(
  BuildContext context, {
  required Future<List<String>> Function() loader,
  required String? current,
  /// 「提交 / 推送」入口（2026-10-28 补）。
  ///
  /// 第三格现在直接开这个面板，原来「版本控制」大面板就没有入口了 ——
  /// 提交/推送必须有个地方去。放在面板底部，符合"选分支时顺手提交"的动线。
  VoidCallback? onAdvanced,
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
        onAdvanced: onAdvanced,
      ),
    ),
  );
}

class _GitBranchSheet extends StatefulWidget {
  const _GitBranchSheet({
    required this.h,
    required this.loader,
    required this.current,
    this.onAdvanced,
  });

  final Hue h;
  final Future<List<String>> Function() loader;
  final String? current;
  final VoidCallback? onAdvanced;

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

            // ---- 底部动作（2026-10-29 用户定版）：不再上下两层
            // 无样式的文字行 —— 新建分支 / 提交与推送并排两个
            // 黑色实心按钮（无「提交与推送」入口时新建分支占满整行）。
            const SizedBox(height: HSpace.sm),
            Row(
              children: [
                Expanded(
                  child: _blackButton(
                    h,
                    icon: CupertinoIcons.add,
                    label: '新建分支',
                    onTap: () =>
                        Navigator.of(context).pop(gitBranchSheetCreate),
                  ),
                ),
                if (widget.onAdvanced != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: _blackButton(
                      h,
                      icon: CupertinoIcons.cloud_upload,
                      label: '提交与推送',
                      onTap: () =>
                          Navigator.of(context).pop(gitBranchSheetAdvanced),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 一行 = 全 App 统一的边框选项卡（BwOptionCard）：当前分支
  /// 选中态（主文本色边框 + 实心点），点选其余分支即切换。
  Widget _row(Hue h, String name) {
    final isCurrent = name == widget.current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BwOptionCard(
        h: h,
        selected: isCurrent,
        title: name,
        onTap: isCurrent ? () {} : () => Navigator.of(context).pop(name),
      ),
    );
  }

  /// 底部黑色实心按钮（新建分支 / 提交与推送同式）。
  Widget _blackButton(
    Hue h, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final fg = h.dark ? const Color(0xFF0A0A0B) : Colors.white;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: h.text,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
