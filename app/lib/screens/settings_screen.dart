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
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: HSpace.sm),
          children: [
            _SettingsTile(
              icon: CupertinoIcons.slider_horizontal_3,
              title: '通用设置',
              subtitle: '权限 · 语言 · 外观 · 字号',
              onTap: () => _push(context, GeneralSettingsPage(controller: controller)),
            ),
            _SettingsTile(
              icon: CupertinoIcons.cube_box,
              title: '模型',
              // ★★ 与聊天页保持一致（2026-10-15 修 BUG-5）★★
              //
              // ## 修的是什么
              //
              // 用户实测：聊天页胶囊显示 `kimi-k2.6`，设置页这里却显示 `qwen`
              // —— 同一件事两个说法，用户会困惑"到底在用哪个"。
              //
              // ## 根因（两个错叠加）
              //
              // ① 用 `defaultProvider` 而聊天页用 `effectiveProvider`
              //    —— **连 provider 都可能不是同一个**
              // ② 显示 `provider.name`（`qwen`）而不是 `provider.model`
              //    （`kimi-k2.6`）
              //
              // ## 修法：与聊天页同源同字段
              //
              // 用 `effectiveProvider`（用户实际在用的那个）+ 显示
              // `provider名 · 模型名`（两者都有信息量：前者说"走的哪家"，
              // 后者说"用的哪个模型"）。
              subtitle: s.effectiveProvider == null
                  ? '未选择'
                  : (s.effectiveProvider!.model.isEmpty
                      ? s.effectiveProvider!.name
                      : '${s.effectiveProvider!.name} · ${s.effectiveProvider!.model}'),
              onTap: () => _push(context, ModelSettingsPage(controller: controller)),
            ),
            _SettingsTile(
              icon: CupertinoIcons.paintbrush,
              title: 'Theme / 外观',
              subtitle: '强调色 · 玻璃效果',
              onTap: () => _push(context, AppearanceSettingsPage(controller: controller)),
            ),
            // ★ 设备权限（2026-10-16）—— **二级页面**
            //   （用户反馈：不要平铺在设置主页，与「模型」一样二级进入）
            _DevicePermissionEntry(
              onOpen: () => _push(context, const DevicePermissionPage()),
            ),
            // ★ 全局记忆（2026-10-23）—— **二级页面**：看全文 + 看规模 + 能清空
            //   记忆是跨会话的，用户必须能看见"App 到底记住了多少"。
            _GlobalMemoryEntry(
              onOpen: () => _push(context, const GlobalMemoryPage()),
            ),
            const SizedBox(height: HSpace.lg),
            Divider(),
            const SizedBox(height: HSpace.lg),
            _SettingsTile(
              icon: AppIcons.info,
              title: '关于',
              subtitle: 'Heracles · 手机上的开发智能体',
              onTap: () => _push(context, const AboutPage()),
            ),
          ],
        ),
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final st = await AgentBridge().devicePermission();
    if (!mounted) return;
    setState(() => _granted = st.writeSecureSettings);
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsTile(
      icon: CupertinoIcons.phone,
      title: '设备权限',
      // 状态徽章在副标题位 —— 用户不进二级页也能看到授权状态
      subtitle: _granted == null
          ? '…'
          : (_granted!
              ? '已授权 · 无障碍自愈可用'
              : '未授权 · 无障碍自愈不可用'),
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

  /// Shizuku 授权结果（✅/❌ + 可读信息）
  String? _shizukuMsg;
  bool _loading = true;

  /// 执行路由诊断（ping / granted / sui）——
  /// 解释「命令执行成功但 Shizuku 显示 0 个已授权应用」
  Map<String, dynamic> _diag = const {};

  /// **编码层自检**进行中（2026-10-17）—— 构建要 1–3 分钟，按钮要能锁住
  bool _selfCheckBusy = false;

  /// 自检报告（逐行：前台服务/shell 路由/工具链/工作区/构建/产物核对）
  String? _selfCheckMsg;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final st = await AgentBridge().devicePermission();
    if (!mounted) return;
    setState(() {
      _granted = st.writeSecureSettings;
      _guidance = st.guidance;
      _diag = st.shizuku;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设备权限'), leading: _iosBackLeading(context)),
      body: _loading
          ? Center(
              child: CupertinoActivityIndicator(color: h.accent))
          : ListView(
              padding: const EdgeInsets.all(HSpace.lg),
              children: [
                // ---- 状态卡 ----
                Container(
                  padding: const EdgeInsets.all(HSpace.lg),
                  decoration: BoxDecoration(
                    color: h.surface,
                    borderRadius: BorderRadius.circular(HRadius.lg),
                    border: Border.all(
                      color: _granted == true
                          ? HColors.successOn(h.dark)
                          : HColors.warnOn(h.dark),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _granted == true
                            ? CupertinoIcons.checkmark_circle_fill
                            : AppIcons.warning,
                        size: 29,
                        color: _granted == true
                            ? HColors.successOn(h.dark)
                            : HColors.warnOn(h.dark),
                      ),
                      const SizedBox(width: HSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _granted == true ? '已授权' : '未授权',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: h.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _granted == true
                                  ? '无障碍自愈可用（WRITE_SECURE_SETTINGS）'
                                  : '无障碍自愈不可用',
                              style: TextStyle(
                                  fontSize: 12, color: h.textDim),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: HSpace.lg),
                // ---- 引导 ----
                if (_granted == false && _guidance.isNotEmpty) ...[
                  Text(
                    '三种授权方式任选其一：',
                    style: TextStyle(fontSize: 13, color: h.textDim),
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
                  // ★ 一键 Shizuku 授权（2026-10-16 用户反馈完善）——
                  //
                  // 用户实测：「我在 shizuku 上面都找不到本 app 来授权」——
                  // 因为 App 没集成 Shizuku SDK。现在集成了：点这个按钮 →
                  // Shizuku 弹授权框 → 同意后自动执行 pm grant。
                  //
                  // 结果在按钮下方显示（成功/失败 + 服务器返回的可读信息）。
                  SizedBox(
                    width: double.infinity,
                    child: IosButton(
                      label: '通过 Shizuku 一键授权',
                      color: h.accent,
                      // ★ 忙态转圈（2026-10-22 补）：iOS 按钮忙态 = 文字换转圈
                      busy: _shizukuBusy,
                      onPressed: _shizukuBusy
                          ? null
                          : () async {
                              setState(() => _shizukuBusy = true);
                              final r = await AgentBridge().shizukuGrant();
                              if (!mounted) return;
                              setState(() => _shizukuMsg =
                                  '${r.success ? "✅" : "❌"} ${r.message}');
                              await _refresh();
                              if (!mounted) return;
                              setState(() => _shizukuBusy = false);
                            },
                    ),
                  ),
                  if (_shizukuMsg != null) ...[
                    const SizedBox(height: HSpace.xs),
                    Text(
                      _shizukuMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: _shizukuMsg!.startsWith('✅')
                            ? HColors.successOn(h.dark)
                            : HColors.errorOn(h.dark),
                      ),
                    ),
                  ],
                  const SizedBox(height: HSpace.md),
                  SizedBox(
                    width: double.infinity,
                    child: IosButton(
                      label: '我已执行授权，刷新状态',
                      filled: false,
                      color: h.accent,
                      onPressed: _refresh,
                    ),
                  ),
                  const SizedBox(height: HSpace.md),
                ] else if (_granted == true) ...[
                  Text(
                    '一切正常 —— 无障碍被系统关闭时会自动恢复，无需干预。',
                    style: TextStyle(fontSize: 13, color: h.textDim),
                  ),
                  const SizedBox(height: HSpace.md),
                  // ★ 强制重新申请（2026-10-16）——
                  //   用户问「Shizuku 那边怎么还是已授权 0 个应用？」：
                  //   诊断证明 Shizuku **服务端已授权本 App**，但它的 UI 列表空
                  //   —— 因为本 App 的授权是遗留记录（2026-10-12 装过），
                  //   **没走过 Shizuku 的申请弹窗**，而列表只收录"走过流程"的应用。
                  //
                  //   这个按钮无条件触发一次 Shizuku 弹窗 → 同意后它的
                  //   「已授权应用」里就会收录本 App。
                  SizedBox(
                    width: double.infinity,
                    child: IosButton(
                      label: '重新向 Shizuku 申请授权（让它收录本 App）',
                      filled: false,
                      color: h.accent,
                      dense: true,
                      busy: _shizukuBusy,
                      onPressed: _shizukuBusy
                          ? null
                          : () async {
                              setState(() => _shizukuBusy = true);
                              final r = await AgentBridge()
                                  .shizukuForceRequest();
                              if (!mounted) return;
                              setState(() => _shizukuMsg =
                                  '${r.success ? "✅" : "❌"} ${r.message}');
                              await _refresh();
                              if (!mounted) return;
                              setState(() => _shizukuBusy = false);
                            },
                    ),
                  ),
                  if (_shizukuMsg != null) ...[
                    const SizedBox(height: HSpace.xs),
                    Text(
                      _shizukuMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: _shizukuMsg!.startsWith('✅')
                            ? HColors.successOn(h.dark)
                            : HColors.errorOn(h.dark),
                      ),
                    ),
                  ],
                ],
                // ---- ★ 执行路由诊断（2026-10-16）----
                //
                // 用户问「Shizuku 那边怎么还是已授权 0 个应用？」——
                // 本机同时装了 Stellar（Sui 系管理器），而 Shizuku-API
                // **内置 Sui 支持**：Sui 可用时 API 调用走 Sui，Shizuku
                // 的授权列表自然是 0（因为根本没经它）。
                //
                // 这里如实显示实际路由，让用户看到真相而不是猜。
                if (_diag.isNotEmpty) ...[
                  const SizedBox(height: HSpace.lg),
                  Text(
                    '执行路由诊断',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: h.text),
                  ),
                  const SizedBox(height: HSpace.xs),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(HSpace.md),
                    decoration: BoxDecoration(
                      color: h.surfaceAlt,
                      borderRadius: BorderRadius.circular(HRadius.md),
                      border: Border.all(color: h.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ★ 统一结论：实际走的是谁（Stellar 优先 → Shizuku）
                        Row(
                          children: [
                            Text('当前执行路由：',
                                style: TextStyle(fontSize: 12.5, color: h.textDim)),
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
                        // ---- Stellar（能力更强，优先）----
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
                        // ---- Shizuku ----
                        _diagRow(h, 'Shizuku 已安装', _diag['shizukuInstalled']),
                        _diagRow(h, 'Shizuku binder 连通', _diag['shizukuPing']),
                        _diagRow(h, 'Shizuku 已授权本 App', _diag['shizukuGranted']),
                        _diagRow(h, 'Shizuku 版本过旧(pre-v11)', _diag['shizukuPreV11']),
                        const SizedBox(height: HSpace.sm),
                        Text(_diagConclusion(), style: TextStyle(
                            fontSize: 12, height: 1.5, color: h.textDim)),
                      ],
                    ),
                  ),
                ],
                // ---- ★ 编码层自检（2026-10-17）----
                //
                // 为什么放在「设备权限」页：自检能不能跑通**直接取决于上面那个执行路由**
                // （App 自己没有 shell 身份，aapt2/javac/d8 全靠它跑）。
                // 而 `DeviceShellRunner` / `AgentBuildService` / `SystemHealthSource`
                // 此前只有「编译过、APK 装得上」—— 这里给它们一个**能真跑的答案**。
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
                  style: TextStyle(fontSize: 12, height: 1.5, color: h.textDim),
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
      return '本机通过 **Stellar** 提供 shell 能力'
          '${_diag['stellarRoot'] == true ? "（Root 模式，能力最强）" : "（ADB/Shell 模式）"}。'
          '授权请到 Stellar 的「授权应用」里查看。';
    }
    if (route == 'Shizuku') {
      return '本机通过 **Shizuku** 提供 shell 能力。'
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

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return CupertinoListTile(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: HSpace.lg,
        vertical: HSpace.md + 2,
      ),
      leadingSize: 20,
      leadingToTitle: HSpace.md + 2,
      // iOS 的按下态：整行浅底（跟随应用配色，不用 Cupertino 的系统灰）
      backgroundColor: CupertinoColors.transparent,
      backgroundColorActivated: h.surfaceAlt,
      leading: Icon(icon, size: 20, color: h.textDim),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w500,
          color: h.text,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: h.textFaint,
        ),
      ),
      trailing: Icon(AppIcons.chevronRight,
          size: 19, color: h.textFaint),
    );
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
        : (r.isEmpty
            ? '暂无记忆'
            : '${_entryCount(r.text)} 条 · ${_fmtBytes(r.bytes)}'));
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsTile(
      icon: AppIcons.think,
      title: '全局记忆',
      // 规模徽章在副标题位 —— 不进二级页也知道记了多少
      subtitle: _badge ?? '…',
      onTap: () async {
        await widget.onOpen();
        // 从二级页返回后再读一次（用户可能刚点了清空）—— 这次是真等 pop
        await _reload();
      },
    );
  }
}

