import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/settings.dart';
import '../services/agent_bridge.dart';
import '../services/global_memory.dart';
import '../services/settings_controller.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/elastic_switch.dart';
import '../widgets/bw_approval.dart';

/// 设置主页 —— 分类列表（对应参考图的侧栏结构）。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('设置'),
        leading: _iosBackLeading(context),
      ),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: controller,
        builder: (context, s, _) {
          return ListView(
            padding: const EdgeInsets.only(bottom: HSpace.xl),
            children: [
              // ★ 设置主页卡片式（2026-10-25 用户参照账户页截图指定）：
              //   小字分组标签在上，每个设置项一张圆角卡片包裹（标题 +
              //   副行状态值 + 右箭头）。「通用设置」不再做小字链接，
              //   与其他项同为卡片；状态值放副行、整行省略 —— 旧平直行
              //   把值放右侧，长模型名把标题挤成竖排（真机实测翻车）。
              const _SectionLabel('通用'),
              _HomeCard(
                title: '通用设置',
                subtitle: '界面字号 · 工作步骤 · 繁忙发送 · 最大轮次',
                onTap: () => _push(
                    context, GeneralSettingsPage(controller: controller)),
              ),
              const _SectionLabel('智能体'),
              _GlobalMemoryEntry(
                onOpen: () => _push(context, const GlobalMemoryPage()),
              ),
              _DevicePermissionEntry(
                onOpen: () => _push(context, const DevicePermissionPage()),
              ),
              _HomeCard(
                title: '模型',
                // 与聊天页同源同字段（2026-10-15 修 BUG-5 的口径保留）：
                // effectiveProvider + 「服务商 · 模型名」
                subtitle: s.effectiveProvider == null
                    ? '未选择'
                    : (s.effectiveProvider!.model.isEmpty
                        ? s.effectiveProvider!.name
                        : '${s.effectiveProvider!.name} · ${s.effectiveProvider!.model}'),
                onTap: () => _push(
                    context, ModelSettingsPage(controller: controller)),
              ),
              const _SectionLabel('应用'),
              _HomeCard(
                title: '外观',
                subtitle: s.appearance.label,
                onTap: () => _push(
                    context, AppearanceSettingsPage(controller: controller)),
              ),
              _HomeCard(
                title: '关于 Heracles',
                subtitle: 'Dart 内核',
                onTap: () => _push(context, const AboutPage()),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 二级页统一入口（iOS 侧滑路由）。
  ///
  /// 返回的是**这条路由的 Future**（pop 时才完成）—— 调用方不 `await`
  /// 就照旧是"点火即忘"，行为不变；`_GlobalMemoryEntry` 需要**从二级页
  /// 返回后**再刷新徽章，所以要等它。（旧写法 `void _push` 让
  /// 「返回后刷新」在 push 的那一刻就跑了 —— 那是假刷新。）
  Future<void> _push(BuildContext context, Widget page) async {
    await Navigator.of(context)
        .push(CupertinoPageRoute(builder: (_) => page));
  }
}

/// **设备权限入口**（2026-10-16，无线调试/Shizuku/adb 授权引导）。
///
/// ## 用户需求
///
/// > 「接入shizuku获取更高权限 / 接入stellar获取最高权限，
/// >   或者自己通过无线调试获取adb权限操控手机」
///
/// ## 本批范围（用户确认：先做授权引导）
///
/// 检测 + 引导 —— 不做配对执行器（完整 shell 能力下批）。
/// `WRITE_SECURE_SETTINGS` 是无障碍自愈的钥匙（ADR-016，P0），
/// 授权一次三类能力全解锁（pm grant 的效果是复用的）。
/// **设备权限入口行**（2026-10-16，二级页面形态 —— 与「模型」一致）。
///
/// 用户反馈：「设备权限放到二级界面去，跟模型界面一样，
///           不要放到设置界面」—— 主页只放一行入口 + 状态徽章，
///           详情（引导文案、刷新按钮）在二级页。
class _DevicePermissionEntry extends StatefulWidget {
  const _DevicePermissionEntry({required this.onOpen});

  final VoidCallback onOpen;

  @override
  State<_DevicePermissionEntry> createState() => _DevicePermissionEntryState();
}

class _DevicePermissionEntryState extends State<_DevicePermissionEntry> {
  bool? _granted;

  /// N8 总览里「未授权」的项数（allFiles 按设计不计）；null = 无数据。
  int? _deniedCount;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final st = await AgentBridge().devicePermission();
    final perms = await AgentBridge().devicePermissions();
    if (!mounted) return;
    setState(() {
      _granted = st.writeSecureSettings;
      if (perms.isNotEmpty) {
        const keys = [
          'shizuku',
          'files',
          'notifications',
          'accessibility',
          'overlay',
        ];
        _deniedCount = keys.where((k) => perms[k] == 'denied').length;
      }
    });
  }

  String get _badge {
    final n = _deniedCount;
    if (n != null) return n == 0 ? '全部开启' : '$n 项未开启';
    if (_granted == null) return '…';
    return _granted! ? '已授权' : '未授权';
  }

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '设备权限',
      // 状态作卡片副行 —— 不进二级页也知道几项没开
      subtitle: _badge,
      onTap: () async {
        widget.onOpen();
        // 从二级页返回后刷新状态（用户可能刚执行了授权命令）
        await _refresh();
      },
    );
  }
}

/// **设备权限二级页**（2026-10-16）—— 检测状态 + 三渠道授权引导。
///
/// ## 本批范围（用户确认：先做授权引导）
///
/// 检测 + 引导 —— 不做配对执行器（完整 shell 能力下批）。
/// `WRITE_SECURE_SETTINGS` 是无障碍自愈的钥匙（ADR-016，P0），
/// 授权一次三类能力全解锁（pm grant 的效果是复用的）。
class DevicePermissionPage extends StatefulWidget {
  const DevicePermissionPage({super.key});

  @override
  State<DevicePermissionPage> createState() => _DevicePermissionPageState();
}

class _DevicePermissionPageState extends State<DevicePermissionPage> {
  bool? _granted;
  String _guidance = '';

  /// Shizuku 一键授权进行中（按钮转圈）
  bool _shizukuBusy = false;

  /// Shizuku 授权结果文案 + 成败（成败单独存，不靠文案前缀判断）
  String? _shizukuMsg;
  bool _shizukuOk = false;
  bool _loading = true;

  /// 执行路由诊断（ping / granted / sui）——
  /// 解释「命令执行成功但 Shizuku 显示 0 个已授权应用」
  Map<String, dynamic> _diag = const {};

  /// **编码层自检**进行中（2026-10-17）—— 构建要 1–3 分钟，按钮要能锁住
  bool _selfCheckBusy = false;

  /// 自检报告（逐行：前台服务/shell 路由/工具链/工作区/构建/产物核对）
  String? _selfCheckMsg;

  /// N8 统一权限总览（六项 → granted/denied/unknown）；空 = 通道无数据，
  /// 整段不渲染，不画假状态。
  Map<String, String> _perms = const {};

