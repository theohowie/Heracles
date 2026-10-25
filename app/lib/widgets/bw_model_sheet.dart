import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

/// 模型与思考半抽屉（原型 09，2026-10-25 按用户「严格按原型图」重做）。
///
/// 结构（自上而下，与原型逐项对齐）：
/// - 抓手
/// - 标题「模型」+ 副标题「切换后对新消息生效」
/// - 模型行：模型名（主）+ 服务商名（副），当前项带「当前」徽标、
///   端侧项带「端侧」徽标，配了模型目录的带 ›（点进去选具体模型，
///   沿用 2026-10-14 用户要求的两层结构）
/// - 分组「思考等级」+ 五档胶囊一排（auto/off/low/high/max）；
///   协议不区分档位时（后端 rLv 如实标注）只给开/关两态，不假装五档
/// - 分组「最大轮次」+ 档位胶囊 + 人话说明（2026-10-18 用户功能，
///   原型未画但不可删：它是单次运行的成本参数，唯一 UI 入口在此）
///
/// 选择语义与旧弹层完全一致：点选即生效并收起；选同一档不回调
/// （不产生无意义写盘）；未配置（无 Key）的服务商不渲染。
Future<void> showModelSheet(
  BuildContext context, {
  required List<ModelProviderConfig> providers,
  required String? activeProviderId,
  required ReasoningLevel reasoningLevel,
  required int maxTurns,
  ValueChanged<String>? onProviderSelected,
  ValueChanged<String>? onOpenModelCatalog,
  ValueChanged<ReasoningLevel>? onReasoningLevelChanged,
  ValueChanged<int>? onMaxTurnsChanged,
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
              const SizedBox(height: 12),
              for (final p in visible) ...[
                _ModelRow(
                  h: h,
                  title: p.model.isNotEmpty ? p.model : p.name,
                  subtitle: p.model.isNotEmpty ? p.name : null,
                  catalogCount:
                      p.modelCatalog.isNotEmpty ? p.modelCatalog.length : null,
                  active: p.id == activeProviderId,
                  isLocal: AppSettings.isLocalConfig(p),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    // 配了模型目录 → 进目录选具体模型（选中即切
                    // provider + 换模型）；否则点选即切换。
                    if (p.modelCatalog.isNotEmpty) {
                      onOpenModelCatalog?.call(p.id);
                    } else {
                      onProviderSelected?.call(p.id);
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 6),
              Text(
                '思考等级',
                style: HTxt.sectionTitle.copyWith(color: h.text),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: HSpace.sm,
                runSpacing: HSpace.sm,
                children: [
                  if (levelsEffective)
                    for (final v in ReasoningLevel.values)
                      _SheetPill(
                        label: v.label,
                        selected: v == reasoningLevel,
                        h: h,
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          if (v != reasoningLevel) {
                            onReasoningLevelChanged?.call(v);
                          }
                        },
                      )
                  else ...[
                    _SheetPill(
                      label: '关',
                      selected: reasoningLevel == ReasoningLevel.off,
                      h: h,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        if (reasoningLevel != ReasoningLevel.off) {
                          onReasoningLevelChanged?.call(ReasoningLevel.off);
                        }
                      },
                    ),
                    _SheetPill(
                      label: '开',
                      selected: reasoningLevel != ReasoningLevel.off,
                      h: h,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        if (reasoningLevel == ReasoningLevel.off) {
                          onReasoningLevelChanged?.call(ReasoningLevel.auto);
                        }
                      },
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                levelsEffective
                    ? reasoningLevel.description
                    : '当前协议不区分思考档位（低 / 高 / 最大不生效），只有开和关。',
                style: TextStyle(fontSize: 12, height: 1.4, color: h.textDim),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '最大轮次',
                    style: HTxt.sectionTitle.copyWith(color: h.text),
                  ),
                  const Spacer(),
                  Text(
                    maxTurns == 0 ? '自动' : '$maxTurns',
                    style: TextStyle(fontSize: 13, color: h.textDim),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: HSpace.sm,
                runSpacing: HSpace.sm,
                children: [
                  for (final v in kMaxTurnsOptions)
                    _SheetPill(
                      label: v == 0 ? '自动' : '$v',
                      selected: v == maxTurns,
                      h: h,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        if (v != maxTurns) {
                          onMaxTurnsChanged?.call(v);
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '自动 = 云端 40 轮（默认）。\n'
                '轮次越多，单次任务能做的步骤越多，但可能跑更久；'
                '云端按轮计费，花费也更多。',
                style: TextStyle(fontSize: 12, height: 1.4, color: h.textDim),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 模型行（原型 09）：名称 + 说明在左，徽标/箭头在右。
///
/// 当前项整行浅填 + 「当前」徽标；端侧项带「端侧」徽标；
/// 两者都有时「当前」优先（端侧信息已在副标题的服务商名里）。
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.h,
    required this.title,
    required this.subtitle,
    required this.catalogCount,
    required this.active,
    required this.isLocal,
    required this.onTap,
  });

  final Hue h;
  final String title;
  final String? subtitle;
  final int? catalogCount;
  final bool active;
  final bool isLocal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: active ? h.surface : Colors.transparent,
          border: Border.all(color: h.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
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
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: h.text,
                    ),
                  ),
                  if (subtitle != null || catalogCount != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        ?subtitle,
                        if (catalogCount != null) '模型目录 · $catalogCount 个',
                      ].join(' · '),
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
              _Badge(h: h, label: '当前', filled: true)
            else if (isLocal)
              _Badge(h: h, label: '端侧', filled: false),
            if (catalogCount != null) ...[
              const SizedBox(width: 6),
              Icon(AppIcons.chevronRight, size: 17, color: h.textFaint),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.h, required this.label, required this.filled});

  final Hue h;
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? h.text : Colors.transparent,
        border: filled ? null : Border.all(color: h.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: filled ? h.onAccent : h.textDim,
        ),
      ),
    );
  }
}

/// 抽屉内单选胶囊：选中 = 强调色实心，未选 = 表面色 + 描边。
class _SheetPill extends StatelessWidget {
  const _SheetPill({
    required this.label,
    required this.selected,
    required this.h,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Hue h;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? h.accent : h.surface,
          borderRadius: BorderRadius.circular(HRadius.pill),
          border: Border.all(color: selected ? h.accent : h.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? h.onAccent : h.textDim,
          ),
        ),
      ),
    );
  }
}