/// **全局记忆二级页**（2026-10-23）—— 全文查看 + 清空。
///
/// 记忆存在 App 全局（不在工作区），每轮系统提示都会把它带回去；
/// 这一页只管两件事：**看得见**、**能清掉**。
class GlobalMemoryPage extends StatefulWidget {
  const GlobalMemoryPage({super.key});

  @override
  State<GlobalMemoryPage> createState() => _GlobalMemoryPageState();
}

class _GlobalMemoryPageState extends State<GlobalMemoryPage> {
  final _memory = const GlobalMemory();

  /// null = 读取中（转圈）
  MemoryReadResult? _result;

  /// 清空进行中 —— 右上角动作锁住并转圈，避免连点二次触发
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await _memory.readResult();
    if (!mounted) return;
    setState(() => _result = result);
  }

  /// 清空**不可逆** —— 先弹 iOS 确认框，破坏性动作用红色（iOS 的规矩）。
  Future<void> _confirmClear() async {
    await showIosDialog(
      context,
      title: '清空全局记忆？',
      message: '所有跨会话记忆都会被删除，无法恢复。'
          '之后的新会话不再带着这些内容开始。',
      actions: [
        const IosAction('取消'),
        IosAction('清空记忆',
            isDestructiveAction: true, onTap: _doClear),
      ],
    );
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

  /// 「12 条 · 3.4 KB / 256 KB」—— 规模与上限一行说清（接近上限就提醒）。
  String _sizeLine(MemoryReadResult r) {
    final cap = _fmtBytes(GlobalMemory.maxBytes);
    if (r.isEmpty) return '暂无记忆 · 上限 $cap';
    final line = '${_entryCount(r.text)} 条 · ${_fmtBytes(r.bytes)} / $cap';
    return r.nearlyFull ? '$line · 接近上限，建议清空' : line;
  }

  TextStyle _mono(Hue h, Color color, {double size = 12}) => TextStyle(
        fontSize: size,
        fontFamily: kMonoFontFamily,
        fontFamilyFallback: kMonoFallback,
        color: color,
      );

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final r = _result;
    // 读不出来时连"有没有东西可清"都不知道 —— 那时只给「重试」
    final canClear = r != null && r.error == null && !r.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('全局记忆'),
        leading: _iosBackLeading(context),
        actions: [
          // 没有记忆就没有可清的东西 —— 动作干脆不出现（iOS 的做法）
          if (canClear)
            CupertinoButton(
              onPressed: _clearing ? null : _confirmClear,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
              foregroundColor: HColors.errorOn(h.dark),
              child: _clearing
                  ? CupertinoActivityIndicator(
                      radius: 8, color: HColors.errorOn(h.dark))
                  : const Text('清空', style: TextStyle(fontSize: 15)),
            ),
          const SizedBox(width: HSpace.sm),
        ],
      ),
      body: r == null
          ? Center(child: CupertinoActivityIndicator(color: h.accent))
          : ListView(
              padding: const EdgeInsets.all(HSpace.lg),
              children: [
                // ---- 读不出来 ≠ 没有记忆：这两种情况必须说不同的话 ----
                if (r.error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(HSpace.md),
                    decoration: BoxDecoration(
                      color: HColors.errorOn(h.dark).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(HRadius.md),
                      border: Border.all(
                        color: HColors.errorOn(h.dark).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '读不出记忆：${r.error}',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: HColors.errorOn(h.dark),
                      ),
                    ),
                  ),
                  const SizedBox(height: HSpace.md),
                  IosButton(
                    label: '重试',
                    filled: false,
                    color: h.accent,
                    dense: true,
                    onPressed: _load,
                  ),
                ] else ...[
                  // ---- 规模与上限 ----
                  Text(
                    _sizeLine(r),
                    style: _mono(
                        h, r.nearlyFull ? HColors.warnOn(h.dark) : h.textDim),
                  ),
                  const SizedBox(height: HSpace.sm),
                  // ---- 全文 / 空态 ----
                  if (r.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(HSpace.md),
                      decoration: BoxDecoration(
                        color: h.surfaceAlt,
                        borderRadius: BorderRadius.circular(HRadius.md),
                        border: Border.all(color: h.border),
                      ),
                      child: Text(
                        '还没有任何记忆。和 Heracles 聊天时它会把值得记住的事'
                        '写在这里（跨会话生效）。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: h.textFaint,
                        ),
                      ),
                    )
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(HSpace.md),
                      decoration: BoxDecoration(
                        color: h.surfaceAlt,
                        borderRadius: BorderRadius.circular(HRadius.md),
                        border: Border.all(color: h.border),
                      ),
                      child: SelectableText(
                        r.text,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          fontFamily: kMonoFontFamily,
                          fontFamilyFallback: kMonoFallback,
                          color: h.text,
                        ),
                      ),
                    ),
                  const SizedBox(height: HSpace.md),
                  // 滚到底时再报一次规模，不用翻回顶部
                  Text(_sizeLine(r), style: _mono(h, h.textFaint)),
                ],
              ],
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
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: HSpace.sm),
          children: [
            // ---- 权限（★ 真实功能：拦截危险操作）----
            const _SectionLabel('权限'),
            _PickerRow<PermissionMode>(
              label: '新会话的默认权限',
              hint: '决定工具执行前是否需要你确认',
              value: s.permission,
              options: PermissionMode.values,
              labelOf: (v) => v.label,
              descOf: (v) => v.description,
              onChanged: controller.setPermission,
            ),
            if (s.permission.requiresElevation)
              const _WarningNote(
                '⚠️ 「完全访问」需要 Shizuku 或 root 才能真正生效。',
              ),
            // ★ 「始终允许」白名单（2026-10-19）：用户点过「本会话始终允许」的工具会
            //   **跨 run 记住**（存在原生侧），所以必须有个地方能看到并清掉它 ——
            //   否则用户会疑惑"为什么这次不问我了"。
            const _AlwaysAllowedRow(),
            Divider(),

            // ---- 语言 ----
            const _SectionLabel('语言'),
            _PickerRow<AppLanguage>(
              label: '界面语言',
              value: s.language,
              options: AppLanguage.values,
              labelOf: (v) => v.label,
              onChanged: controller.setLanguage,
            ),
            Divider(),

            // ---- 外观 ----
            const _SectionLabel('外观'),
            _SegmentedRow<AppAppearance>(
              value: s.appearance,
              options: AppAppearance.values,
              labelOf: (v) => v.label,
              iconOf: (v) => switch (v) {
                AppAppearance.light => CupertinoIcons.sun_max_fill,
                AppAppearance.dark => CupertinoIcons.moon_fill,
                AppAppearance.system => CupertinoIcons.brightness,
              },
              onChanged: controller.setAppearance,
            ),

            // ---- 字号（★ 真实功能：改变全局字号）----
            _SliderRow(
              label: '字号大小',
              hint: '影响会话内容的字号',
              value: s.fontSize,
              min: 12,
              max: 20,
              divisions: 8,
              suffix: 'px',
              onChanged: controller.setFontSize,
            ),
            Divider(),

            // ---- 工作步骤展示（★ 真实功能：过滤工具卡片细节）----
            const _SectionLabel('会话'),
            _PickerRow<StepDetail>(
              label: '工作步骤展示',
              hint: '选择希望看到多少工具调用细节',
              value: s.stepDetail,
              options: StepDetail.values,
              labelOf: (v) => v.label,
              descOf: (v) => v.description,
              onChanged: controller.setStepDetail,
            ),
            // ⚠️ 2026-10-19：「显示代码工作视图」开关已删 —— 它没有任何消费方
            //   （渲染层从未读过这个值），是个"拨了没反应"的假开关。
            _PickerRow<BusySendBehavior>(
              label: '繁忙时的发送行为',
              hint: '智能体运行时按发送键的行为',
              value: s.busySend,
              options: BusySendBehavior.values,
              labelOf: (v) => v.label,
              descOf: (v) => v.description,
              onChanged: controller.setBusySend,
            ),
          ],
        ),
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
      await showIosDialog(
        context,
        title: '删除这个提供商？',
        message: '「${provider.name.isEmpty ? "(未命名)" : provider.name}」的配置'
            '与已保存的 API Key 都会被清除，无法恢复。',
        actions: [
          const IosAction('取消'),
          IosAction('删除',
              isDestructiveAction: true, onTap: onDelete),
        ],
      );
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
                // N5：档位只在 OpenAI 兼容轨真生效
                reasoningLevelsEffective:
                    _protocol == ProviderProtocol.openaiChat,
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
    final h = Hue.of(context);
    return Scaffold(
      appBar:
          AppBar(title: Text('Theme / 外观'), leading: _iosBackLeading(context)),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: controller,
        builder: (context, s, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: HSpace.sm),
          children: [
            const _SectionLabel('强调色'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
              child: Wrap(
                spacing: HSpace.md,
                runSpacing: HSpace.md,
                children: kAccentPresets.map((p) {
                  final selected = p.hex == s.accentHex;
                  return GestureDetector(
                    onTap: () => controller.setAccentHex(p.hex),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(p.hex),
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: h.text, width: 2.5)
                            : null,
                      ),
                      child: selected
                          ? const Icon(AppIcons.check,
                              size: 19, color: CupertinoColors.white)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: HSpace.xl),
            Divider(),
            const _SectionLabel('效果'),
            _SwitchRow(
              label: '玻璃效果',
              hint: '面板使用半透明毛玻璃质感',
              value: s.glassEffect,
              onChanged: controller.setGlassEffect,
            ),
          ],
        ),
      ),
    );
  }
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