  /// 执行路由诊断明细是否展开（默认收起：页面只给结论，
  /// 逐项清单是调试信息，不该整墙糊在用户脸上）。
  bool _diagExpanded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final st = await AgentBridge().devicePermission();
    final perms = await AgentBridge().devicePermissions();
    if (!mounted) return;
    setState(() {
      _granted = st.writeSecureSettings;
      _guidance = st.guidance;
      _diag = st.shizuku;
      _perms = perms;
      _loading = false;
    });
  }

  /// 权限总览卡（2026-10-25 晚按概念图 07 重做）：一张卡六行，
  /// 每行 名称 + 说明 + 右侧状态胶囊 —— 已授权 = 黑色实心胶囊，
  /// 其余 = 灰胶囊（Shizuku 未授权时胶囊可点 =「去开启」一键授权），
  /// 不再用彩色文字堆一张表。
  ///
  /// 两个渲染口径（后端对接清单 §6，必须照做）：
  /// · `allFiles` 的 denied 是**正常态**（按设计不申请所有文件访问，
  ///   文件走 SAF 授权目录）—— 胶囊写「未开启 · 按设计」，中性；
  /// · `shizuku` 的 unknown = Shizuku **没启动**（探测不了），与
  ///   denied（启动了没授权）是两回事，文案分开。
  Widget _permOverview(Hue h) {
    const rows = [
      ('shizuku', 'Shizuku', '执行系统级命令与设备操作'),
      ('files', '文件访问', '读写已授权的工作区文件夹'),
      ('allFiles', '所有文件访问', '按设计不申请，文件经授权目录访问'),
      ('notifications', '通知', '任务完成与审批请求提醒'),
      ('accessibility', '无障碍服务', '读取界面元素、辅助点击操作'),
      ('overlay', '悬浮窗', '在其他应用上方显示运行状态'),
    ];

    Widget pill(String key) {
      final v = _perms[key] ?? 'unknown';
      // (文案, 是否实心, 是否可点去开启)
      final (label, filled, action) = switch ((key, v)) {
        ('allFiles', 'denied') => ('未开启 · 按设计', false, false),
        ('shizuku', 'unknown') => ('未启动', false, false),
        (_, 'granted') =>
          (key == 'notifications' ? '已开启' : '已授权', true, false),
        ('shizuku', 'denied') => ('去开启', false, true),
        (_, 'denied') => ('未授权', false, false),
        _ => ('未知', false, false),
      };
      final chip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: filled ? h.text : h.surface,
          borderRadius: BorderRadius.circular(999),
        ),
        child: action && _shizukuBusy
            ? CupertinoActivityIndicator(radius: 8, color: h.text)
            : Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: filled ? h.bg : h.text,
                ),
              ),
      );
      if (!action) return chip;
      return GestureDetector(
        onTap: _shizukuBusy ? null : () => _runShizuku(force: false),
        behavior: HitTestBehavior.opaque,
        child: chip,
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(height: 1, indent: 18, endIndent: 18, color: h.border),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rows[i].$2,
                            style: TextStyle(fontSize: 15, color: h.text)),
                        const SizedBox(height: 2),
                        Text(rows[i].$3,
                            style: TextStyle(
                                fontSize: 12.5, color: h.textFaint)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  pill(rows[i].$1),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Shizuku 授权动作（胶囊「去开启」/ 一键授权 / 重新申请共用）：
  /// force=false 走 shizukuGrant（未授权时的一键授权）；force=true
  /// 走 shizukuForceRequest（已授权时强制再弹一次，让 Shizuku 的
  /// 「已授权应用」列表收录本 App —— 2026-10-16 实测问题）。
  Future<void> _runShizuku({required bool force}) async {
    setState(() => _shizukuBusy = true);
    final r = force
        ? await AgentBridge().shizukuForceRequest()
        : await AgentBridge().shizukuGrant();
    if (!mounted) return;
    setState(() {
      _shizukuOk = r.success;
      _shizukuMsg = r.message;
    });
    await _refresh();
    if (!mounted) return;
    setState(() => _shizukuBusy = false);
  }

  /// 授权结果一行（成功绿 / 失败红，纯文字无装饰符号）
  Widget _shizukuMsgLine(Hue h) {
    if (_shizukuMsg == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: HSpace.sm),
      child: Text(
        _shizukuMsg!,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color:
              _shizukuOk ? HColors.successOn(h.dark) : HColors.errorOn(h.dark),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      appBar: AppBar(
          title: const Text('设备权限'), leading: _iosBackLeading(context)),
      body: _loading
          ? Center(child: CupertinoActivityIndicator(color: h.accent))
          : ListView(
              padding: const EdgeInsets.all(HSpace.lg),
              children: [
                // ---- 权限总览卡（概念图 07 形态）----
                if (_perms.isNotEmpty) _permOverview(h),
                // ---- 卡下说明：自愈状态 + 概念图 07 页脚 ----
                const SizedBox(height: HSpace.md),
                Text(
                  [
                    if (_granted != null)
                      '无障碍自愈${_granted == true ? '可用' : '不可用'}',
                    '权限只在你主动开启后生效；关闭任意一项，对应工具会立即不可用并说明原因。',
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 12, height: 1.55, color: h.textFaint),
                ),
                // ---- 未授权：授权引导（方式说明 + 一键授权）----
                if (_granted == false && _guidance.isNotEmpty) ...[
                  const SizedBox(height: HSpace.lg),
                  Text(
                    '授权引导',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: h.text),
                  ),
                  const SizedBox(height: HSpace.xs),
                  Text(
                    '三种授权方式任选其一：',
                    style: TextStyle(fontSize: 12.5, color: h.textDim),
                  ),
                  const SizedBox(height: HSpace.sm),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(HSpace.md),
                    decoration: BoxDecoration(
                      color: h.surfaceAlt,
                      borderRadius: BorderRadius.circular(HRadius.md),
                      border: Border.all(color: h.border),
                    ),
                    child: Text(
                      _guidance,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        fontFamily: kMonoFontFamily,
                        fontFamilyFallback: kMonoFallback,
                        color: h.text,
                      ),
                    ),
                  ),
                  const SizedBox(height: HSpace.md),
                  SizedBox(
                    width: double.infinity,
                    child: IosButton(
                      label: '通过 Shizuku 一键授权',
                      color: h.accent,
                      busy: _shizukuBusy,
                      onPressed: _shizukuBusy
                          ? null
                          : () => _runShizuku(force: false),
                    ),
                  ),
                  _shizukuMsgLine(h),
                  const SizedBox(height: HSpace.sm),
                  SizedBox(
                    width: double.infinity,
                    child: IosButton(
                      label: '我已执行授权，刷新状态',
                      filled: false,
                      color: h.accent,
                      onPressed: _refresh,
                    ),
                  ),
                ] else if (_granted == true) ...[
                  const SizedBox(height: HSpace.md),
                  Text(
                    '一切正常 —— 无障碍被系统关闭时会自动恢复，无需干预。',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.5, color: h.textDim),
                  ),
                  // 强制重新申请（2026-10-16）：Shizuku 服务端已授权但
                  // 它的 UI 列表不收录「遗留授权」—— 以小字按钮保留入口，
                  // 不再占一整行大按钮。
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CupertinoButton(
                      onPressed: _shizukuBusy
                          ? null
                          : () => _runShizuku(force: true),
                      minimumSize: const Size(0, 36),
                      padding: EdgeInsets.zero,
                      child: Text(
                        '重新向 Shizuku 申请授权（收录本 App）',
                        style: TextStyle(fontSize: 13, color: h.textDim),
                      ),
                    ),
                  ),
                  _shizukuMsgLine(h),
                ],
                // ---- 诊断与自检（默认收起：调试信息不是正文）----
                const SizedBox(height: HSpace.lg),
                GestureDetector(
                  onTap: () => setState(() => _diagExpanded = !_diagExpanded),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      Text(
                        '诊断与自检',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: h.text),
                      ),
                      const Spacer(),
                      Text(
                        _diagExpanded ? '收起' : '详情',
                        style: TextStyle(fontSize: 12.5, color: h.textDim),
                      ),
                      Icon(
                        _diagExpanded
                            ? AppIcons.chevronUp
                            : AppIcons.chevronDown,
                        size: 15,
                        color: h.textDim,
                      ),
                    ],
                  ),
                ),
                if (_diagExpanded) ...[
                  // 执行路由诊断：本机同时装 Stellar（Sui 系）时
                  // Shizuku-API 内置 Sui 支持会改走 Sui，它的授权
                  // 列表自然是 0 —— 如实显示实际路由，不让用户猜。
                  if (_diag.isNotEmpty) ...[
                    const SizedBox(height: HSpace.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(HSpace.md),
                      decoration: BoxDecoration(
                        color: h.surfaceAlt,
                        borderRadius: BorderRadius.circular(HRadius.lg),
                        border: Border.all(color: h.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('当前执行路由：',
                                  style: TextStyle(
                                      fontSize: 12.5, color: h.textDim)),
                              Text(
                                (_diag['route'] as String?) ?? '无',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: (_diag['route'] as String?) == '无'
                                      ? HColors.errorOn(h.dark)
                                      : HColors.successOn(h.dark),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: HSpace.xs),
                          Divider(height: 1, color: h.border),
                          const SizedBox(height: HSpace.xs),
                          _diagRow(h, 'Stellar 已安装', _diag['stellarInstalled']),
                          _diagRow(h, 'Stellar 服务在运行', _diag['stellarRunning']),
                          _diagRow(h, 'Stellar 已授权本 App', _diag['stellarGranted']),
                          if (_diag['stellarGranted'] == true)
                            _diagText(
                              h,
                              (_diag['stellarRoot'] == true)
                                  ? 'Stellar 模式：Root（能力最强）'
                                  : 'Stellar 模式：ADB / Shell（uid=${_diag['stellarUid']}）',
                            ),
                          const SizedBox(height: HSpace.xs),
                          _diagRow(h, 'Shizuku 已安装', _diag['shizukuInstalled']),
                          _diagRow(h, 'Shizuku binder 连通', _diag['shizukuPing']),
                          _diagRow(h, 'Shizuku 已授权本 App', _diag['shizukuGranted']),
                          _diagRow(h, 'Shizuku 版本过旧(pre-v11)', _diag['shizukuPreV11']),
                          const SizedBox(height: HSpace.sm),
                          Text(_diagConclusion(),
                              style: TextStyle(
                                  fontSize: 12, height: 1.5, color: h.textDim)),
                        ],
                      ),
                    ),
                  ],
                  // 编码层自检：能不能跑通直接取决于上面的执行路由
                  //（App 自己没有 shell 身份，工具链全靠它跑）。
                  const SizedBox(height: HSpace.lg),
                  Text(
                    '编码层自检',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: h.text),
                  ),
                  const SizedBox(height: HSpace.xs),
                  Text(
                    '在手机上真跑一遍：起前台服务 → 读温度/电量 → 定位工具链 → '
                    '建 Hello World → 构建 → 拆包核对。',
                    style:
                        TextStyle(fontSize: 12, height: 1.5, color: h.textDim),
                  ),
                  const SizedBox(height: HSpace.sm),
                  SizedBox(
                    width: double.infinity,
                    child: IosButton(
                      label: '跑一遍编码层自检',
                      color: h.accent,
                      busy: _selfCheckBusy,
                      onPressed: _selfCheckBusy
                          ? null
                          : () async {
                              setState(() {
                                _selfCheckBusy = true;
                                _selfCheckMsg = null;
                              });
                              final r = await AgentBridge().encodeSelfCheck();
                              if (!mounted) return;
                              setState(() {
                                _selfCheckMsg = r;
                                _selfCheckBusy = false;
                              });
                            },
                    ),
                  ),
                  if (_selfCheckBusy)
                    Padding(
                      padding: const EdgeInsets.only(top: HSpace.xs),
                      child: Text('构建要 1–3 分钟，期间请不要切走应用…',
                          style: TextStyle(fontSize: 12, color: h.textDim)),
                    ),
                  if (_selfCheckMsg != null) ...[
                    const SizedBox(height: HSpace.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(HSpace.md),
                      decoration: BoxDecoration(
                        color: h.surfaceAlt,
                        borderRadius: BorderRadius.circular(HRadius.md),
                        border: Border.all(color: h.border),
                      ),
                      child: SelectableText(
                        _selfCheckMsg!,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          fontFamily: kMonoFontFamily,
                          fontFamilyFallback: kMonoFallback,
                          color: h.text,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
    );
  }

  /// 诊断行：名称 + ✅/❌
  Widget _diagRow(Hue h, String label, Object? value) {
    final ok = value == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            ok ? CupertinoIcons.checkmark_circle : CupertinoIcons.minus_circle,
            size: 15,
            color: ok ? HColors.successOn(h.dark) : h.textFaint,
          ),
          const SizedBox(width: HSpace.xs),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: h.textDim)),
          ),
          Text(
            ok ? '是' : '否',
            style: TextStyle(
              fontSize: 12,
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFallback,
              color: ok ? HColors.successOn(h.dark) : h.textFaint,
            ),
          ),
        ],
      ),
    );
  }

  /// 诊断补充文字（缩进小字）
  Widget _diagText(Hue h, String text) => Padding(
        padding: const EdgeInsets.only(left: 22, bottom: 4),
        child: Text(text,
            style: TextStyle(fontSize: 11.5, color: h.textFaint)),
      );

  /// **诊断结论**（把四个状态翻译成一句人话）。
  ///
  /// 用户真正想知道的是"我现在到底能用什么、不能用什么、为什么"。
  String _diagConclusion() {
    final route = (_diag['route'] as String?) ?? '无';
    final stellarGranted = _diag['stellarGranted'] == true;
    final anyInstalled = _diag['stellarInstalled'] == true ||
        _diag['shizukuInstalled'] == true;

    if (route == 'Stellar') {
      return '本机通过 Stellar 提供 shell 能力'
          '${_diag['stellarRoot'] == true ? "（Root 模式，能力最强）" : "（ADB/Shell 模式）"}。'
          '授权请到 Stellar 的「授权应用」里查看。';
    }
    if (route == 'Shizuku') {
      return '本机通过 Shizuku 提供 shell 能力。'
          '若 Shizuku 界面显示 0 个已授权应用，那是它自身的列表问题，不影响功能。';
    }
    if (!anyInstalled) {
      return '未安装 Stellar / Shizuku。请先安装其一并启动服务，再回到这里点授权按钮。';
    }
    if (!stellarGranted && _diag['stellarRunning'] == true) {
      return 'Stellar 服务在运行但尚未授权本 App —— 点上方按钮会弹出它的授权框。';
    }
    return '检测到管理器但服务未运行（或未授权）。'
        '请先在 Stellar / Shizuku 里启动服务，再回到这里点授权按钮。';
  }
}

