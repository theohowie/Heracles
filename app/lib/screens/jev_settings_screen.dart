import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/jev.dart';
import '../services/jev_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/pressable.dart';
import 'jev_local_settings_screen.dart';

// ---------------------------------------------------------------------------
// 决策请求诊断展示（消费后端 B8 的 JevDiagnostics / JevDecisionResult）
//
// 页面**只消费** B8 的诊断对象：不自己发 HTTP、不伪造成功、不吞 422。
// 「测试连接 / 获取可用模型」各留一个 UI 侧注入点（probe）：生产一律
// 不传（走 JevCloudClient，真实诊断上屏）；测试用 mock 诊断对象覆盖
// 422（有/无 body）/401/403/413/429 等分支。
// ---------------------------------------------------------------------------

/// 「测试连接」注入点：生产为 null（UI 调 `JevCloudClient.decide`，
/// 自己**不发 HTTP**）；测试用 mock 抛 [JevException]（带诊断）或
/// 返回 [JevDecisionResult]。
typedef JevDecideProbe = Future<JevDecisionResult> Function({
  required String baseUrl,
  required String apiKey,
  required String model,
  required String question,
});

/// 「获取可用模型」注入点（生产为 null，走 `JevCloudClient.fetchModels`）。
typedef JevModelsProbe = Future<List<String>> Function({
  required String baseUrl,
  required String apiKey,
});

/// 结果区的一份快照：B8 诊断对象 + 成功结果 / 失败人话。
///
/// 请求根本没发出去（地址/密钥空等本地前置错误）时 [diagnostics] 为
/// null —— 此时**不编造** HTTP 码与 traceId，只展示人话原因。
class JevTestReport {
  const JevTestReport({
    required this.endpoint,
    this.diagnostics,
    this.result,
    this.failureMessage,
  });

  /// 本次实际请求的端点（`JevCloudClient.resolveEndpoint` 的结论；
  /// 有诊断时以诊断里的脱敏 URL 为准）。
  final String endpoint;

  /// B8 诊断对象（连不上/本地前置错误时为 null）。
  final JevDiagnostics? diagnostics;

  /// 成功时的决策结果。
  final JevDecisionResult? result;

  /// 失败人话原因（成功为 null）。
  final String? failureMessage;

  /// 判定成功只看诊断的 2xx —— 失败/超时**绝不**画成成功。
  bool get ok => diagnostics?.ok ?? false;
}

/// 422 / 平台 hint 的排障分类 —— 用户要求**分三类文案**：
/// 参数形状 / 上游限制 / 模型权限；401/403/404 另按鉴权与端点单列。
enum JevHintKind {
  none,
  paramShape,
  upstreamLimit,
  modelPermission,
  auth,
  endpoint,
}

/// 分类依据 = HTTP 码 + 平台错误体（code / message）关键词。
///
/// B8 的 [JevDiagnostics.hint] 是**多条拼接**（422 时会同时提到
/// 参数/上游/模型权限），所以不用它做分类，只当「平台原话」整段展示。
JevHintKind jevHintKindOf(JevDiagnostics d) {
  final status = d.httpStatus;
  if (status == null) return JevHintKind.none; // 传输层错误：没有 HTTP 码
  if (status >= 200 && status < 300) return JevHintKind.none;
  if (status == 401) return JevHintKind.auth;
  if (status == 403) return JevHintKind.modelPermission;
  if (status == 404) return JevHintKind.endpoint;
  if (status == 413 || status == 429) return JevHintKind.upstreamLimit;
  if (status != 422) return JevHintKind.none;
  final text = '${d.serverCode ?? ''} ${d.serverMessage ?? ''}'.toLowerCase();
  bool hasAny(List<String> words) => words.any(text.contains);
  // 先看**强信号**：上游限制（超时/限流/体积…）比裸「模型」二字具体 ——
  // 平台 422 的人话常是「上游模型超时」，不能被其中的「模型」抢走分类。
  if (hasAny(const [
    '上游',
    'upstream',
    '限流',
    'rate limit',
    '频率',
    '超时',
    'timeout',
    '过载',
    '容量',
    'too large',
    'payload',
    '1mib',
  ])) {
    return JevHintKind.upstreamLimit;
  }
  // 模型权限只认「权限」类强信号（不认裸「模型」/「model」）。
  if (hasAny(const [
    '权限',
    'permission',
    '授权',
    'unauthorized',
    'not authorized',
    'forbidden',
    'access denied',
    '灰度',
  ])) {
    return JevHintKind.modelPermission;
  }
  if (hasAny(const [
    '参数',
    '形状',
    '报文',
    'schema',
    'format',
    'invalid',
    '字段',
    'questions',
    'state',
    '类型',
  ])) {
    return JevHintKind.paramShape;
  }
  // 平台文档：422 一般是参数形状 / 上游限制；没有更具体证据时按参数形状。
  return JevHintKind.paramShape;
}

