import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/open_source_licenses.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

/// **开源许可页**（2026-10-27 用户定）：致谢名单形态 ——
/// 直接依赖 + 其依赖（递归深度上限 2）+ 平台/原生/设计资产，
/// 每项可点进看完整许可文本。数据由
/// `app/tool/generate_oss_licenses.py` 从各包 LICENSE 生成。
class OssLicensesScreen extends StatelessWidget {
  const OssLicensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final self = kOssEntries.where((e) => e.group == 'self').toList();
    final direct = kOssEntries.where((e) => e.group == 'direct').toList();
    final second = kOssEntries.where((e) => e.group == 'second').toList();
    final platform = kOssEntries.where((e) => e.group == 'platform').toList();
    // 项目本体不算“第三方开源项目”，引言里只数第三方依赖。
    final thirdParty = kOssEntries.where((e) => e.group != 'self').length;
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('开源许可'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          Text(
            'Heracles 本体以 GPL-3.0 开源；同时基于以下 $thirdParty 个开源项目构建，谨此致谢。'
            '名单含直接依赖与它们的依赖（两层），以及平台、原生组件与图标资产；'
            '点任意一项可查看其完整许可文本。',
            style: TextStyle(fontSize: 12.5, height: 1.55, color: h.textFaint),
          ),
          const SizedBox(height: HSpace.lg),
          if (self.isNotEmpty) ...[
            _group(h, 'Heracles 本体', self),
            const SizedBox(height: HSpace.lg),
          ],
          _group(h, '直接依赖', direct),
          const SizedBox(height: HSpace.lg),
          _group(h, '二层依赖', second),
          const SizedBox(height: HSpace.lg),
          _group(h, '平台与原生', platform),
        ],
      ),
    );
  }

  Widget _group(Hue h, String title, List<OssEntry> entries) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title,
              style: HTxt.sectionTitle.copyWith(color: h.textDim)),
        ),
        Container(
          decoration: BoxDecoration(
            color: h.surfaceAlt,
            borderRadius: BorderRadius.circular(HRadius.xl),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1, indent: 18, endIndent: 18, color: h.border),
                _OssRow(entry: entries[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _OssRow extends StatelessWidget {
  const _OssRow({required this.entry});

  final OssEntry entry;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final meta = [
      entry.licenseKind,
      if (entry.version.isNotEmpty) 'v${entry.version}',
      if (entry.note.isNotEmpty) entry.note else entry.origin,
    ].join(' · ');
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => OssLicenseDetailScreen(entry: entry),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name,
                      style: TextStyle(fontSize: 15, color: h.text)),
                  const SizedBox(height: 2),
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: h.textFaint)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(CupertinoIcons.chevron_forward, size: 14, color: h.textFaint),
          ],
        ),
      ),
    );
  }
}

/// 许可详情：项目名 + 许可种类/版本 + 许可全文（可选中复制）。
class OssLicenseDetailScreen extends StatelessWidget {
  const OssLicenseDetailScreen({super.key, required this.entry});

  final OssEntry entry;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final meta = [
      entry.licenseKind,
      if (entry.version.isNotEmpty) 'v${entry.version}',
      entry.origin,
      if (entry.note.isNotEmpty) entry.note,
    ].join(' · ');
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: Text(entry.name),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          Text(meta, style: TextStyle(fontSize: 12.5, color: h.textFaint)),
          const SizedBox(height: HSpace.md),
          Container(
            decoration: BoxDecoration(
              color: h.surfaceAlt,
              borderRadius: BorderRadius.circular(HRadius.lg),
            ),
            padding: const EdgeInsets.all(HSpace.lg),
            child: SelectableText(
              entry.licenseText,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: h.textDim,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