/// iOS 返回键（AppBar 的 leading）—— 用 Cupertino 的 ‹ 而不是 Material 的 ←。
/// 布局槽位不变，只换视觉语言。
Widget _iosBackLeading(BuildContext context) => IconButton(
      icon: const Icon(AppIcons.back, size: 21),
      onPressed: () => Navigator.of(context).pop(),
    );

// ============================================================ 全局记忆

/// **全局记忆入口**（2026-10-23）—— 主页一行 + 规模徽章，详情在二级页。
///
/// 与「设备权限」同一形态：主页只给"看一眼"的规模，全文与清空在二级页。
/// 从二级页返回后**重新读一次**（用户可能刚点了清空 —— 徽章得跟着变）。
class _GlobalMemoryEntry extends StatefulWidget {
  const _GlobalMemoryEntry({required this.onOpen});

  /// 打开二级页；**返回后**才完成（徽章据此刷新）。
  final Future<void> Function() onOpen;

  @override
  State<_GlobalMemoryEntry> createState() => _GlobalMemoryEntryState();
}

class _GlobalMemoryEntryState extends State<_GlobalMemoryEntry> {
  final _memory = const GlobalMemory();

  /// null = 还没读到。加载中显示 '…' —— 一闪而过的"暂无记忆"比不显示更骗人。
  String? _badge;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final r = await _memory.readResult();
    if (!mounted) return;
    // 读不出来**不说**"暂无记忆" —— 那是两句话，说错就骗人
    setState(() => _badge = r.error != null
        ? '读取失败'
        : (r.isEmpty ? '暂无记忆' : '${_entryCount(r.text)} 条'));
  }

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      title: '全局记忆',
      // 规模作卡片副行 —— 不进二级页也知道记了多少
      subtitle: _badge ?? '…',
      onTap: () async {
        await widget.onOpen();
        // 从二级页返回后再读一次（用户可能刚点了清空）—— 这次是真等 pop
        await _reload();
      },
    );
  }
}

/// **全局记忆二级页**（2026-10-25 改版）—— 结构化条目卡片。
///
/// 记忆存在 App 全局（不在工作区），每轮系统提示都会把它带回去。
/// 后端 N7 落地后记忆按条目组织（kind/source/createdAt），本页按
/// kind 分组逐条展示，可增 / 改 / 删单条，也可整表清空。
/// 旧格式（legacy）条目是纯文本行自动迁移来的，元信息行标「旧格式」。
class GlobalMemoryPage extends StatefulWidget {
  const GlobalMemoryPage({super.key});

  @override
  State<GlobalMemoryPage> createState() => _GlobalMemoryPageState();
}

/// kind 词表（后端定，前端只展示）：分组顺序与中文名。
const _memoryKindOrder = ['preference', 'background', 'habit', 'other'];
const _memoryKindLabels = {
  'preference': '长期偏好',
  'background': '项目背景',
  'habit': '使用习惯',
  'other': '其他',
};

String _memorySourceLabel(String source) => switch (source) {
      'user' => '手动添加',
      'agent' => '模型记的',
      'legacy' => '旧格式',
      _ => source,
    };

String _memoryDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.month}月${d.day}日';
}

/// 卡片头行的短标签（概念图 03 的标签形态：偏好 / 背景 / 习惯 / 其他）
const _memoryKindShort = {
  'preference': '偏好',
  'background': '背景',
  'habit': '习惯',
  'other': '其他',
};

String _memoryDateTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.month}月${d.day}日 $hh:$mm';
}

class _GlobalMemoryPageState extends State<GlobalMemoryPage> {
  final _memory = const GlobalMemory();

  /// null = 读取中（转圈）
  List<MemoryEntry>? _entries;
  ({int usedBytes, int maxBytes})? _capacity;

  /// 清空进行中 —— 右上角动作锁住并转圈，避免连点二次触发
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await _memory.listEntries();
    final cap = await _memory.capacity();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _capacity = cap;
    });
  }

  /// 清空**不可逆** —— 先弹确认抽屉（2026-10-25 起统一走上拉抽屉，
  /// 不再用居中弹窗），破坏性按钮红色实心。
  Future<void> _confirmClear() async {
    final ok = await showBwConfirmSheet(
      context,
      title: '清空全局记忆？',
      message: '所有跨会话记忆都会被删除，无法恢复。'
          '之后的新会话不再带着这些内容开始。',
      confirmLabel: '清空记忆',
      destructive: true,
    );
    if (ok && mounted) await _doClear();
  }

  Future<void> _doClear() async {
    setState(() => _clearing = true);
    final ok = await _memory.clear();
    if (!mounted) return;
    setState(() => _clearing = false);
    if (!ok) {
      showIosToast(context, '清空失败');
      return;
    }
    await _load();
    if (!mounted) return;
    showIosToast(context, '已清空');
  }

  Future<void> _confirmDelete(MemoryEntry e) async {
    final ok = await showBwConfirmSheet(
      context,
      title: '删除这条记忆？',
      message: e.text.length > 80 ? '${e.text.substring(0, 80)}…' : e.text,
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final r = await _memory.deleteEntry(e.id);
    if (!mounted) return;
    if (!r.ok) {
      showIosToast(context, r.error ?? '删除失败');
      return;
    }
    await _load();
  }

  Future<void> _openEditor({MemoryEntry? entry}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemoryEditorSheet(memory: _memory, entry: entry),
    );
    if (saved == true) {
      await _load();
      if (!mounted) return;
      showIosToast(context, entry == null ? '已添加' : '已保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final entries = _entries;
    final cap = _capacity;
    final nearlyFull =
        cap != null && cap.usedBytes >= cap.maxBytes * 0.9;
    return Scaffold(
      appBar: AppBar(
        title: const Text('全局记忆'),
        leading: _iosBackLeading(context),
        actions: [
          CupertinoButton(
            onPressed: () => _openEditor(),
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
            child: Icon(AppIcons.add, size: 22, color: h.text),
          ),
          // 没有记忆就没有可清的东西 —— 动作干脆不出现（iOS 的做法）
          if (entries != null && entries.isNotEmpty)
            CupertinoButton(
              onPressed: _clearing ? null : _confirmClear,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: _clearing
                    ? CupertinoActivityIndicator(
                        radius: 8, color: HColors.errorOn(h.dark))
                    : Text('清空',
                        style: TextStyle(
                            fontSize: 13.5,
                            color: HColors.errorOn(h.dark))),
              ),
            ),
          const SizedBox(width: HSpace.sm),
        ],
      ),
      body: entries == null
          ? Center(child: CupertinoActivityIndicator(color: h.accent))
          : ListView(
              padding: const EdgeInsets.all(HSpace.lg),
              children: [
                // ---- 容量头卡（2026-10-25 晚按概念图 03）：大数字 +
                //   容量条 + 已用/上限，一张卡说清规模 ----
                if (cap != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    decoration: BoxDecoration(
                      color: h.surfaceAlt,
                      borderRadius: BorderRadius.circular(HRadius.xl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              '${entries.length}',
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: h.text,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '条记忆',
                              style:
                                  TextStyle(fontSize: 14, color: h.textDim),
                            ),
                            const Spacer(),
                            Text(
                              nearlyFull ? '接近上限，建议清理' : '会注入每次对话',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: nearlyFull
                                    ? HColors.warnOn(h.dark)
                                    : h.textFaint,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: cap.maxBytes > 0
                                ? (cap.usedBytes / cap.maxBytes)
                                    .clamp(0.0, 1.0)
                                : 0,
                            minHeight: 6,
                            backgroundColor: h.border,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              nearlyFull
                                  ? HColors.warnOn(h.dark)
                                  : h.text,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              '已用 ${_fmtBytes(cap.usedBytes)}',
                              style: TextStyle(
                                  fontSize: 12, color: h.textFaint),
                            ),
                            const Spacer(),
                            Text(
                              '上限 ${_fmtBytes(cap.maxBytes)}',
                              style: TextStyle(
                                  fontSize: 12, color: h.textFaint),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: HSpace.lg),
                ],
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36),
                    child: Text(
                      '还没有任何记忆。\n和 Heracles 聊天时它会把值得记住的事'
                      '写在这里（跨会话生效），也可以点右上角 + 手动添加。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: h.textFaint,
                      ),
                    ),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: HSpace.sm),
                    child: Text(
                      '全部记忆',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: h.textDim,
                      ),
                    ),
                  ),
                  for (final e in entries)
                    _MemoryCard(
                      entry: e,
                      h: h,
                      onEdit: () => _openEditor(entry: e),
                      onDelete: () => _confirmDelete(e),
                    ),
                  const SizedBox(height: HSpace.sm),
                  Center(
                    child: Text(
                      '记忆由对话自动提炼，也可以手动添加',
                      style: TextStyle(fontSize: 12, color: h.textFaint),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// 一条记忆的卡片：正文 + 来源/日期元信息 + 编辑/删除。
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.entry,
    required this.h,
    required this.onEdit,
    required this.onDelete,
  });

  final MemoryEntry entry;
  final Hue h;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // 卡底元信息：来源（手动添加 / 模型记的 / 旧格式）+ 到期标注
    final meta = <String>[
      _memorySourceLabel(entry.source),
      if (entry.expiresAt != null) '到期 ${_memoryDate(entry.expiresAt!)}',
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: HSpace.sm),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头行（概念图 03）：类别标签 + 日期 …… 编辑 / 删除小方钮
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _memoryKindShort[entry.kind] ?? entry.kind,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: h.textDim,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (entry.createdAt > 0)
                Text(
                  _memoryDateTime(entry.createdAt),
                  style: TextStyle(fontSize: 12, color: h.textFaint),
                ),
              const Spacer(),
              _iconBtn(AppIcons.edit, onEdit),
              const SizedBox(width: 6),
              _iconBtn(AppIcons.trash, onDelete),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            entry.text,
            style: TextStyle(fontSize: 14.5, height: 1.55, color: h.text),
          ),
          const SizedBox(height: 6),
          Text(
            meta.join(' · '),
            style: TextStyle(fontSize: 11.5, color: h.textFaint),
          ),
        ],
      ),
    );
  }

  /// 头行小方钮：浅底圆角 + 填充图标（危险色留给确认抽屉承担）
  Widget _iconBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: h.surface,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 15, color: h.textDim),
        ),
      );
}

