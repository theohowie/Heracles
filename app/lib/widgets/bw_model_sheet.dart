import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/stretch_segmented.dart';
import 'bw_approval.dart';

/// 模型与思考半抽屉（原型 09，2026-10-25 晚按用户对照图六再对齐）。
///
/// 结构（自上而下）：
/// - 抓手
/// - 标题行「模型」+ 右上 × 关闭；副标题「切换后对新消息生效」
/// - 模型行 = 全 App 统一的边框选项卡（BwOptionCard，2026-10-29
///   用户以审批模式图一为范式定版）：名称（主）+ 说明（副）；
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
  String? currentProviderId,
  required ReasoningLevel reasoningLevel,
  ValueChanged<String>? onProviderSelected,
  ValueChanged<String>? onOpenModelCatalog,
  ValueChanged<ReasoningLevel>? onReasoningLevelChanged,
}) async {
  final h = Hue.of(context);
  // ★「当前」判据（2026-10-29 T2 第 6 条）：**不再只认用户显式点过的
  //   `activeProviderId`**。用户没点过时它是 null，而输入框胶囊显示的是
  //   `AppSettings.effectiveProvider`（models/settings.dart:733-749 会自动
  //   选中一个）⇒ 旧版胶囊上有模型名、抽屉里却没有任何「当前」。
  //   调用方把 `effectiveProvider?.id` 作为 [currentProviderId] 传进来
  //   （唯一口径，抽屉里**不重算**选择顺序）；只有旧调用没传时才退回
  //   `activeProviderId`（compat）。
  final currentId = currentProviderId ?? activeProviderId;
  // ★ 思考档位是否真生效（后端如实标注）：Anthropic / Responses 轨
  //   不读 reasoning_effort ⇒ 只给开/关两态。数据优先吃能力快照
  //   （rLv），没有快照时按 provider 协议推导。
  var levelsEffective = true;
  final currentProvider =
      providers.where((p) => p.id == currentId).firstOrNull;
  if (currentProvider != null) {
    levelsEffective =
        currentProvider.modelCapabilities[currentProvider.model]
                ?.reasoningLevelsEffective ??
            currentProvider.protocol.reasoningLevelsEffective;
  }
  final visible = providers
      .where((p) => p.isConfigured || AppSettings.isLocalConfig(p))
      .toList();

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: SafeArea(
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
                if (i > 0) const SizedBox(height: 8),
                BwOptionCard(
                  h: h,
                  selected: visible[i].id == currentId,
                  title: visible[i].model.isNotEmpty
                      ? visible[i].model
                      : visible[i].name,
                  subtitle: [
                    if (visible[i].model.isNotEmpty) visible[i].name,
                    if (visible[i].modelCatalog.isNotEmpty)
                      '模型目录 · ${visible[i].modelCatalog.length} 个',
                    if (AppSettings.isLocalConfig(visible[i])) '端侧运行',
                  ].join(' · '),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (visible[i].id == currentId)
                        _Badge(h: h, label: '当前')
                      else if (AppSettings.isLocalConfig(visible[i]))
                        _Badge(h: h, label: '端侧'),
                      if (visible[i].modelCatalog.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Icon(AppIcons.chevronRight,
                            size: 17, color: h.textFaint),
                      ],
                    ],
                  ),
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
              // ★ 五档恒显（2026-10-26 用户令）：不管协议支不支持，
              // Auto/Off/Low/High/Max 五档都摆出来用同一条流体分段；
              // 不支持分档的协议把 Low/High/Max 禁用（变淡、点不动、
              // 拖不过去），只留 Auto 与 Off 可选 —— 旧版在不支持时
              // 换成「关/开」两档，用户问「不支持是前端还是后端」：
              // 是后端能力（rLv），前端如实禁用而不是藏起来。
              // 当前值若是被禁的档（从别的服务商带过来的），选中态
              // 按「开」处理落在 Auto 上。
              _SegBar(
                h: h,
                labels: [for (final v in ReasoningLevel.values) v.label],
                selected: levelsEffective
                    ? ReasoningLevel.values.indexOf(reasoningLevel)
                    : (reasoningLevel == ReasoningLevel.off
                        ? ReasoningLevel.values.indexOf(ReasoningLevel.off)
                        : ReasoningLevel.values.indexOf(ReasoningLevel.auto)),
                disabled: levelsEffective
                    ? const {}
                    : {
                        ReasoningLevel.values.indexOf(ReasoningLevel.low),
                        ReasoningLevel.values.indexOf(ReasoningLevel.high),
                        ReasoningLevel.values.indexOf(ReasoningLevel.max),
                      },
                onSelected: (i) {
                  final v = ReasoningLevel.values[i];
                  Navigator.of(sheetCtx).pop();
                  if (v != reasoningLevel) {
                    onReasoningLevelChanged?.call(v);
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
    )),
  );
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
    this.disabled = const {},
  });

  final Hue h;
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final Set<int> disabled;

  @override
  Widget build(BuildContext context) {
    // 与通用设置的分段控件同一套弹性拉伸动画（StretchSegmented），
    // 只换皮：白块＋轻投影（抽屉里是浅底托深字）。
    return StretchSegmented(
      labels: labels,
      selected: selected,
      onSelected: onSelected,
      disabled: disabled,
      trackColor: h.surface,
      blockColor: h.surfaceAlt,
      blockShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ],
      selectedLabelColor: h.text,
      labelColor: h.textDim,
      fontSize: 13,
    );
  }
}

