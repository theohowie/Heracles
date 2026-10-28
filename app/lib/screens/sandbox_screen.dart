import 'package:flutter/material.dart';

import '../services/sandbox_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../widgets/bw_approval.dart';

/// **沙箱页**（2026-10-28，docs/INTERFACE.md §8 + 用户定调）。
///
/// ## 定位（用户定调，别做偏）
///
/// 沙箱的消费者是 **agent**，不是用户：激活后 agent 的命令默认
/// 全部走沙箱，只有沙箱做不了的（动 Android 本身）才落手机 Shell。
/// 所以这一页**只是管理面** —— 激活、看状态、看挂载点、看通道、
/// 重置；**没有命令输入、没有独立执行界面**（执行都在对话的工具卡
/// 里看）。§8.5 旧版的「前端执行输出 UI」已按定调作废。
///
/// ## 口径红线（§8）
///
/// - 不把它描述成「安全沙箱」：PRoot 不是敌对代码隔离，它解决的
///   是文件污染与崩溃回滚；
/// - 界面只出现 `@name` 逻辑名，**绝不显示物理路径**；
/// - 通道只展示可用性与风险，**不做授权开关**（放行是门禁的事）。
class SandboxScreen extends StatefulWidget {
  const SandboxScreen({super.key});

  @override
  State<SandboxScreen> createState() => _SandboxScreenState();
}

class _SandboxScreenState extends State<SandboxScreen> {
  final SandboxService _service = SandboxService();

