import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

/// 模型与思考半抽屉（原型 09，2026-10-25 晚按用户对照图六再对齐）。
///
/// 结构（自上而下）：
/// - 抓手
/// - 标题行「模型」+ 右上 × 关闭；副标题「切换后对新消息生效」
/// - 模型单选行：单选圆圈 + 名称（主）+ 说明（副），行间细分隔线；
///   当前项带「当前」徽标、端侧项带「端侧」徽标，配了模型目录的
///   带 ›（点进去选具体模型，沿用 2026-10-14 用户要求的两层结构）
/// - 分组「思考等级」+ 分段条（五档）；协议不区分档位时（后端 rLv
///   如实标注）只给开/关两段，不假装五档
///
/// **最大轮次不在这里改**（2026-10-25 用户明确定：「不要在这个模型
/// 抽屉里改」）—— 唯一入口在通用设置页的分段选择。选择语义不变：
/// 点选即生效并收起；选同一档不回调（不产生无意义写盘）；
/// 未配置（无 Key）的服务商不渲染。
Future<void> showModelSheet(
  BuildContext context, {
  required List<ModelProviderConfig> providers,
  required String? activeProviderId,
  required ReasoningLevel reasoningLevel,
  ValueChanged<String>? onProviderSelected,
  ValueChanged<String>? onOpenModelCatalog,
  ValueChanged<ReasoningLevel>? onReasoningLevelChanged,
}) async {
  final h = Hue.of(context);
  // ★ 思考档位是否真生效（后端如实标注）：Anthropic / Responses 轨
  //   不读 reasoning_effort ⇒ 只给开/关两态。数据优先吃能力快照
  //   （rLv），没有快照时按 provider 协议推导。
  var levelsEffective = true;
  final activeProvider =
      providers.where((p) => p.id == activeProviderId).firstOrNull;
  if (activeProvider != null) {
    levelsEffective =
        activeProvider.modelCapabilities[activeProvider.model]
                ?.reasoningLevelsEffective ??
            activeProvider.protocol.reasoningLevelsEffective;
  }
  final visible = providers
      .where((p) => p.isConfigured || AppSettings.isLocalConfig(p))
      .toList();

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: h.surfaceAlt,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: SingleChildScrollView(
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '模型',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: h.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '切换后对新消息生效',
                          style: TextStyle(fontSize: 12, color: h.textFaint),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(sheetCtx).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: h.surface,
                        shape: BoxShape.circle,
                      ),
                      child:
                          Icon(AppIcons.close, size: 13, color: h.textDim),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < visible.length; i++) ...[
                if (i > 0)
                  Divider(height: 1, indent: 36, color: h.border),
                _ModelRadioRow(
                  h: h,
                  title: visible[i].model.isNotEmpty
                      ? visible[i].model
                      : visible[i].name,
                  subtitle: [
                    if (visible[i].model.isNotEmpty) visible[i].name,
                    if (visible[i].modelCatalog.isNotEmpty)
                      '模型目录 · ${visible[i].modelCatalog.length} 个',
                    if (AppSettings.isLocalConfig(visible[i])) '端侧运行',
                  ].join(' · '),
                  hasCatalog: visible[i].modelCatalog.isNotEmpty,
                  active: visible[i].id == activeProviderId,
                  isLocal: AppSettings.isLocalConfig(visible[i]),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    // 配了模型目录 → 进目录选具体模型（选中即切
                    // provider + 换模型）；否则点选即切换。
                    if (visible[i].modelCatalog.isNotEmpty) {
                      onOpenModelCatalog?.call(visible[i].id);
                    } else {
                      onProviderSelected?.call(visible[i].id);
                    }
                  },
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '思考等级',
                style: HTxt.sectionTitle.copyWith(color: h.text),
              ),
              const SizedBox(height: 10),
              if (levelsEffective)
                _SegBar(
                  h: h,
                  labels: [for (final v in ReasoningLevel.values) v.label],
                  selected: ReasoningLevel.values.indexOf(reasoningLevel),
                  onSelected: (i) {
                    final v = ReasoningLevel.values[i];
                    Navigator.of(sheetCtx).pop();
                    if (v != reasoningLevel) {
                      onReasoningLevelChanged?.call(v);
                    }
                  },
                )
              else
                _SegBar(
                  h: h,
                  labels: const ['关', '开'],
                  selected: reasoningLevel == ReasoningLevel.off ? 0 : 1,
                  onSelected: (i) {
                    Navigator.of(sheetCtx).pop();
                    if (i == 0 && reasoningLevel != ReasoningLevel.off) {
                      onReasoningLevelChanged?.call(ReasoningLevel.off);
                    }
                    if (i == 1 && reasoningLevel == ReasoningLevel.off) {
                      onReasoningLevelChanged?.call(ReasoningLevel.auto);
                    }
                  },
                ),
              const SizedBox(height: 8),
              Text(
                levelsEffective
                    ? reasoningLevel.description
                    : '当前协议不区分思考档位（低 / 高 / 最大不生效），只有开和关。',
                style: TextStyle(fontSize: 12, height: 1.4, color: h.textDim),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 模型单选行（图六形态）：单选圆圈 + 名称/说明 + 徽标/箭头。
/// 选中 = 圆圈描边加粗 + 中心实点 + 名称加粗。
class _ModelRadioRow extends StatelessWidget {
  const _ModelRadioRow({
    required this.h,
    required this.title,
    required this.subtitle,
    required this.hasCatalog,
    required this.active,
    required this.isLocal,
    required this.onTap,
  });

  final Hue h;
  final String title;
  final String subtitle;
  final bool hasCatalog;
  final bool active;
  final bool isLocal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? h.text : h.border,
                  width: active ? 2 : 1.5,
                ),
              ),
              child: active
                  ? Center(
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: h.text,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.w400,
                      color: h.text,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: h.textFaint),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (active)
              _Badge(h: h, label: '当前')
            else if (isLocal)
              _Badge(h: h, label: '端侧'),
            if (hasCatalog) ...[
              const SizedBox(width: 6),
              Icon(AppIcons.chevronRight, size: 17, color: h.textFaint),
            ],
          ],
        ),
      ),
    );
  }
}

/// 行尾徽标（当前 / 端侧）：浅底胶囊，两者同式（图六）。
class _Badge extends StatelessWidget {
  const _Badge({required this.h, required this.label});

  final Hue h;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: h.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: h.textDim,
        ),
      ),
    );
  }
}

/// 分段条（图六形态）：灰轨 + 选中白片（深色轨上则为浅灰片）。
class _SegBar extends StatelessWidget {
  const _SegBar({
    required this.h,
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final Hue h;
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: h.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelected(i),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color:
                        i == selected ? h.surfaceAlt : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: i == selected
                        ? [
                            BoxShadow(
                              color:
                                  Colors.black.withValues(alpha: 0.08),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          i == selected ? FontWeight.w600 : FontWeight.w400,
                      color: i == selected ? h.text : h.textDim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