/// 下拉选择行（权限 / 工作步骤 / 繁忙行为都用它）
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.hint,
    this.descOf,
  });

  final String label;
  final String? hint;
  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final String Function(T)? descOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.sm, HSpace.lg, HSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 14, color: h.text),
                ),
                if (hint != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    hint!,
                    style: TextStyle(fontSize: 11.5, color: h.textFaint),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: HSpace.md),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 34),
            onPressed: () => _pick(context),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: HSpace.md, vertical: HSpace.sm),
              decoration: BoxDecoration(
                color: h.surface,
                borderRadius: BorderRadius.circular(HRadius.md),
                border: Border.all(color: h.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(labelOf(value),
                      style: TextStyle(fontSize: 13, color: h.text)),
                  const SizedBox(width: HSpace.xs),
                  Icon(AppIcons.chevronDown,
                      size: 17, color: h.textFaint),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// iOS 动作面板（替换 Material 的 `PopupMenuButton`）—— 选中逻辑逐条不变。
  Future<void> _pick(BuildContext context) async {
    final h = Hue.of(context);
    final picked = await showCupertinoModalPopup<T>(
      context: context,
      builder: (sheetCtx) => CupertinoActionSheet(
        title: Text(label),
        actions: [
          for (final o in options)
            CupertinoActionSheetAction(
              isDefaultAction: o == value,
              onPressed: () => Navigator.of(sheetCtx).pop(o),
              child: _optionOf(o, h),
            ),
        ],
      ),
    );
    if (picked != null) onChanged(picked);
  }

  /// 选项内容：名称（+ 可选说明），对应旧的 `PopupMenuItem`。
  Widget _optionOf(T o, Hue h) {
    final desc = descOf?.call(o);
    if (desc == null || desc.isEmpty) return Text(labelOf(o));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(labelOf(o)),
        const SizedBox(height: 2),
        Text(
          desc,
          style: TextStyle(fontSize: 11, color: h.textFaint, height: 1.3),
        ),
      ],
    );
  }
}