  SandboxStatus? _status;
  List<SandboxMount> _mounts = const [];
  bool _activating = false;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final st = await _service.status();
    final mounts = await _service.listMounts();
    if (!mounted) return;
    setState(() {
      _status = st;
      _mounts = mounts;
    });
  }

  Future<void> _activate() async {
    if (_activating) return;
    setState(() => _activating = true);
    final st = await _service.activate();
    if (!mounted) return;
    setState(() {
      _activating = false;
      _status = st;
    });
    if (st.installed) {
      showIosToast(context, '沙箱已激活');
      _refresh();
    } else {
      // activate 的失败原因被客户端收敛进状态形状，这里只能如实
      // 报「没装上」+ 最可能的下一步（内置失败会走 OCI 兜底，要网）。
      showIosToast(context, '激活失败：内置环境不可用时需要联网重试');
    }
  }

  Future<void> _reset() async {
    if (_resetting) return;
    final ok = await showBwConfirmSheet(
      context,
      title: '重置沙箱？',
      message: '沙箱里的环境、产物和缓存会被整块清掉，回到未激活状态。'
          '挂载点指向的外部文件不受影响。',
      confirmLabel: '重置',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _resetting = true);
    final st = await _service.reset();
    if (!mounted) return;
    setState(() {
      _resetting = false;
      _status = st;
    });
    if (!st.installed) {
      showIosToast(context, '沙箱已重置');
      _refresh();
    } else {
      showIosToast(context, '重置失败：后端尚未支持重置');
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final st = _status;
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('沙箱'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          _statusCard(h, st),
          const SizedBox(height: HSpace.lg),
          _sectionLabel(h, '挂载点'),
          _mountsCard(h, st),
          const SizedBox(height: HSpace.lg),
          _sectionLabel(h, '执行通道'),
          _channelsCard(h, st),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, HSpace.sm, 4, 0),
            child: Text(
              '通道只展示可用性，放不放行由权限门禁决定。',
              style: TextStyle(fontSize: 12, color: h.textFaint, height: 1.55),
            ),
          ),
          if (st != null && st.installed) ...[
            const SizedBox(height: HSpace.lg),
            _sectionLabel(h, '管理'),
            _resetCard(h),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(Hue h, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, HSpace.sm),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: h.textFaint,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _card(Hue h, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: child,
    );
  }

  Widget _statusCard(Hue h, SandboxStatus? st) {
    final installed = st?.installed ?? false;
    return _card(
      h,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: st == null
                      ? h.textFaint
                      : installed
                          ? HColors.successOn(h.dark)
                          : h.textFaint,
                ),
              ),
              const SizedBox(width: HSpace.sm),
              Text(
                st == null ? '正在读取状态…' : (installed ? '已激活' : '未激活'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: h.text,
                ),
              ),
              if (st != null && installed && st.prootReady) ...[
                const Spacer(),
                Text(
                  'PRoot 就绪',
                  style: TextStyle(fontSize: 12, color: h.textFaint),
                ),
              ],
            ],
          ),
          const SizedBox(height: HSpace.sm),
          Text(
            installed
                ? (st!.rootfsSummary.isEmpty
                    ? '内置 Linux 环境已就绪。'
                    : st.rootfsSummary)
                : '内置的 Alpine Linux 环境还没有装好。激活会解包约 9 MB 的 '
                    'rootfs（离线内置，不需要联网），之后 agent 的命令默认 '
                    '在沙箱里执行，产物与真机文件分开存放。',
            style: TextStyle(fontSize: 13, color: h.textDim, height: 1.6),
          ),
          if (st != null && installed && !st.prootReady) ...[
            const SizedBox(height: HSpace.xs),
            Text(
              'PRoot 尚未就绪，命令暂时无法在沙箱执行。',
              style: TextStyle(
                fontSize: 13,
                color: HColors.warnOn(h.dark),
                height: 1.6,
              ),
            ),
          ],
          if (st != null && !installed) ...[
            const SizedBox(height: HSpace.md),
            GestureDetector(
              onTap: _activating ? null : _activate,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: h.text,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Center(
                  child: _activating
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: h.bg,
                              ),
                            ),
                            const SizedBox(width: HSpace.sm),
                            Text(
                              '正在解包 rootfs…',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: h.bg,
                              ),
                            ),
                          ],
                        )
                      : Text(
                          '激活沙箱',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: h.bg,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mountsCard(Hue h, SandboxStatus? st) {
    final installed = st?.installed ?? false;
    if (!installed) {
      return _card(
        h,
        Text(
          '激活后显示。沙箱通过 @名字 访问外部目录。',
          style: TextStyle(fontSize: 13, color: h.textFaint, height: 1.6),
        ),
      );
    }
    if (_mounts.isEmpty) {
      return _card(
        h,
        Text(
          '暂无挂载点。',
          style: TextStyle(fontSize: 13, color: h.textFaint, height: 1.6),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < _mounts.length; i++) ...[
            if (i > 0) Divider(height: 1, color: h.border),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _mounts[i].prefix,
                          style: const TextStyle(
                            fontFamily: kMonoFontFamily,
                            fontFamilyFallback: kMonoFallback,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_mounts[i].description.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            _mounts[i].description,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: h.textFaint,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _mounts[i].readOnly
                          ? HColors.warnOn(h.dark).withValues(alpha: 0.16)
                          : h.surface,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _mounts[i].readOnly ? '只读' : '读写',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _mounts[i].readOnly
                            ? HColors.warnOn(h.dark)
                            : h.textDim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _channelsCard(Hue h, SandboxStatus? st) {
    final channels = st?.channels ?? const <SandboxChannelInfo>[];
    if (channels.isEmpty) {
      return _card(
        h,
        Text(
          '暂无通道信息。',
          style: TextStyle(fontSize: 13, color: h.textFaint, height: 1.6),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < channels.length; i++) ...[
            if (i > 0) Divider(height: 1, color: h.border),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      channels[i].name,
                      style: TextStyle(fontSize: 13.5, color: h.text),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: h.border),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '风险 ${switch (channels[i].risk) { 0 => '低', 1 => '中', _ => '高' }}',
                      style: TextStyle(fontSize: 11, color: h.textFaint),
                    ),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Text(
                    channels[i].available
                        ? '可用'
                        : (channels[i].reason.isEmpty
                            ? '不可用'
                            : channels[i].reason),
                    style: TextStyle(fontSize: 12.5, color: h.textFaint),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resetCard(Hue h) {
    return GestureDetector(
      onTap: _resetting ? null : _reset,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.xl),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '重置沙箱',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: HColors.errorOn(h.dark),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '整块回滚，清掉环境与产物',
                    style: TextStyle(fontSize: 13, color: h.textFaint),
                  ),
                ],
              ),
            ),
            if (_resetting)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: h.textFaint,
                ),
              )
            else
              Icon(AppIcons.chevronRight, size: 16, color: h.textFaint),
          ],
        ),
      ),
    );
  }
}