/// 分类文案（每类都写清下一步查什么；失败绝不画成成功）。
String jevHintCopy(JevHintKind kind) => switch (kind) {
  JevHintKind.paramShape =>
    '参数形状不对：请求体要按文档用 state + questions 形状（应用已按文档'
        '发送），题数 1–16 道、请求体 ≤1MiB。仍反复出现时把 traceId 与'
        '原始响应体一并报给平台。',
  JevHintKind.upstreamLimit =>
    '上游限制：平台侧限流、容量或请求体积超限 —— 稍后重试或缩短输入；'
        '反复出现时带 traceId 找平台。',
  JevHintKind.modelPermission =>
    '模型权限：账号可能没有 $kJevDefaultModel 的调用权限（「获取可用模型」'
        '的目录里查不到它时尤其可能）。',
  JevHintKind.auth =>
    '鉴权失败：密钥无效、过期或没填 —— 检查 API 密钥（sk_ 开头）。'
        '平台先验鉴权再验参数，所以密钥不对时看不到 422（无 Key 三发全 401）。',
  JevHintKind.endpoint =>
    '端点不对（404）：推荐 https://tokenrhythm.studio/v1/decision，'
        '或填到 https://tokenrhythm.studio/v1 让应用自动补 /decision。',
  JevHintKind.none => '',
};

/// 422 的三类常见原因 —— 三类都要列出来，避免把 422 说成单一原因
/// （平台文档：422 = 参数形状 / 上游限制；无 Key 时鉴权先于校验 ⇒ 401）。
const String kJev422Categories =
    '422 三类常见原因：① 参数形状（state + questions 报文形状）'
    ' ② 上游限制（题数 >16 / 请求体 >1MiB / 上游过载、限流）'
    ' ③ 模型权限（账号没有 $kJevDefaultModel 的权限）';

/// 结果区默认那一行结论（成功/失败都只一行，技术细节收进「详情」）。
String jevOutcomeHeadline(JevTestReport r) {
  if (r.ok && r.result != null) {
    final res = r.result!;
    final pct = (res.confidence * 100).toStringAsFixed(0);
    final sec = (res.diagnostics.elapsedMs / 1000).toStringAsFixed(1);
    return '连接成功：决策服务返回「${res.recommended ? '是' : '否'}」，'
        '置信度 $pct% · 耗时 $sec 秒';
  }
  final d = r.diagnostics;
  final status = d?.httpStatus;
  final kind = d == null ? JevHintKind.none : jevHintKindOf(d);
  final label = switch (kind) {
    JevHintKind.paramShape => '参数形状不符合平台要求',
    JevHintKind.upstreamLimit => '上游限制',
    JevHintKind.modelPermission => '模型权限不足',
    JevHintKind.auth => '密钥无效或未授权',
    JevHintKind.endpoint => '接口地址不对',
    JevHintKind.none => '',
  };
  final reason = r.failureMessage?.trim() ?? '';
  if (status == null) {
    if (label.isNotEmpty) return '连接失败：$label';
    return reason.isEmpty ? '连接失败' : '连接失败：$reason';
  }
  final head = '连接失败（HTTP $status）';
  return label.isEmpty ? head : '$head：$label';
}