/// 三段式选择（外观）
class _SegmentedRow<T> extends StatelessWidget {
  const _SegmentedRow({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.iconOf,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final IconData Function(T) iconOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HSpace.lg),
      child: Row(
        children: options.map((o) {
          final selected = o == value;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: HSpace.sm),
              child: GestureDetector(
                onTap: () => onChanged(o),
                child: Container(
                  height: 72,
                  decoration: BoxDecoration(
                    color: selected
                        ? h.accent.withValues(alpha: 0.10)
                        : h.surface,
                    borderRadius: BorderRadius.circular(HRadius.md),
                    border: Border.all(
                      color: selected ? h.accent : h.border,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(iconOf(o),
                          size: 21,
                          color: selected ? h.accent : h.textDim),
                      const SizedBox(height: HSpace.xs + 2),
                      Text(
                        labelOf(o),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          color: selected ? h.accent : h.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// 滑块行（字号）
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.hint,
    this.divisions,
    this.suffix,
  });

  final String label;
  final String? hint;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? suffix;
  final void Function(double) onChanged;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.sm, HSpace.lg, HSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(fontSize: 14, color: h.text)),
                    if (hint != null) ...[
                      const SizedBox(height: 2),
                      Text(hint!,
                          style: TextStyle(
                              fontSize: 11.5, color: h.textFaint)),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: HSpace.md, vertical: HSpace.xs + 2),
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(HRadius.md),
                  border: Border.all(color: h.border),
                ),
                child: Text(
                  '${value.round()}${suffix ?? ''}',
                  style: TextStyle(fontSize: 13, color: h.text),
                ),
              ),
            ],
          ),
          CupertinoSlider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: h.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// 开关行
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String? hint;
  final bool value;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.sm, HSpace.lg, HSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(fontSize: 14, color: h.text)),
                if (hint != null) ...[
                  const SizedBox(height: 3),
                  Text(hint!,
                      style: TextStyle(
                          fontSize: 11.5, color: h.textFaint, height: 1.35)),
                ],
              ],
            ),
          ),
          const SizedBox(width: HSpace.md),
          CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: h.accent,
            // 关闭态轨道跟随应用配色（Cupertino 的系统灰按平台亮度解析）
            inactiveTrackColor: h.border,
            thumbColor: CupertinoColors.white,
          ),
        ],
      ),
    );
  }
}

class _WarningNote extends StatelessWidget {
  const _WarningNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, HSpace.sm),
        child: Container(
          padding: const EdgeInsets.all(HSpace.md),
          decoration: BoxDecoration(
            color: HColors.warnOn(h.dark).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(HRadius.md),
            border: Border.all(color: HColors.warnOn(h.dark).withValues(alpha: 0.3)),
          ),
          child: Text(
            text,
            style: TextStyle(
                fontSize: 11.5, color: HColors.warnOn(h.dark), height: 1.5),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.lg, 0, HSpace.lg, HSpace.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('已始终允许的工具',
                    style: TextStyle(fontSize: 13, color: h.text)),
                const SizedBox(height: 2),
                Text(
                  tools.isEmpty ? '无' : tools.join('、'),
                  style: TextStyle(fontSize: 11.5, color: h.textDim),
                ),
              ],
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