/// 记忆编辑抽屉：新增（可选 kind）/ 编辑正文。
///
/// 写入失败（疑似密钥拒收 / 超限）把后端给的人话原因直接显示在
/// 输入框下方，不吞错误。
class _MemoryEditorSheet extends StatefulWidget {
  const _MemoryEditorSheet({required this.memory, this.entry});

  final GlobalMemory memory;
  final MemoryEntry? entry;

  @override
  State<_MemoryEditorSheet> createState() => _MemoryEditorSheetState();
}

class _MemoryEditorSheetState extends State<_MemoryEditorSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.entry?.text ?? '');
  String _kind = 'other';
  String? _error;
  bool _saving = false;

  bool get _isEdit => widget.entry != null;

  Future<void> _save() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '内容为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final r = _isEdit
        ? await widget.memory.updateEntry(widget.entry!.id, text)
        : await widget.memory.addEntry(text, kind: _kind, source: 'user');
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _saving = false;
        _error = r.error ?? '保存失败';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: h.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(
            HSpace.lg, HSpace.md, HSpace.lg, HSpace.lg),
        child: SafeArea(
          top: false,
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
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: HSpace.md),
              Text(
                _isEdit ? '编辑记忆' : '添加记忆',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: h.text,
                ),
              ),
              const SizedBox(height: HSpace.md),
              CupertinoTextField(
                controller: _ctrl,
                autofocus: true,
                maxLines: 5,
                minLines: 3,
                placeholder: '写下要长期记住的事…',
                style: TextStyle(fontSize: 15, color: h.text),
                placeholderStyle:
                    TextStyle(fontSize: 15, color: h.textFaint),
                decoration: BoxDecoration(
                  color: h.surfaceAlt,
                  borderRadius: BorderRadius.circular(HRadius.md),
                  border: Border.all(color: h.border),
                ),
                padding: const EdgeInsets.all(HSpace.md),
              ),
              if (!_isEdit) ...[
                const SizedBox(height: HSpace.md),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final kind in _memoryKindOrder)
                      GestureDetector(
                        onTap: () => setState(() => _kind = kind),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: _kind == kind ? h.text : h.surfaceAlt,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: h.border),
                          ),
                          child: Text(
                            _memoryKindLabels[kind] ?? kind,
                            style: TextStyle(
                              fontSize: 13,
                              color: _kind == kind
                                  ? (h.dark
                                      ? const Color(0xFF0A0A0B)
                                      : Colors.white)
                                  : h.textDim,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: HSpace.sm),
                Text(
                  _error!,
                  style: TextStyle(
                      fontSize: 13, color: HColors.errorOn(h.dark)),
                ),
              ],
              const SizedBox(height: HSpace.md),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  onPressed: _saving ? null : _save,
                  color: h.text,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  borderRadius: BorderRadius.circular(HRadius.md),
                  child: _saving
                      ? CupertinoActivityIndicator(
                          radius: 9,
                          color: h.dark
                              ? const Color(0xFF0A0A0B)
                              : Colors.white)
                      : Text(
                          '保存',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: h.dark
                                ? const Color(0xFF0A0A0B)
                                : Colors.white,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 条目数 = 非空行数。
///
/// 与存储侧同一口径：Kotlin 那边**一条一行**（行首 ISO 时间戳由它加），
/// 而契约只给全文字符串、没有单独的条数字段 —— 所以这里按行数，
/// **不要**再在别处发明第二种"条数"算法。
int _entryCount(String text) =>
    text.split('\n').where((l) => l.trim().isNotEmpty).length;

/// 人类可读的字节数：整数就不带小数（256 KB），否则一位小数（3.4 KB）。
String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${_fmtNum(kb)} KB';
  return '${_fmtNum(kb / 1024)} MB';
}

/// 数字显示：整数值不带小数点（256），否则一位小数（3.4）。
String _fmtNum(double v) =>
    v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

// ------------------------------------------------------------
// 记忆的**真存储**在 `services/global_memory.dart`（写进
// `<externalFilesDir>/heracles/memory.md`，与工作区无关、跨工作区共享，
// 由 `local_agent` 每轮读出来注入 system prompt）。
// 上面这一节只是它的**查看 + 清空 UI**：读走 `readResult()` 而不是 `read()`
// —— 它带真实字节数与失败原因，而"读不出来"和"还没有记忆"对用户是两句话。

// ============================================================ 通用设置
class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('通用设置'), leading: _iosBackLeading(context)),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: controller,
        builder: (context, s, _) {
          final h = Hue.of(context);
          return ListView(
          padding: const EdgeInsets.only(bottom: HSpace.xl),
          children: [
            // ★ 卡片式（2026-10-25 晚，用户批准概念图 heracles-ui-general）：
            //   每项一张卡、卡内只有一套控件。字号是连续量用滑杆；
            //   其余离散档位用分段胶囊；流式只报状态；权限卡内含中性
            //   警示行。旧版「值胶囊 + 滑杆」双控件与步进器全部退役。
            //   页尾权限组（默认权限 + 始终允许）是安全设置、没有第二
            //   个入口，随卡片化保留。
            const _SectionLabel('显示'),
            _SettingsCard(
              title: '界面语言',
              subtitle: '界面与回复使用的语言',
              child: _SegControl<AppLanguage>(
                value: s.language,
                options: AppLanguage.values,
                labelOf: (v) => v.label,
                onChanged: controller.setLanguage,
              ),
            ),
            _SettingsCard(
              title: '字号大小',
              subtitle: '全局字阶按比例缩放，拖动实时预览',
              trailing: Text(
                '${_fontStopLabel(s.fontSize)} · ${s.fontSize.round()}',
                style: TextStyle(fontSize: 14, color: h.textDim),
              ),
              child: Column(
                children: [
                  CupertinoSlider(
                    value: s.fontSize,
                    min: 12,
                    max: 20,
                    activeColor: h.text,
                    onChanged: controller.setFontSize,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('小',
                            style: TextStyle(
                                fontSize: 12, color: h.textFaint)),
                        Text('大',
                            style: TextStyle(
                                fontSize: 12, color: h.textFaint)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const _SectionLabel('行为'),
            _SettingsCard(
              title: '工作步骤展示',
              subtitle: '选择希望看到多少工具调用细节',
              child: _SegControl<StepDetail>(
                value: s.stepDetail,
                options: StepDetail.values,
                labelOf: (v) => v.label,
                onChanged: controller.setStepDetail,
              ),
            ),
            _SettingsCard(
              title: '繁忙时发送',
              subtitle: '任务执行中发消息如何处理',
              child: _SegControl<BusySendBehavior>(
                value: s.busySend,
                options: BusySendBehavior.values,
                labelOf: (v) => v == BusySendBehavior.queue ? '排队' : '插队',
                onChanged: controller.setBusySend,
              ),
            ),
            _SettingsCard(
              title: '最大轮次',
              subtitle: '单次任务最多执行的工具轮次',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SegControl<int>(
                    value: s.maxTurns,
                    options: kMaxTurnsOptions,
                    labelOf: (v) => v == 0 ? '自动' : '$v',
                    onChanged: controller.setMaxTurns,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '自动 = 云端 40 轮（默认）。轮次越多，单次任务能做的步骤'
                    '越多，但可能跑更久；云端按轮计费，花费也更多。',
                    style: TextStyle(
                        fontSize: 12, height: 1.5, color: h.textFaint),
                  ),
                ],
              ),
            ),
            // ---- 流式输出：默认开启、不设关闭开关（用户拍板）----
            _SettingsCard(
              title: '流式输出',
              subtitle: '逐字显示模型回复',
              trailing: Text('始终开启',
                  style: TextStyle(fontSize: 14, color: h.textDim)),
            ),
            const _SectionLabel('权限'),
            _SettingsCard(
              title: '新会话的默认权限',
              subtitle: '决定工具执行前是否需要你确认',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SegControl<PermissionMode>(
                    value: s.permission,
                    options: PermissionMode.values,
                    labelOf: (v) => v.label,
                    onChanged: controller.setPermission,
                  ),
                  if (s.permission.requiresElevation) ...[
                    const SizedBox(height: 13),
                    const _CardWarnNote(
                      '「完全访问」需要 Shizuku 或 root 才能真正生效。',
                    ),
                  ],
                ],
              ),
            ),
            const _AlwaysAllowedRow(),
          ],
          );
        },
      ),
    );
  }
}

// ============================================================ 模型