/// 详情面板的固定行（请求 URL / HTTP 码 / 耗时 / code / message /
/// traceId）。traceId 缺失也照样占一行并标「（无）」—— 排障口径。
List<String> jevDiagnosticLines(JevTestReport r) {
  final d = r.diagnostics;
  if (d == null) {
    return [
      '请求 URL：${r.endpoint.trim().isEmpty ? '—' : r.endpoint}',
      'HTTP 码：—（请求没有发出：${r.failureMessage ?? '本地前置检查未通过'}）',
      'traceId：（无）',
    ];
  }
  final transport = d.transportError;
  final statusText = d.httpStatus != null
      ? '${d.httpStatus}'
      : '—（没有拿到 HTTP 响应${transport == null ? '' : '：$transport'}）';
  return [
    '请求 URL：${d.resolvedEndpoint.trim().isEmpty ? '—' : d.resolvedEndpoint}',
    'HTTP 码：$statusText',
    '耗时：${(d.elapsedMs / 1000).toStringAsFixed(1)} 秒',
    'code：${d.serverCode ?? '—'}',
    'message：${d.serverMessage ?? '—'}',
    'traceId：${d.traceId ?? '（无）'}',
  ];
}

/// 原始响应体展示上限：>2KB 截断（与 `JevCloudClient.rawBodyLimit` 同口径；
/// 服务层已先截一次，这里再兜一次 —— 注入的 mock 诊断也不会把整段倒上屏）。
int get kJevRawBodyLimit => JevCloudClient.rawBodyLimit;

/// 原始响应体预览（超限只留头部）。
String jevRawBodyPreview(String body) => body.length <= kJevRawBodyLimit
    ? body
    : body.substring(0, kJevRawBodyLimit);

/// 原始响应体是否被截断。
bool jevRawBodyTruncated(String body) => body.length > kJevRawBodyLimit;

/// 「被截断了」的显式标注（展示与复制共用）。
String jevRawBodyTruncationNote(String body) =>
    '（原始响应体共 ${body.length} 字符，已截断到 $kJevRawBodyLimit）';

