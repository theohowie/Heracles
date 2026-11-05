// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// 模型目录行 + 展开面板（2026-11-05 用户要求）：
//   · 删除按钮**左边**加一个 chevron（向下展开）；
//   · 展开后填「上下文窗口」与「最大输出 token 数」。
//
// 单独放一个 widget 而不是往 settings_screen 里再塞 60 行：
// 那个文件已经 4900+ 行，再长就没人敢动了（AGENTS §"文件太长就是信号"）。
library;

import 'package:flutter/cupertino.dart';

import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

/// 目录里的一行模型：点行 = 选用；chevron = 展开限额面板；trash = 从目录移除。
class ModelCatalogRow extends StatelessWidget {
  const ModelCatalogRow({
    super.key,
    required this.id,
    required this.selected,
    required this.expanded,
    required this.contextLength,
    required this.maxOutput,
    required this.onSelect,
    required this.onToggleExpand,
    required this.onRemove,
    this.contextPlaceholder = '128K',
    this.maxOutputPlaceholder = '16K',
  });

  final String id;
  final bool selected;
  final bool expanded;
  final TextEditingController contextLength;
  final TextEditingController maxOutput;
  final VoidCallback onSelect;
  final VoidCallback onToggleExpand;
  final VoidCallback onRemove;

  /// 占位提示 = **默认/已获取的值**（用户要求：输入框自己展示填好的默认值）。
  final String contextPlaceholder;
  final String maxOutputPlaceholder;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Column(
      children: [
        CupertinoListTile(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          title: Text(
            id,
            style: TextStyle(
              fontSize: 13,
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFallback,
              color: selected ? h.accent : h.text,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ★ 展开/收起（在删除按钮左边，用户指定的位置）
              CupertinoButton(
                padding: const EdgeInsets.all(6),
                minimumSize: const Size(0, 28),
                onPressed: onToggleExpand,
                child: Icon(
                  expanded
                      ? CupertinoIcons.chevron_down
                      : CupertinoIcons.chevron_right,
                  size: 16,
                  color: h.textDim,
                ),
              ),
              if (selected)
                Icon(AppIcons.check, size: 17, color: h.accent)
              else
                CupertinoButton(
                  padding: const EdgeInsets.all(6),
                  minimumSize: const Size(0, 28),
                  onPressed: onRemove,
                  child: Icon(AppIcons.trash, size: 18, color: h.textFaint),
                ),
            ],
          ),
          onTap: onSelect,
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '这个模型的上游额度（留空 = 用契约默认：窗口 128K / 输出 16384）',
                  style: TextStyle(fontSize: 11, color: h.textFaint),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _num(
                        h,
                        contextLength,
                        '上下文窗口，如 1M / 128K / 131072'
                            '（默认 $contextPlaceholder）',
                      ),
                    ),
                    const SizedBox(width: HSpace.sm),
                    Expanded(
                      child: _num(h, maxOutput,
                          '最大输出，如 32K / 32768（默认 $maxOutputPlaceholder）'),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _num(Hue h, TextEditingController c, String placeholder) =>
      CupertinoTextField(
        controller: c,
        keyboardType: TextInputType.number,
        style: TextStyle(fontSize: 13, color: h.text),
        placeholder: placeholder,
        placeholderStyle: TextStyle(fontSize: 11, color: h.textFaint),
        padding: const EdgeInsets.symmetric(
            horizontal: HSpace.sm, vertical: HSpace.xs),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HRadius.sm),
          border: Border.all(color: h.border),
        ),
      );
}