class ModelSettingsPage extends StatelessWidget {
  const ModelSettingsPage({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('模型'), leading: _iosBackLeading(context)),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: controller,
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.all(HSpace.lg),
          children: [
            Text(
              '填入各提供商的 API 密钥即可使用其模型。',
              style: TextStyle(fontSize: 13, color: h.textFaint),
            ),
            const SizedBox(height: HSpace.lg),
            ...s.providers.map((p) => _ProviderCard(
                  provider: p,
                  onEdit: () => _edit(context, p),
                  onSetDefault: () => controller.setDefaultProvider(p.id),
                  onDelete: p.isOfficialAccount
                      ? null
                      : () => controller.removeProvider(p.id),
                )),
            const SizedBox(height: HSpace.sm),
            _AddProviderButton(onTap: () => _add(context)),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, ModelProviderConfig p) async {
    final result = await Navigator.of(context).push<ModelProviderConfig>(
      CupertinoPageRoute(builder: (_) => ProviderEditPage(provider: p)),
    );
    if (result != null) await controller.updateProvider(result);
  }

  Future<void> _add(BuildContext context) async {
    final result = await Navigator.of(context).push<ModelProviderConfig>(
      CupertinoPageRoute(
        builder: (_) => const ProviderEditPage(
          provider: ModelProviderConfig(
            id: '',
            name: '',
            baseUrl: 'https://',
            model: '',
          ),
          isNew: true,
        ),
      ),
    );
    if (result != null) await controller.addProvider(result);
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.onEdit,
    required this.onSetDefault,
    this.onDelete,
  });

  final ModelProviderConfig provider;
  final VoidCallback onEdit;
  final VoidCallback onSetDefault;
  final VoidCallback? onDelete;

