import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/jev.dart';
import '../services/jev_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/elastic_switch.dart';
import '../theme/pressable.dart';
import 'jev_local_settings_screen.dart';

/// **JEV 决策引擎编辑页**（2026-10-27 建，2026-10-28 按用户要求
/// 重排并搬家；2026-10-29 按基元律动接口文档对齐 + 结构再收敛）。
///
/// 位置：设置 →「模型」页里与各提供商并列一张卡，点「编辑」进来，
/// 版式与「编辑提供商」页一致（字段 + 右上「保存」）。
///
/// 内容（用户定）：**云端在前** —— 接口地址 / 密钥 / 模型三字段，
/// 加与提供商编辑页同款的「获取模型」与「测试连接」；其后是
/// 生成理由开关；**本地有关的一切**（本机检测、本地模型下载
/// 管理）收进页面下方的「本地配置」入口页，不再摊在本页。
/// 引擎来源不在这里选 —— 在决策页输入框的来源胶囊抽屉里切换。
class JevSettingsScreen extends StatefulWidget {
  const JevSettingsScreen({super.key, required this.jev});

  final JevController jev;

  @override
  State<JevSettingsScreen> createState() => _JevSettingsScreenState();
}

class _JevSettingsScreenState extends State<JevSettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  bool _keyLoaded = false;
  bool _obscureKey = true;

  // 获取模型（与提供商编辑页同款交互：目录 + 点选回填）
  bool _loadingModels = false;
  String? _modelsError;
  List<String> _modelCatalog = const [];

  // 测试连接（用表单里的当前值发一发最小决策请求）
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  JevController get jev => widget.jev;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = jev.config.cloudBaseUrl;
    _modelCtrl.text = jev.config.cloudModel;
    unawaited(_loadKey());
    if (!jev.loaded) unawaited(jev.load());
  }

  Future<void> _loadKey() async {
    var key = '';
    try {
      key = await JevStore.readCloudKey();
    } catch (_) {
      // 安全存储不可用（测试环境/异常机型）时按未配置处理，不崩页。
      key = '';
    }
    if (!mounted) return;
    _keyCtrl.text = key;
    _keyLoaded = true;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveCloud() async {
    await jev.updateConfig(
      jev.config.copyWith(
        cloudBaseUrl: _urlCtrl.text.trim(),
        cloudModel: _modelCtrl.text.trim(),
      ),
    );
    if (_keyLoaded) await JevStore.writeCloudKey(_keyCtrl.text.trim());
    // 密钥刚落盘 → 刷新控制器的密钥在位状态（模型页卡/顶栏据此显示，
    // refreshCloudKey 内部会通知监听者）
    await jev.refreshCloudKey();
    if (!mounted) return;
    showIosToast(context, '已保存');
  }

  /// 拉取模型目录（GET /v1/models 口径，见 JevCloudClient）——
  /// 用**表单里的当前值**，不用先保存（与提供商编辑页一致）。
  Future<void> _fetchModels() async {
    final baseUrl = _urlCtrl.text.trim();
    final apiKey = _keyCtrl.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _modelsError = '先填接口地址');
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final models = await JevCloudClient.fetchModels(
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
      if (!mounted) return;
      setState(() => _modelCatalog = models);
      showIosToast(context, '找到 ${models.length} 个模型，点一下填入');
    } on JevException catch (e) {
      if (!mounted) return;
      setState(() => _modelsError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelsError = '$e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  /// 测试连接：拿表单当前值发一次最小决策（decide 的是非题），
  /// 通 = 端点、密钥、模型、报文形状全对。结果行内显示，不用
  /// 保存后回决策页试错。
  Future<void> _testConnection() async {
    final baseUrl = _urlCtrl.text.trim();
    final apiKey = _keyCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    if (baseUrl.isEmpty) {
      setState(() {
        _testOk = false;
        _testResult = '先填接口地址';
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final sw = Stopwatch()..start();
    try {
      final r = await JevCloudClient.decide(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        question: '连通性测试：路口信号灯为红色，前方有行人，现在是否应停车？',
      );
      sw.stop();
      if (!mounted) return;
      final recommended = r.yesProb >= 0.5;
      final confidence = (recommended ? r.yesProb : 1 - r.yesProb) * 100;
      setState(() {
        _testOk = true;
        _testResult = '连接成功：决策服务返回「${recommended ? '是' : '否'}」'
            '（置信度 ${confidence.toStringAsFixed(0)}%），'
            '耗时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒';
      });
    } on JevException catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('JEV 决策引擎'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          CupertinoButton(
            onPressed: () => unawaited(_saveCloud()),
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
            foregroundColor: h.accent,
            child: const Text('保存'),
          ),
          const SizedBox(width: HSpace.sm),
        ],
      ),
      body: AnimatedBuilder(
        animation: jev,
        builder: (context, _) {
          final config = jev.config;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              HSpace.lg,
              HSpace.md,
              HSpace.lg,
              HSpace.xl,
            ),
            children: [
              // ★ 顺序（2026-10-29 用户定）：云端在本页（字段 +
              // 获取模型 + 测试连接 + 理由开关），本地的一切收进
              // 下方「本地配置」入口页。引擎来源不在本页 —— 在
              // 决策页输入框左下角的来源胶囊里点按切换。
              Text(
                '引擎来源（云端 / 本地）在决策页输入框左下角点按切换；'
                '这里编辑云端接口，本地模型与本机检测在下方「本地配置」里。',
                style: TextStyle(fontSize: 13, color: h.textFaint, height: 1.5),
              ),
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '云端'),
              _field(
                h,
                '接口地址',
                _urlCtrl,
                hint: '预置基元律动：https://tokenrhythm.studio/v1/decision',
              ),
              const SizedBox(height: HSpace.md),
              _field(
                h,
                'API 密钥',
                _keyCtrl,
                hint: '平台密钥，sk_ 开头',
                obscure: _obscureKey,
                trailing: CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: HSpace.sm),
                  minimumSize: const Size(0, 32),
                  onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  child: Icon(
                    _obscureKey ? CupertinoIcons.eye_slash : AppIcons.eye,
                    size: 19,
                    color: h.textFaint,
                  ),
                ),
              ),
              const SizedBox(height: HSpace.md),
              _field(h, '模型', _modelCtrl, hint: '基元律动固定 NeoHorse-Jev-4B'),
              const SizedBox(height: HSpace.md),
              // ---- 获取模型（与提供商编辑页同款：标签 + 右侧轻量入口）----
              Row(
                children: [
                  Text('模型目录',
                      style: TextStyle(fontSize: 13, color: h.textDim)),
                  const Spacer(),
                  IosTap(
                    onTap: _loadingModels ? null : _fetchModels,
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: HSpace.xs),
                      child: _loadingModels
                          ? CupertinoActivityIndicator(
                              radius: 6, color: h.accent)
                          : Text('获取可用模型',
                              style:
                                  TextStyle(fontSize: 12, color: h.accent)),
                    ),
                  ),
                ],
              ),
              if (_modelsError != null) ...[
                const SizedBox(height: HSpace.xs),
                Text(
                  _modelsError!,
                  style: TextStyle(
                      fontSize: 12, color: HColors.errorOn(h.dark)),
                ),
              ],
              if (_modelCatalog.isNotEmpty) ...[
                const SizedBox(height: HSpace.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(HSpace.md),
                  decoration: BoxDecoration(
                    border: Border.all(color: h.border),
                    borderRadius: BorderRadius.circular(HRadius.sm),
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in _modelCatalog)
                        _catalogChip(h, id),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: HSpace.md),
              // ---- 测试连接（与提供商编辑页同款：描边钮 + 行内结果）----
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: IosButton(
                      label: _testing ? '测试中…' : '测试连接',
                      filled: false,
                      color: h.accent,
                      busy: _testing,
                      onPressed: _testing ? null : _testConnection,
                    ),
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: HSpace.sm),
                    Text(
                      _testResult!,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: _testOk
                            ? HColors.successOn(h.dark)
                            : HColors.errorOn(h.dark),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: HSpace.sm),
              Text(
                '改完点右上角「保存」；获取模型与测试连接用的是框里'
                '当前填的值，不用先保存。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.55),
              ),
              const SizedBox(height: HSpace.lg),
              _card(h, [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '生成理由',
                            style: HTxt.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '决策模型只给结论和概率；开启后由当前对话模型'
                            '补写一两句理由（云端模型自带的思考会优先用）。',
                            style: HTxt.caption.copyWith(
                              color: h.textFaint,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: HSpace.md),
                    ElasticSwitch(
                      value: config.reasonEnabled,
                      onChanged: (v) => unawaited(
                        jev.updateConfig(config.copyWith(reasonEnabled: v)),
                      ),
                    ),
                  ],
                ),
              ]),
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '本地'),
              _localEntry(h),
            ],
          );
        },
      ),
    );
  }

  /// 模型目录里的一个模型 ID —— 点一下填进「模型」框；
  /// 与当前框中值一致的呈选中态（实心）。
  Widget _catalogChip(Hue h, String id) {
    final selected = _modelCtrl.text.trim() == id;
    return Pressable(
      child: GestureDetector(
        onTap: () => setState(() => _modelCtrl.text = id),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? h.text : Colors.transparent,
            border: Border.all(color: selected ? h.text : h.border),
            borderRadius: BorderRadius.circular(HRadius.pill),
          ),
          child: Text(
            id,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: selected ? h.bg : h.text,
            ),
          ),
        ),
      ),
    );
  }

  /// 「本地配置」入口（2026-10-29 用户定）：本机检测与本地模型
  /// 管理都收进独立页，本页只留这一行入口。
  Widget _localEntry(Hue h) {
    final downloaded = kJevModelSpecs
        .where((s) => jev.isDownloaded(s.source))
        .length;
    return Pressable(
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => JevLocalSettingsScreen(jev: jev),
          ),
        ),
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: h.surfaceAlt,
            borderRadius: BorderRadius.circular(HRadius.xl),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.memory, size: 19, color: h.text),
              ),
              const SizedBox(width: HSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '本地配置',
                      style: HTxt.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      downloaded > 0
                          ? '本机检测 · 已下载 $downloaded 个本地模型'
                          : '本机检测 · 本地模型下载与管理',
                      style: HTxt.caption.copyWith(color: h.textFaint),
                    ),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_forward,
                  size: 16, color: h.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  /// 字段 —— 与「编辑提供商」页同一规格：小标签在上、描边圆角
  /// 框、右端可挂操作（如密钥可见切换）。
  Widget _field(
    Hue h,
    String label,
    TextEditingController ctrl, {
    String? hint,
    bool obscure = false,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: h.textDim)),
        const SizedBox(height: HSpace.sm),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: h.border),
            borderRadius: BorderRadius.circular(HRadius.sm),
          ),
          child: Row(
            children: [
              Expanded(
                child: CupertinoTextField.borderless(
                  controller: ctrl,
                  obscureText: obscure,
                  placeholder: hint,
                  placeholderStyle: TextStyle(fontSize: 14, color: h.textFaint),
                  style: TextStyle(fontSize: 14, color: h.text),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HSpace.md,
                    vertical: 12,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ],
    );
  }

  Widget _groupLabel(Hue h, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(text, style: HTxt.sectionTitle.copyWith(color: h.textDim)),
    );
  }

  Widget _card(Hue h, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