/// 「复制详情」拷的纯文本：结论 + 固定行 + 原始响应体（截断标记）+ 提示。
String jevDiagnosticsText(JevTestReport r) {
  final b = StringBuffer()
    ..writeln('JEV 决策连接诊断')
    ..writeln('结论：${jevOutcomeHeadline(r)}');
  for (final line in jevDiagnosticLines(r)) {
    b.writeln(line);
  }
  final body = r.diagnostics?.rawBody ?? '';
  if (body.trim().isEmpty) {
    b.writeln('原始响应体：（无）');
  } else {
    b
      ..writeln('原始响应体：')
      ..writeln(jevRawBodyPreview(body));
    if (jevRawBodyTruncated(body)) {
      b.writeln(jevRawBodyTruncationNote(body));
    }
  }
  final hint = jevHintCopy(
    r.diagnostics == null ? JevHintKind.none : jevHintKindOf(r.diagnostics!),
  );
  if (hint.isNotEmpty) b.writeln('排障提示：$hint');
  return b.toString();
}

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
  const JevSettingsScreen({
    super.key,
    required this.jev,
    this.decideProbe,
    this.modelsProbe,
  });

  final JevController jev;

  /// 测试注入点（生产为 null ⇒ 走 `JevCloudClient`，UI 自己不发 HTTP）。
  final JevDecideProbe? decideProbe;
  final JevModelsProbe? modelsProbe;

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
  JevTestReport? _report;
  bool _diagExpanded = false;
  String? _preflightError;

  // 模型目录拉取成功但没有固定决策模型 ⇒ 大概率没该模型权限（真实状态）。
  String? _catalogHint;

  JevController get jev => widget.jev;

  @override
  void initState() {
    super.initState();
    _urlCtrl.text = jev.config.cloudBaseUrl;
    _modelCtrl.text = jev.config.cloudModel;
    // 「将请求：POST …」与固定模型黄字提示都要随输入实时变。
    _urlCtrl.addListener(_onFormChanged);
    _modelCtrl.addListener(_onFormChanged);
    unawaited(_loadKey());
    if (!jev.loaded) unawaited(jev.load());
  }

  void _onFormChanged() {
    if (mounted) setState(() {});
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
    _urlCtrl.removeListener(_onFormChanged);
    _modelCtrl.removeListener(_onFormChanged);
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
  /// 目录拉成功但没有固定决策模型 ⇒ 黄字提示「可能没模型权限」。
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
      _catalogHint = null;
    });
    try {
      final models = await (widget.modelsProbe?.call(
                baseUrl: baseUrl,
                apiKey: apiKey,
              ) ??
              JevCloudClient.fetchModels(baseUrl: baseUrl, apiKey: apiKey));
      if (!mounted) return;
      setState(() {
        _modelCatalog = models;
        _catalogHint = models.contains(kJevDefaultModel)
            ? null
            : '目录里没有 $kJevDefaultModel —— 这个密钥可能没有该模型的权限'
                '（平台目录只回可用的模型）。';
      });
      if (!mounted) return;
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
  ///
  /// 展示口径（用户 2026-10-29）：**默认一行结论**，「详情」可折叠展开
  /// 请求 URL / HTTP 码 / code / message / traceId / 原始响应体（>2KB
  /// 截断）+ 复制详情；成功也显示 URL 与耗时。失败**绝不**画成成功。
  Future<void> _testConnection() async {
    final baseUrl = _urlCtrl.text.trim();
    final apiKey = _keyCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final resolution = JevCloudClient.resolveEndpoint(baseUrl);
    if (baseUrl.isEmpty) {
      setState(() {
        _preflightError = resolution.hint ?? '先填接口地址';
        _report = null;
      });
      return;
    }
    setState(() {
      _testing = true;
      _preflightError = null;
      _report = null;
      _diagExpanded = false;
    });
    const question = '连通性测试：路口信号灯为红色，前方有行人，现在是否应停车？';
    final probe = widget.decideProbe;
    try {
      final result = probe != null
          ? await probe(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              question: question,
            )
          : await JevCloudClient.decide(
              baseUrl: baseUrl,
              apiKey: apiKey,
              model: model,
              question: question,
            );
      if (!mounted) return;
      setState(() {
        _report = JevTestReport(
          endpoint: result.resolvedEndpoint,
          diagnostics: result.diagnostics,
          result: result,
        );
        _diagExpanded = false;
      });
    } on JevException catch (e) {
      if (!mounted) return;
      setState(() {
        // B8 失败时带完整诊断；本地前置错误（地址/密钥空）没有诊断，
        // 此时不编 HTTP 码，只展示人话原因。
        _report = JevTestReport(
          endpoint: e.diagnostics?.resolvedEndpoint ?? resolution.url,
          diagnostics: e.diagnostics,
          failureMessage: e.message,
        );
        _diagExpanded = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _report = JevTestReport(
          endpoint: resolution.url,
          failureMessage: '$e',
        );
        _diagExpanded = false;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _copyReport(JevTestReport report) async {
    await Clipboard.setData(ClipboardData(text: jevDiagnosticsText(report)));
    if (!mounted) return;
    showIosToast(context, '详情已复制');
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
                fieldKey: const ValueKey('jev-url-field'),
                hint: '预置基元律动：https://tokenrhythm.studio/v1/decision',
              ),
              const SizedBox(height: HSpace.xs),
              // ★ 用户 2026-10-29：地址框下方**实时**显示实际请求端点，
              // 值一律来自 JevCloudClient.resolveEndpoint（页面不自己拼）。
              _endpointPreview(h),
              const SizedBox(height: HSpace.xs),
              Text(
                '两种填法：① 完整端点 https://tokenrhythm.studio/v1/decision；'
                '② 只填到 https://tokenrhythm.studio/v1，应用自动补 /decision。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.5),
              ),
              const SizedBox(height: HSpace.md),
              _field(
                h,
                'API 密钥',
                _keyCtrl,
                fieldKey: const ValueKey('jev-key-field'),
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
              _field(
                h,
                '模型',
                _modelCtrl,
                fieldKey: const ValueKey('jev-model-field'),
                hint: '基元律动固定 NeoHorse-Jev-4B',
              ),
              // ★ 模型字段不是固定 ID 时黄字提示；B8 报告 modelCorrected
              // 时再显示「已按固定 ID 发送」。
              _modelHint(h),
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
              // ★ 目录拉成功但没有 NeoHorse-Jev-4B ⇒ 可能没有该模型权限
              // （平台目录只回可用模型；不把空目录说成「全部可用」）。
              if (_catalogHint != null) ...[
                const SizedBox(height: HSpace.xs),
                Text(
                  _catalogHint!,
                  key: const ValueKey('jev-catalog-hint'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: HColors.warnOn(h.dark),
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
                  if (_preflightError != null) ...[
                    const SizedBox(height: HSpace.sm),
                    Text(
                      _preflightError!,
                      key: const ValueKey('jev-test-preflight'),
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: HColors.errorOn(h.dark),
                      ),
                    ),
                  ],
                  if (_report != null) ...[
                    const SizedBox(height: HSpace.sm),
                    _reportBlock(h, _report!),
                  ],
                ],
              ),
              const SizedBox(height: HSpace.sm),
              Text(
                '改完点右上角「保存」；获取模型与测试连接用的是框里'
                '当前填的值，不用先保存。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.55),
              ),
              const SizedBox(height: HSpace.sm),
              Text(
                '理由生成暂不支持（后续版本提供）：决策只给结论与概率。',
                style: HTxt.caption.copyWith(color: h.textFaint, height: 1.55),
              ),
              const SizedBox(height: HSpace.lg),
              _groupLabel(h, '本地'),
              _localEntry(h),
            ],
          );
        },
      ),
    );
  }

  /// 地址框下方的**实时**请求预览 + 服务层端点补全提示。
  ///
  /// 「将请求：POST …」的值一律来自 [JevCloudClient.resolveEndpoint]
  /// （页面**不自己拼**）；裸域名等问题用服务层给的 hint，不另写一套。
  Widget _endpointPreview(Hue h) {
    final raw = _urlCtrl.text.trim();
    final resolution = JevCloudClient.resolveEndpoint(raw);
    final text = raw.isEmpty
        ? '将请求：POST （先填接口地址）'
        : '将请求：POST ${resolution.url}';
    final hint = resolution.hint?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          key: const ValueKey('jev-endpoint-preview'),
          style: TextStyle(fontSize: 12, color: h.textDim, height: 1.45),
        ),
        if (hint != null && hint.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            hint,
            key: const ValueKey('jev-endpoint-hint'),
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: HColors.warnOn(h.dark),
            ),
          ),
        ],
      ],
    );
  }

  /// 模型字段的固定 ID 提示（填错时黄字）+ B8 `modelCorrected` 的确认。
  Widget _modelHint(Hue h) {
    final typed = _modelCtrl.text.trim();
    final wrong = typed.isNotEmpty && typed != kJevDefaultModel;
    final corrected = _report?.diagnostics?.modelCorrected ?? false;
    if (!wrong && !corrected) return const SizedBox.shrink();
    final warn = HColors.warnOn(h.dark);
    return Padding(
      padding: const EdgeInsets.only(top: HSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wrong)
            Text(
              '模型 ID 固定为 $kJevDefaultModel：平台只认这一个决策模型，'
              '填别的会在发送时被强制纠正。',
              key: const ValueKey('jev-model-fixed-warning'),
              style: TextStyle(fontSize: 12, height: 1.45, color: warn),
            ),
          if (corrected) ...[
            if (wrong) const SizedBox(height: 2),
            Text(
              '已按固定 ID 发送',
              key: const ValueKey('jev-model-corrected'),
              style: TextStyle(fontSize: 12, height: 1.45, color: warn),
            ),
          ],
        ],
      ),
    );
  }

  /// 结果区：默认一行结论（绿=成功 / 红=失败），「详情」折叠展开
  /// 请求 URL / HTTP 码 / 耗时 / code / message / traceId / 原始响应体；
  /// 「复制详情」把整份诊断拷成文本。
  Widget _reportBlock(Hue h, JevTestReport report) {
    final d = report.diagnostics;
    final kind = d == null ? JevHintKind.none : jevHintKindOf(d);
    final hintCopy = jevHintCopy(kind);
    final platformHint = d?.hint?.trim() ?? '';
    final is422 = d?.httpStatus == 422;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HSpace.md),
      decoration: BoxDecoration(
        border: Border.all(color: h.border),
        borderRadius: BorderRadius.circular(HRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            jevOutcomeHeadline(report),
            key: const ValueKey('jev-outcome-headline'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: report.ok
                  ? HColors.successOn(h.dark)
                  : HColors.errorOn(h.dark),
            ),
          ),
          // ★ traceId 始终展示（折叠态也看得到 —— 平台排障要求）。
          if (d != null) ...[
            const SizedBox(height: 4),
            Text(
              'traceId：${d.traceId ?? '（无）'}',
              key: const ValueKey('jev-outcome-trace'),
              style: TextStyle(fontSize: 12, height: 1.4, color: h.textFaint),
            ),
          ],
          if (hintCopy.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              hintCopy,
              key: const ValueKey('jev-hint-copy'),
              style: TextStyle(fontSize: 12, height: 1.5, color: h.textDim),
            ),
          ],
          if (is422) ...[
            const SizedBox(height: 4),
            Text(
              kJev422Categories,
              key: const ValueKey('jev-422-categories'),
              style: TextStyle(fontSize: 12, height: 1.5, color: h.textFaint),
            ),
          ],
          if (platformHint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '平台提示：$platformHint',
              key: const ValueKey('jev-platform-hint'),
              style: TextStyle(fontSize: 12, height: 1.5, color: h.textFaint),
            ),
          ],
          const SizedBox(height: HSpace.sm),
          Row(
            children: [
              IosTap(
                onTap: () => setState(() => _diagExpanded = !_diagExpanded),
                child: Text(
                  _diagExpanded ? '收起' : '详情',
                  key: const ValueKey('jev-detail-toggle'),
                  style: TextStyle(fontSize: 12, color: h.accent),
                ),
              ),
              const SizedBox(width: HSpace.lg),
              IosTap(
                onTap: () => unawaited(_copyReport(report)),
                child: Text(
                  '复制详情',
                  key: const ValueKey('jev-copy-details'),
                  style: TextStyle(fontSize: 12, color: h.accent),
                ),
              ),
            ],
          ),
          if (_diagExpanded) ...[
            const SizedBox(height: HSpace.sm),
            for (final line in jevDiagnosticLines(report))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  line,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: h.textDim,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: _rawBodyBlock(h, d),
            ),
          ],
        ],
      ),
    );
  }

  /// 原始响应体（>2KB 截断；没有 body 就说「无」，不编内容）。
  Widget _rawBodyBlock(Hue h, JevDiagnostics? d) {
    final body = d?.rawBody ?? '';
    if (body.trim().isEmpty) {
      return Text(
        '原始响应体：（无）',
        key: const ValueKey('jev-raw-body-empty'),
        style: TextStyle(fontSize: 12, height: 1.4, color: h.textDim),
      );
    }
    final truncated = jevRawBodyTruncated(body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '原始响应体：',
          style: TextStyle(fontSize: 12, height: 1.4, color: h.textDim),
        ),
        if (truncated)
          Text(
            jevRawBodyTruncationNote(body),
            key: const ValueKey('jev-raw-body-truncated'),
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: HColors.warnOn(h.dark),
            ),
          ),
        Text(
          jevRawBodyPreview(body),
          key: const ValueKey('jev-raw-body'),
          maxLines: 8,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, height: 1.4, color: h.textFaint),
        ),
      ],
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
  /// 框、右端可挂操作（如密钥可见切换）。[fieldKey] 给测试定位输入框。
  Widget _field(
    Hue h,
    String label,
    TextEditingController ctrl, {
    Key? fieldKey,
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
                  key: fieldKey,
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
}