  /// **长按卡片 → 弹出操作菜单**（2026-10-14，用户要求）。
  ///
  /// ## 为什么用底部弹层而不是 contextMenu
  ///
  /// 与 App 其他地方一致（模型选择、权限选择都是 `showModalBottomSheet`）——
  /// 且真机实测锚点式菜单在键盘弹出时会错位（`docs/25` 记录的坑）。
  ///
  /// ## 为什么不用左滑删除
  ///
  /// `Dismissible` 在**卡片式列表**里容易误触（本卡片有"编辑/设为默认"
  /// 两个按钮在同一行），且删除 provider 是**不可逆**操作 ——
  /// 长按是明确的、需要停留的意图表达，更安全。
  Future<void> _showActions(BuildContext context) async {
    if (onDelete == null) return; // 官方账号不可删
    final h = Hue.of(context);
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (sheetCtx) => CupertinoActionSheet(
        title: Text(
          provider.name.isEmpty ? '(未命名)' : provider.name,
          style: TextStyle(fontSize: 14, color: h.textDim),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(sheetCtx).pop(false),
            child: const Text('编辑'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('删除'),
                Text(
                  '同时清除已保存的 API Key',
                  style: TextStyle(fontSize: 11.5, color: h.textFaint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (confirmed == true) {
      // ★ 二次确认 —— 删除不可逆（连带清掉 Keystore 里的 Key）
      final ok = await showBwConfirmSheet(
        context,
        title: '删除这个提供商？',
        message: '「${provider.name.isEmpty ? "(未命名)" : provider.name}」的配置'
            '与已保存的 API Key 都会被清除，无法恢复。',
        confirmLabel: '删除',
        destructive: true,
      );
      if (ok && context.mounted) onDelete?.call();
    } else if (confirmed == false) {
      onEdit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    // ★★ "可用"的判据必须包含自建后端（2026-10-15 真机实测修复）★★
    //
    // ## 修的是什么
    //
    // 用户实测（截图）：**本地模型（llama.cpp）与 qwen 明明能用**
    //（聊天页能选、qwen 的"测试连接"通过），设置页却显示
    // ⚪ 灰点 + 「未配置 API Key」—— 用户会以为配置坏了。
    //
    // ## 根因
    //
    // 旧判据只有 `apiKey.isNotEmpty` —— **漏了"自建/局域网不需要 Key"**。
    // `AppSettings.isLocalConfig` 早已能识别自建后端
    //（RFC1918 私有网段 + 回环），但这里没用它。
    //
    // ⚠️ 这是**同一类 bug 的漏网**：模型选择弹层（`input_bar.dart`）
    //    早就用了 `isConfigured || isLocalConfig` 的正确判据，
    //    设置页这份没跟上 —— 两处判据不一致才会出现
    //    "能选但显示未配置"的矛盾现象。
    //
    // 现在两处统一：**判"可用"一律走这个方法**。
    final configured =
        provider.isConfigured || AppSettings.isLocalConfig(provider);
    return GestureDetector(
      // ★ 长按 → 操作菜单（编辑 / 删除）
      onLongPress: onDelete == null ? null : () => _showActions(context),
      child: Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      decoration: BoxDecoration(
        color: h.surface,
        borderRadius: BorderRadius.circular(HRadius.lg),
        border: Border.all(
          color: provider.isDefault ? h.accent : h.border,
          width: provider.isDefault ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.sm, HSpace.md),
        child: Row(
          children: [
            // 配置状态点 —— 一眼看出哪个能用
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: configured ? HColors.successOn(h.dark) : h.textFaint,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: HSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          provider.name.isEmpty ? '(未命名)' : provider.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                            color: h.text,
                          ),
                        ),
                      ),
                      if (provider.isDefault) ...[
                        const SizedBox(width: HSpace.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: h.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(HRadius.pill),
                          ),
                          child: Text(
                            '默认',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: h.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // ★ 副标题也要认自建后端（2026-10-15，BUG-4 同一处）——
                    //   本地/自建 provider 没有 API Key 是**正常的**，
                    //   不该显示"未配置"。
                    configured
                        ? '${provider.model} · ${provider.baseUrl}'
                        : '未配置 API Key',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: h.textFaint,
                    ),
                  ),
                ],
              ),
            ),
            if (!provider.isDefault && configured)
              CupertinoButton(
                onPressed: onSetDefault,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
                foregroundColor: h.textDim,
                child: Text('设为默认', style: TextStyle(fontSize: 12)),
              ),
            CupertinoButton(
              onPressed: onEdit,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
              foregroundColor: h.text,
              child: Text('编辑', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _AddProviderButton extends StatelessWidget {
  const _AddProviderButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return IosTap(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(HRadius.lg),
          border: Border.all(
            color: h.border,
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(AppIcons.add, size: 19, color: h.textDim),
            SizedBox(width: HSpace.sm),
            Text(
              '添加模型提供商',
              style: TextStyle(fontSize: 13.5, color: h.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

/// 提供商编辑页 —— **真实功能**：填完后 `enabled` 变 true，
/// 可以作为后端使用。
class ProviderEditPage extends StatefulWidget {
  const ProviderEditPage({super.key, required this.provider, this.isNew = false});

  final ModelProviderConfig provider;
  final bool isNew;

  @override
  State<ProviderEditPage> createState() => _ProviderEditPageState();
}

class _ProviderEditPageState extends State<ProviderEditPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.provider.name);
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.provider.baseUrl);
  late final TextEditingController _model =
      TextEditingController(text: widget.provider.model);
  late final TextEditingController _apiKey =
      TextEditingController(text: widget.provider.apiKey);
  bool _obscure = true;

  /// **上下文长度**（token，2026-10-14 用户反馈新增）。
  ///
  /// 用户实测：基元律动的 `deepseek-v4-flash-0731` 是 **1M**，
  /// 而 App 猜 128K → ① 使用率失真 ② **按 128K×0.8 过早压缩会话**。
  ///
  /// 留空 = 用后端默认（本地 4096 / 云端 128K）。
  /// 「获取可用模型」若从 `/models` 读到真实值，会自动填进来。
  late final TextEditingController _contextLength = TextEditingController(
    text: widget.provider.contextLength > 0
        ? widget.provider.contextLength.toString()
        : '',
  );

  /// **已选模型目录**（2026-10-14，参考图对齐：容器 + 多选）。
  ///
  /// 参考图的关键差异：不是"单选替换模型名"，而是**模型目录**——
  /// 拉回来打勾多个，目录外的 ID 仍可手填直发。
  ///
  /// ★ 初值必须来自 [widget.provider.modelCatalog]（2026-10-14
  ///   真机 bug：原来写死 `const []` —— 每次进编辑页目录都空，
  ///   保存后把已存的目录**覆盖回空**，用户"保存了但目录里不显示"）。
  late List<String> _modelCatalog = [...widget.provider.modelCatalog];

  /// 拉取中（右上角轻量转圈）
  bool _loadingModels = false;

  /// **模型能力缓存**（2026-10-14 第三版）—— 从服务端拉到，
  /// 保存时随 provider 一起持久化。
  ///
  /// 为什么要持久化：第二版放内存里，App 重启就丢，用户又看到
  /// 「⚠️ 未从服务端获取」。用户实测抓到了这个。
  late Map<String, ModelCapability> _modelCapabilities = {
    ...widget.provider.modelCapabilities,
  };

  /// 拉取失败的提示
  String? _modelsError;

  /// **API 协议**（2026-10-14）—— 初值 = 已存的声明（默认 OpenAI Chat）
  late ProviderProtocol _protocol = widget.provider.protocol;

  /// **拉取可用模型**（GET {baseUrl}/models，OpenAI 标准端点）。
  Future<void> _fetchModels() async {
    final baseUrl = _baseUrl.text.trim();
    final apiKey = _apiKey.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _modelsError = '先填 API 地址');
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final bridge = AgentBridge();
      final models = await bridge.fetchModels(baseUrl: baseUrl, apiKey: apiKey);
      if (!mounted) return;
      setState(() {
        // 合并进目录（保留用户手填的，去重 + 排序）
        final merged = [..._modelCatalog, ...models];
        _modelCatalog = merged.toSet().toList()..sort();
      });

      // ★ 把服务端返回的**能力**存进本页状态（2026-10-14 第三版）——
      //   上下文长度等能力**必须持久化**，否则：
      //   · App 重启后丢失 → 又退回兜底值
      //   · 用户不点本按钮 → 永远兜底
      //   持久化在 `_save()` 里随 provider 一起写盘。
      final caps = bridge.lastFetchedCaps;
      if (caps.isNotEmpty) {
        setState(() {
          _modelCapabilities = {
            for (final e in caps.entries)
              e.key: ModelCapability(
                contextWindow: e.value.contextWindow ?? 0,
                maxOutputTokens: e.value.maxOutputTokens,
                supportsTools: e.value.supportsTools,
                supportsReasoning: e.value.supportsReasoning,
                reasoningLevelsEffective:
                    _protocol.reasoningLevelsEffective,
              ),
          };
        });
      }

      if (!mounted) return;
      final withCaps = caps.values.where((c) => c.contextWindow != null).length;
      showIosToast(
        context,
        '找到 ${models.length} 个模型'
        '${withCaps > 0 ? "（$withCaps 个含上下文长度）" : "（服务端未提供上下文长度）"}',
      );
    } on AgentBridgeException catch (e) {
      if (!mounted) return;
      setState(() => _modelsError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelsError = '$e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  /// **删除 _FetchModelsButton 的说明**（2026-10-14）：
  /// 首版做成"大按钮 + 展开列表"，用户给了参考图 —— 形态是
  /// 「模型目录」标签 + 右上角轻量入口 + 已选容器（+ 添加）。
  /// 已按参考图重构为内联 UI（见 `_fetchModels` 与 build 里的目录区）。

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _contextLength.dispose();
    super.dispose();
  }

  void _save() {
    // ★ 模型同步（2026-10-14）：目录里的第一项 = 实际发送用的 model。
    //
    // 用户原话：「要模型名干嘛？下面不是加入了嘛？」——
    // 单值"模型名"输入框已删；model 字段保留（请求需要），
    // 但它的值来自目录（用户点选），不再有独立输入框。
    //
    // ⚠️ 目录为空且 _model 也空 → 不覆盖（保持原值，避免把
    //    已能用的配置改坏）。
    final currentModel = _model.text.trim();
    if (_modelCatalog.isNotEmpty && !_modelCatalog.contains(currentModel)) {
      _model.text = _modelCatalog.first;
    }
    final p = widget.provider.copyWith(
      name: _name.text.trim().isEmpty
          ? (_model.text.trim().isEmpty ? '未命名' : _model.text.trim())
          : _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      apiKey: _apiKey.text.trim(),
      // ★ API 协议（2026-10-14）：决定 AgentBridge 分派到哪个 provider
      protocol: _protocol,
      // ★ 上下文长度（2026-10-14）：留空 → 0（用后端默认）
      contextLength: int.tryParse(_contextLength.text.trim()) ?? 0,
      // ★ 模型能力（2026-10-14 第三版）：从服务端拉到的一并持久化，
      //   否则 App 重启后又退回兜底值（用户实测抓到的 bug）
      modelCapabilities: _modelCapabilities,
      // ★ 模型目录（2026-10-14）：拉取/手填的可用模型清单
      modelCatalog: _modelCatalog,
    );
    final result = widget.isNew
        ? ModelProviderConfig(
            id: 'p${DateTime.now().millisecondsSinceEpoch}',
            name: p.name,
            baseUrl: p.baseUrl,
            model: p.model,
            apiKey: p.apiKey,
            enabled: p.isConfigured,
            modelCatalog: p.modelCatalog,
            // ★ 2026-10-19 修 bug：新增 provider 时漏了这三项 ——
            //   走"添加"路径保存后，协议退回 openaiChat、上下文长度归 0、
            //   刚拉到的模型能力全丢（编辑路径一直是对的，两处字段清单已经漂移）。
            protocol: p.protocol,
            contextLength: p.contextLength,
            modelCapabilities: p.modelCapabilities,
          )
        : p;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? '添加提供商' : '编辑提供商'),
        leading: _iosBackLeading(context),
        actions: [
          CupertinoButton(
            onPressed: _save,
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
            foregroundColor: h.accent,
            child: const Text('保存'),
          ),
          const SizedBox(width: HSpace.sm),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(HSpace.lg),
        children: [
          _Field(label: '名称', controller: _name, hint: '例如：我的 DeepSeek'),
          _Field(
            label: 'Base URL',
            controller: _baseUrl,
            hint: 'https://api.deepseek.com/v1',
            keyboard: TextInputType.url,
          ),
          // ---- ★ API 协议下拉（2026-10-14，三协议真实支持）----
          //
          // 参考图的下拉三项。三种都**真实实现**（各有 Kotlin provider），
          // 不是假装 —— 见 ProviderProtocol 的 doc 与 AgentBridge 分派。
          //
          // ## 顺序按参考图：API 地址 → API 协议 → API 密钥
          Padding(
            padding: const EdgeInsets.only(top: HSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('API 协议',
                    style: TextStyle(fontSize: 12.5, color: h.textDim)),
                const SizedBox(height: HSpace.xs),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: HSpace.md),
                  decoration: BoxDecoration(
                    border: Border.all(color: h.border),
                    borderRadius: BorderRadius.circular(HRadius.sm),
                  ),
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(
                        0, kMinInteractiveDimensionCupertino),
                    alignment: Alignment.centerLeft,
                    onPressed: () async {
                      final p = await showCupertinoModalPopup<ProviderProtocol>(
                        context: context,
                        builder: (sheetCtx) => CupertinoActionSheet(
                          title: const Text('API 协议'),
                          actions: [
                            for (final o in ProviderProtocol.values)
                              CupertinoActionSheetAction(
                                isDefaultAction: o == _protocol,
                                onPressed: () =>
                                    Navigator.of(sheetCtx).pop(o),
                                child: Text(o.label),
                              ),
                          ],
                        ),
                      );
                      if (p != null) setState(() => _protocol = p);
                    },
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(_protocol.label,
                              style: TextStyle(
                                  fontSize: 14, color: h.text)),
                        ),
                        Icon(AppIcons.chevronDown,
                            size: 17, color: h.textFaint),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ★ 「模型名」单值字段已删（2026-10-14，用户原话：
          //   「要模型名干嘛？下面不是加入了嘛？」）——
          //   模型从**模型目录**选（目录第一项 = 实际发送用的 model）。
          _Field(
            label: 'API Key',
            controller: _apiKey,
            hint: 'sk-...',
            obscure: _obscure,
            trailing: CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
              minimumSize: const Size(0, 32),
              onPressed: () => setState(() => _obscure = !_obscure),
              child: Icon(
                _obscure ? CupertinoIcons.eye_slash : AppIcons.eye,
                size: 19,
                color: h.textFaint,
              ),
            ),
          ),
          // ★ Key 指纹（2026-10-14）—— 判断"填进去的到底是什么"
          //
          // ## 为什么需要
          //
          // 用户实测 401「未认证或登录已过期」时**无法区分**：
          //   · Key 填错了 / 复制少了字符
          //   · 前后带了空格或换行（复制常见）
          //   · 服务器侧未激活 / 余额不足
          //
          // 显示长度 + 首尾字符就能定位前两种，而**不泄漏 Key 本身**
          //（只露头尾各 4 字符）。
          //
          // 用 ValueListenableBuilder 跟随输入实时更新 ——
          // 否则用户改了内容提示不刷新，反而误导。
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _apiKey,
            builder: (_, v, _) {
              final k = v.text;
              if (k.isEmpty) return const SizedBox.shrink();
              final trimmed = k.trim();
              final hasWs = k != trimmed;
              return Padding(
                padding: const EdgeInsets.only(top: HSpace.xs),
                child: Text(
                  hasWs
                      ? '⚠️ Key 共 ${k.length} 字符，但首尾有空白'
                          '（${k.length - trimmed.length} 个）—— 请删掉'
                      : 'Key 共 ${k.length} 字符'
                          '（${k.substring(0, k.length >= 4 ? 4 : k.length)}…'
                          '${k.length >= 4 ? k.substring(k.length - 4) : ""}）',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hasWs ? HColors.warnOn(h.dark) : h.textFaint,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: HSpace.md),
          // ★ 「上下文长度」输入框已移除（2026-10-14，用户批评后改）
          //
          // ## 用户原话
          //
          // > 「上下文长度是1M就是1M，**不用自己选的**，你还跟我让用户
          // >   自己去选，你觉得这合理吗？这对吗？」
          //
          // ## 用户是对的 —— 这是架构问题，不是配置问题
          //
          // 调研业界做法（2026-10-14）：
          // | 服务 | 上下文长度来源 |
          // |---|---|
          // | OpenRouter | `GET /api/v1/models` 的 `context_length` 字段（自动）|
          // | LiteLLM | 维护 `model_prices_and_context_window.json` 映射表（自动查表）|
          // | Claude Code / Codex | 内置模型元数据表（自动，用户从不配置）|
          //
          // **没有一个让用户手填** —— agent 必须自己知道模型能力，
          // 这是 harness 的责任（上下文管理模块）。
          //
          // 现在改为自动三层（见 `ModelContextTable`）：
          //   ① `/v1/models` 返回的 context_length（最准）
          //   ② 内置模型名 → 上下文长度表（已知模型）
          //   ③ 按后端类型的保守默认（兜底）
          // ---- ★ 模型目录（2026-10-14，按参考图对齐）----
          //
          // 参考图形态：「模型目录」标签 + 右上角轻量入口「获取可用模型」
          // + 已选容器（+ 添加模型；目录外 ID 仍可手填直发）。
          //
          // 为什么必须做：接入聚合服务（基元律动等）时**不可能手填对
          // 模型名** —— 一个字符错就 404/400。OpenAI 兼容服务都有
          // 标准端点 GET /v1/models。
          Row(
            children: [
              Text('模型目录', style: TextStyle(fontSize: 13, color: h.textDim)),
              const Spacer(),
              IosTap(
                onTap: _loadingModels ? null : _fetchModels,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HSpace.xs),
                  child: _loadingModels
                      ? CupertinoActivityIndicator(
                          radius: 6, color: h.accent)
                      : Text('获取可用模型',
                          style: TextStyle(fontSize: 12, color: h.accent)),
                ),
              ),
            ],
          ),
          const SizedBox(height: HSpace.xs),
          // 拉取失败的人话提示（401 = Key 错 / 超时 = 网络不通 等）
          if (_modelsError != null) ...[
            Text(
              '❌ $_modelsError',
              style: TextStyle(fontSize: 12, color: HColors.errorOn(h.dark)),
            ),
            const SizedBox(height: HSpace.xs),
          ],
          // 已选模型容器（虚线边框空态 = 参考图同款）
          if (_modelCatalog.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HSpace.md),
              decoration: BoxDecoration(
                border: Border.all(color: h.border),
                borderRadius: BorderRadius.circular(HRadius.sm),
              ),
              child: Text(
                '模型选择器中将不显示任何模型；目录外 ID 仍可直接发送。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: h.textFaint),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: h.border),
                borderRadius: BorderRadius.circular(HRadius.sm),
              ),
              child: Column(
                children: [
                  // ★ 点选目录项 = **选用**这个模型（2026-10-14）——
                  //   选中的会作为实际发送用的 model（对照参考图：
                  //   「选择基元律动来当模型用是可以点进去选择模型的」）
                  for (final id in _modelCatalog)
                    CupertinoListTile(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      title: Text(id,
                          style: TextStyle(
                              fontSize: 13,
                              fontFamily: kMonoFontFamily,
                              fontFamilyFallback: kMonoFallback,
                              // 选中的高亮
                              color: id == _model.text ? h.accent : h.text,
                              fontWeight: id == _model.text
                                  ? FontWeight.w600
                                  : FontWeight.w400)),
                      // 选中态对勾
                      trailing: id == _model.text
                          ? Icon(AppIcons.check, size: 17, color: h.accent)
                          : CupertinoButton(
                              padding: const EdgeInsets.all(6),
                              minimumSize: const Size(0, 28),
                              onPressed: () => setState(() =>
                                  _modelCatalog =
                                      [..._modelCatalog]..remove(id)),
                              child: Icon(AppIcons.trash,
                                  size: 18, color: h.textFaint),
                            ),
                      onTap: () => setState(() => _model.text = id),
                    ),
                ],
              ),
            ),
          const SizedBox(height: HSpace.sm),
          // 手填入口（目录外 ID 仍可直发 —— 参考图说明）
          Row(
            children: [
              Expanded(
                child: CupertinoTextField(
                  controller: _model,
                  style: TextStyle(fontSize: 14, color: h.text),
                  placeholder: '手填模型 ID（目录外也可直接发送）',
                  placeholderStyle: TextStyle(fontSize: 12, color: h.textFaint),
                  padding: const EdgeInsets.symmetric(
                      horizontal: HSpace.sm, vertical: HSpace.sm),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(HRadius.sm),
                    border: Border.all(color: h.border),
                  ),
                ),
              ),
              const SizedBox(width: HSpace.sm),
              IosButton(
                label: '+ 添加',
                filled: false,
                color: h.accent,
                dense: true,
                onPressed: () {
                  final id = _model.text.trim();
                  if (id.isEmpty) return;
                  setState(() {
                    if (!_modelCatalog.contains(id)) {
                      _modelCatalog = [..._modelCatalog, id];
                    }
                    // ★ 添加即选用（与点选目录项同语义）
                    _model.text = id;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: HSpace.md),
          // ---- ★ 测试连接（2026-10-12，用户要求）----
          //
          // 填完 baseUrl/Key/模型名，点一下就知道通不通 ——
          // 不用保存回主界面再发消息试错。
          //
          // ## 为什么不用主界面的 AgentBridge
          //
          // 那条链路会建会话、落盘、吃上下文预算 —— 测连通性
          // 不该有副作用。这里直接 HTTP POST 一个 max_tokens=1 的
          // 最小请求，读状态码就够（OpenAI 兼容端点 401=Key 错、
          // 404=路径错、超时=网络不通）。
          _TestConnectionButton(
            h: h,
            getBaseUrl: () => _baseUrl.text.trim(),
            getApiKey: () => _apiKey.text.trim(),
            getModel: () => _model.text.trim(),
          ),
        ],
      ),
    );
  }
}

/// **「测试连接」按钮**（2026-10-12，用户要求加在自定义模型配置界面）。
///
/// 向 `<baseUrl>/chat/completions` 发一个 `max_tokens: 1` 的最小请求，
/// 把结果翻译成人话：
///   · 200 + 有 choices → ✅ 连接成功（顺带显示模型回的第一段字）
///   · 401              → ❌ API Key 不对
///   · 404              → ❌ 路径不对（检查 Base URL 是否含 /v1）
///   · 其它状态码        → ❌ HTTP xxx + 响应片段
///   · 超时/异常         → ❌ 网络不通（检查手机与电脑是否同一 WiFi）
class _TestConnectionButton extends StatefulWidget {
  const _TestConnectionButton({
    required this.h,
    required this.getBaseUrl,
    required this.getApiKey,
    required this.getModel,
  });

  final Hue h;
  final String Function() getBaseUrl;
  final String Function() getApiKey;
  final String Function() getModel;

  @override
  State<_TestConnectionButton> createState() => _TestConnectionButtonState();
}

class _TestConnectionButtonState extends State<_TestConnectionButton> {
  bool _testing = false;
  String? _result;
  bool _ok = false;

  Future<void> _test() async {
    // 输入抓快照 —— async gap 后界面可能变化
    final baseUrl = widget.getBaseUrl();
    final apiKey = widget.getApiKey();
    final model = widget.getModel();
    if (baseUrl.isEmpty || model.isEmpty) {
      setState(() {
        _ok = false;
        _result = '先填 Base URL 和模型名';
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    try {
      // 10 秒超时 —— 手机网络下足够判断通不通，不至于让用户干等 120s
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.postUrl(
          Uri.parse('${baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl}/chat/completions'));
      req.headers.set('Content-Type', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      req.add(utf8.encode(
          '{"model":"$model","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      if (!mounted) return;
      if (resp.statusCode == 200) {
        // 尽力从 choices[0].delta/message 里抠一段回显，证明真的通了
        String echo = '';
        try {
          final j = jsonDecode(body) as Map<String, dynamic>;
          final c = (j['choices'] as List?)?.firstOrNull;
          if (c != null) {
            final cc = c as Map;
            final msg = cc['message'] as Map<String, dynamic>?;
            final delta = cc['delta'] as Map<String, dynamic>?;
            echo = (msg?['content'] ?? delta?['content'] ?? '') as String;
            final r = (msg?['reasoning_content'] ??
                delta?['reasoning_content']) as String?;
            if (echo.isEmpty && r != null) echo = r;
          }
        } catch (_) {}
        setState(() {
          _ok = true;
          _result = echo.isEmpty
              ? '✅ 连接成功（HTTP 200）'
              : '✅ 连接成功，模型回：${echo.trim().substring(0, echo.trim().length.clamp(0, 60))}';
        });
      } else if (resp.statusCode == 401) {
        setState(() {
          _ok = false;
          _result = '❌ API Key 不对（401）';
        });
      } else if (resp.statusCode == 404) {
        setState(() {
          _ok = false;
          _result = '❌ 路径不对（404）—— Base URL 通常要以 /v1 结尾';
        });
      } else {
        setState(() {
          _ok = false;
          _result = '❌ HTTP ${resp.statusCode}：'
              '${body.length > 80 ? body.substring(0, 80) : body}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '❌ 连不上：${e.toString().split('\n').first}';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140, // 热区达标
          child: IosButton(
            label: _testing ? '测试中…' : '测试连接',
            filled: false,
            color: h.accent,
            busy: _testing,
            onPressed: _testing ? null : _test,
          ),
        ),
        if (_result != null) ...[
          const SizedBox(height: HSpace.sm),
          Text(
            _result!,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: _ok ? HColors.successOn(h.dark) : HColors.errorOn(h.dark),
            ),
          ),
        ],
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboard,
    this.obscure = false,
    this.trailing,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboard;
  final bool obscure;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12.5, color: h.textDim),
          ),
          const SizedBox(height: HSpace.sm),
          CupertinoTextField(
            controller: controller,
            keyboardType: keyboard,
            obscureText: obscure,
            style: TextStyle(fontSize: 14, color: h.text),
            placeholder: hint,
            placeholderStyle: TextStyle(color: h.textFaint, fontSize: 14),
            suffix: trailing,
            cursorColor: h.accent,
            padding: const EdgeInsets.symmetric(
              horizontal: HSpace.md,
              vertical: HSpace.md,
            ),
            decoration: BoxDecoration(
              color: h.surface,
              borderRadius: BorderRadius.circular(HRadius.md),
              border: Border.all(color: h.border),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================ 外观

class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text('外观'), leading: _iosBackLeading(context)),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: controller,
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: HSpace.sm),
          children: [
            // ★ 深浅（2026-10-25 晚按概念图 08 定稿）：三张预览卡 ——
            //   卡内是界面骨架缩略图（浅 / 深 / 一半一半），比图标钮
            //   一眼更明白；选中 = 深色描边。
            const _SectionLabel('深浅'),
            _AppearancePreviewRow(
              value: s.appearance,
              onChanged: controller.setAppearance,
            ),
            // ★ 主题选择（2026-10-24，用户拍板）：代替已移除的强调色选择。
            //   只换颜色与背景，不换布局；默认黑白。
            const _SectionLabel('主题'),
            for (final t in AppThemeStyle.values)
              _ThemeCard(
                style: t,
                selected: s.themeStyle == t,
                dark: Hue.of(context).dark,
                onTap: () => controller.setThemeStyle(t),
              ),
            const _SectionLabel('显示'),
            // 显示 + 效果合并一张卡（概念图 08 形态）：三行共用
            // _CardRow、同一左缩进顶格对齐。图标风格是既定设计语言
            // （黑白填充），只报状态不做假开关。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
              child: Container(
                decoration: BoxDecoration(
                  color: Hue.of(context).surfaceAlt,
                  borderRadius: BorderRadius.circular(HRadius.xl),
                ),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    _CardRow(
                      title: '界面字号',
                      value: _fontStopLabel(_nearestFontStop(s.fontSize)),
                      onTap: () => Navigator.of(context).push(
                        CupertinoPageRoute(
                          builder: (_) =>
                              GeneralSettingsPage(controller: controller),
                        ),
                      ),
                    ),
                    Divider(
                        height: 1,
                        indent: 18,
                        endIndent: 18,
                        color: Hue.of(context).border),
                    const _CardRow(title: '图标风格', value: '填充 · 黑白'),
                    Divider(
                        height: 1,
                        indent: 18,
                        endIndent: 18,
                        color: Hue.of(context).border),
                    _CardRow(
                      title: '玻璃效果',
                      subtitle: '面板使用半透明毛玻璃质感',
                      trailing: ElasticSwitch(
                        value: s.glassEffect,
                        onChanged: controller.setGlassEffect,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主题选择卡：名字 + 一句话 + 该主题在当前深浅下的色板预览。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.style,
    required this.selected,
    required this.dark,
    required this.onTap,
  });

  final AppThemeStyle style;
  final bool selected;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final preview = Hue.forTheme(style, dark);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, HSpace.sm),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HSpace.lg, vertical: HSpace.md),
          decoration: BoxDecoration(
            color: h.surface,
            borderRadius: BorderRadius.circular(HRadius.md),
            border: Border.all(
              color: selected ? h.text : h.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              // 色板：底色 / 卡片色 / 强调色
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _dot(preview.bg, preview.border),
                  const SizedBox(width: 4),
                  _dot(preview.surface, preview.border),
                  const SizedBox(width: 4),
                  _dot(preview.accent, preview.border),
                ],
              ),
              const SizedBox(width: HSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      style.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: h.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      style.description,
                      style: TextStyle(fontSize: 12, color: h.textFaint),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(AppIcons.check, size: 19, color: h.text),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color fill, Color ring) => Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(color: ring),
        ),
      );
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('关于'), leading: _iosBackLeading(context)),
      body: Padding(
        padding: const EdgeInsets.all(HSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Heracles',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
                color: h.text,
              ),
            ),
            SizedBox(height: HSpace.xs),
            Text('手机上的开发智能体',
                style: TextStyle(fontSize: 13, color: h.textDim)),
            SizedBox(height: HSpace.xl),
            Text(
              '把 Codex 做成安卓版。\n'
              '接入你自己的云端大模型 API，Key 只存在这台手机上。',
              style: TextStyle(
                  fontSize: 13.5, color: h.textDim, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================ 通用组件

/// 设置主页的平直行（原型 05）：标题左对齐、无图标无副标题，
/// 右侧是值/徽标 + 淡箭头。[onTap] 为 null = 纯信息行（无箭头）。
/// 卡内行（外观页显示卡用，2026-10-25 晚）：标题 + 可选副行 + 右侧
/// 值 / 自定义尾部 / 箭头，左缩进与卡片内边距一致（18）。同一张卡
/// 里的行全部走它 —— 左缘顶格对齐，不再各行各的缩进。
class _CardRow extends StatelessWidget {
  const _CardRow({
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 15, color: h.text)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style:
                            TextStyle(fontSize: 12.5, color: h.textFaint)),
                  ],
                ],
              ),
            ),
            if (value != null)
              Text(value!,
                  style: TextStyle(fontSize: 13.5, color: h.textDim)),
            ?trailing,
            if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(AppIcons.chevronRight, size: 15, color: h.textFaint),
            ],
          ],
        ),
      ),
    );
  }
}

/// 深浅三选预览卡组（概念图 08 定稿形态）：每张卡内是界面骨架
/// 缩略图 + 下方标签，选中 = 深色描边 + 标签粗体。
class _AppearancePreviewRow extends StatelessWidget {
  const _AppearancePreviewRow({required this.value, required this.onChanged});

  final AppAppearance value;
  final void Function(AppAppearance) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, HSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < AppAppearance.values.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: _AppearanceOption(
                option: AppAppearance.values[i],
                selected: AppAppearance.values[i] == value,
                onTap: () => onChanged(AppAppearance.values[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppearanceOption extends StatelessWidget {
  const _AppearanceOption({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AppAppearance option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.xl),
          border: Border.all(
            color: selected ? h.text : h.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 62,
                width: double.infinity,
                child: _previewBox(option),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              option.label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: h.text,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 界面骨架缩略：两条文本线 + 一块主按钮，颜色随深浅选项；
  /// 「跟随系统」= 左右各半 + 中性骨架。
  Widget _previewBox(AppAppearance v) {
    Widget skeleton(Color bar, Color pill) => Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 6,
                decoration: BoxDecoration(
                    color: bar, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(height: 5),
              Container(
                width: 48,
                height: 6,
                decoration: BoxDecoration(
                    color: bar, borderRadius: BorderRadius.circular(3)),
              ),
              const Spacer(),
              Container(
                height: 15,
                decoration: BoxDecoration(
                    color: pill, borderRadius: BorderRadius.circular(7.5)),
              ),
            ],
          ),
        );
    return switch (v) {
      AppAppearance.light => Container(
          color: const Color(0xFFF5F5F4),
          child: skeleton(const Color(0xFFD8D8D5), const Color(0xFF161616)),
        ),
      AppAppearance.dark => Container(
          color: const Color(0xFF161616),
          child: skeleton(const Color(0xFF4A4A4A), const Color(0xFFF5F5F4)),
        ),
      AppAppearance.system => Stack(
          children: [
            const Row(
              children: [
                Expanded(child: ColoredBox(color: Color(0xFFF5F5F4))),
                Expanded(child: ColoredBox(color: Color(0xFF161616))),
              ],
            ),
            skeleton(const Color(0xFFB9B9B6), const Color(0xFF8C8C8C)),
          ],
        ),
    };
  }
}

/// 设置子页的卡片容器（2026-10-25 晚，通用设置改版起）：标题 + 副行
/// 说明 + 可选右上状态 + 卡内控件。与主页 [_HomeCard] 同语言（圆角
/// 20、surfaceAlt 底），区别是主页卡是导航行、这里是内容容器。
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    this.subtitle,
    this.trailing,
    this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, 10),
      child: Container(
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.xl),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: h.text)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(subtitle!,
                            style:
                                TextStyle(fontSize: 13, color: h.textFaint)),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: HSpace.sm),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: trailing!,
                  ),
                ],
              ],
            ),
            if (child != null) ...[
              const SizedBox(height: 13),
              child!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 分段胶囊（离散档位专用，2026-10-25 晚）：一排等分选项，
/// 选中 = 主色底 + 反色粗字。连续量（字号）不要用它，用滑杆。
class _SegControl<T> extends StatelessWidget {
  const _SegControl({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Container(
      decoration: BoxDecoration(
        color: h.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: GestureDetector(
                // 选同一档不回调 —— 不产生无意义的写盘（与模型抽屉同语义）
        onTap: () {
          if (o != value) onChanged(o);
        },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: o == value
                      ? BoxDecoration(
                          color: h.text,
                          borderRadius: BorderRadius.circular(9),
                        )
                      : null,
                  child: Text(
                    labelOf(o),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          o == value ? FontWeight.w600 : FontWeight.w400,
                      color: o == value ? h.bg : h.textDim,
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

/// 卡内警示行（中性款）：灰底 + 橙盾图标 + 正文。取代旧版整块橙色
/// 警告框 —— 黑白语言里只留图标一点橙，其余中性。
class _CardWarnNote extends StatelessWidget {
  const _CardWarnNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Container(
      decoration: BoxDecoration(
        color: h.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(CupertinoIcons.exclamationmark_shield_fill,
              size: 16, color: HColors.warnOn(h.dark)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5, height: 1.55, color: h.textDim)),
          ),
        ],
      ),
    );
  }
}

/// 设置主页的卡片项（2026-10-25 用户参照账户页截图指定）：圆角卡片
/// 包裹，标题在上、状态值作副行（整行省略）、右侧箭头。与子页里
/// 继续使用的平直行 [_HomeRow] 分工：主页用卡片，子页用行。
class _HomeCard extends StatelessWidget {
  const _HomeCard({required this.title, this.subtitle, this.onTap});

  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, 10),
      child: GestureDetector(
        onTap: onTap,
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: h.text),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: h.textFaint),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: HSpace.sm),
                Icon(AppIcons.chevronRight, size: 16, color: h.textFaint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 字号三档（原型 06：小 / 标准 / 大）与产品连续字号的映射。
double _nearestFontStop(double v) {
  const stops = [13.0, 15.0, 18.0];
  return stops.reduce((a, b) => (v - a).abs() <= (v - b).abs() ? a : b);
}

String _fontStopLabel(double v) =>
    v <= 13.0 ? '小' : (v >= 18.0 ? '大' : '标准');

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.lg, HSpace.lg, HSpace.sm),
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
}

/// **「始终允许」白名单**（2026-10-19）—— 展示 + 清除。
///
/// 用户点过「本会话始终允许」的工具会被原生侧**跨 run 记住**，所以必须有个地方
/// 能看到并清掉它；否则用户会疑惑"为什么这次不问我了"。
/// 数据在原生侧（`SharedPreferences("heracles_approvals")`），不进 `AppSettings`。
class _AlwaysAllowedRow extends StatefulWidget {
  const _AlwaysAllowedRow();

  @override
  State<_AlwaysAllowedRow> createState() => _AlwaysAllowedRowState();
}

class _AlwaysAllowedRowState extends State<_AlwaysAllowedRow> {
  List<String>? _tools;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await AgentBridge().alwaysAllowedTools();
    if (!mounted) return;
    setState(() => _tools = list);
  }

  Future<void> _clear() async {
    await AgentBridge().clearAlwaysAllowed();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final tools = _tools;
    // 加载中不显示（一闪而过的"无"比不显示更让人困惑）
    if (tools == null) return const SizedBox.shrink();
    return _SettingsCard(
      title: '已始终允许的工具',
      subtitle: '审批时选过「始终允许」的工具',
      child: Row(
        children: [
          Expanded(
            child: Text(
              tools.isEmpty ? '无' : tools.join('、'),
              style: TextStyle(fontSize: 13.5, color: h.textDim),
            ),
          ),
          if (tools.isNotEmpty)
            CupertinoButton(
              onPressed: _clear,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
              child: const Text('清除', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
