/// **「连接 Github」流程**（2026-10-27 起，2026-10-28 按用户两次反馈重做）。
///
/// ## 用户看到的顺序（**这是本文件最重要的部分**）
///
/// ```
/// 1) 面板打开 → 「正在向 GitHub 申请验证码…」
/// 2) 码到了 → 大字显示 ┌ 59A9-D9F6 ┐ + 「已复制」+ 「还剩 14:32」
/// 3) 用户看清楚后，**自己点** [ 打开 GitHub 授权页 ]
/// 4) 浏览器打开 → 用户粘贴码 → Authorize
/// 5) 面板自动关闭（轮询早就跑着，用户回来时结果已就绪）
/// ```
///
/// ## ★ 两条来自真机的教训（改这个文件前必须先读）
///
/// ### 教训 1：**不许自动跳浏览器**（2026-10-28 用户原话）
///
/// > 你这授权码还没出来呢，就直接到浏览器去授权了？
/// > 你不要先提醒用户记好这个授权码再跳浏览器吗？
/// > 让用户点击继续咯，然后再跳浏览器
///
/// 第一版是「拿到码 → 自动复制 → 立刻跳浏览器」。问题：用户**根本没机会
/// 看到码**，回来时倒计时走了一半，且不知道到底复制成功没有。
///
/// ⇒ 现在必须**先展示、等用户点**。多一次点击，换用户知道自己在干什么。
///
/// ### 教训 2：**面板高度必须一屏放得下**（2026-10-28 用户原话）
///
/// > 明明下方还有东西，你这个上拉抽屉做这么低干嘛？还有东西没显示出来
///
/// 第一版把内容堆得很高（码块 18px 内边距 + 三行说明 + 两个按钮 + 三段小字），
/// 结果 `BwSheetShell` 按自然高度只量到一部分，**下面的按钮被裁掉了** ——
/// 用户看到的是"码出来了，但没地方点"。
///
/// ⇒ 现在刻意压紧凑：**一个主按钮**，说明文字并成一行，总高控制在
/// 面板首次展开就能全看见的范围内。宁少勿裁。
///
/// ## 为什么不用一次性跳转授权（web application flow）
///
/// 那条路换 token 必须带 `client_secret`。本 App 开源 + 纯客户端、没有服务器
/// ⇒ 只能把 secret 打进 APK ⇒ 等于公开泄露（APK 是 zip，`strings` 就能翻）。
/// Device Flow 官方明确不需要 secret（"`client_secret` is not needed for the
/// device flow"）。代价就是用户要输一次 8 位码。
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/github_auth.dart';
import '../services/github_config.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../widgets/bw_approval.dart';

/// 弹出「连接 Github」抽屉。
///
/// 返回值：`true` = 已连上；`false`/`null` = 取消或失败。
Future<bool> showGitHubConnectSheet(BuildContext context) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(false),
      child: _GitHubConnectSheet(h: Hue.of(context)),
    ),
  );
  return r ?? false;
}

class _GitHubConnectSheet extends StatefulWidget {
  const _GitHubConnectSheet({required this.h});

  final Hue h;

  @override
  State<_GitHubConnectSheet> createState() => _GitHubConnectSheetState();
}

class _GitHubConnectSheetState extends State<_GitHubConnectSheet> {
  _Phase _phase = _Phase.requesting;

  DeviceCodeInfo? _info;
  String? _error;

  /// 剩余秒数（倒计时，纯展示）。
  int _remaining = 0;
  Timer? _ticker;

  /// 码是否已复制（决定提示文案，不弹 toast —— 见 `_start`）。
  bool _copied = false;

  final _auth = GitHubAuth(
    clientId: GitHubConfig.clientId,
    // 只有用户点了按钮才会走到这里（`_openBrowser`），不自动调。
    openBrowser: (url) async {
      try {
        return await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false; // 没浏览器/被系统拦：由 `_openBrowser` 如实告知
      }
    },
  );

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 请求设备码 → 展示 → 开始轮询。**不自动开浏览器**（教训 1）。
  Future<void> _start() async {
    final r = await _auth.start(scopes: GitHubConfig.scopes);
    if (!mounted) return;

    if (r is GitHubAuthFailure) {
      setState(() {
        _phase = _Phase.failed;
        _error = r.reason;
      });
      return;
    }
    final info = r as DeviceCodeInfo;
    setState(() {
      _phase = _Phase.waiting;
      _info = info;
      _remaining = info.expiresIn;
    });

    // ① 自动复制（省用户一次操作）。**不弹 toast** —— 码就在眼前，
    //    再弹一条"已复制"会盖住它，反而看不清。
    try {
      await Clipboard.setData(ClipboardData(text: info.userCode));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (mounted) setState(() => _copied = false);
    }

    // ② 倒计时
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });

    // ③ 轮询（**先跑起来**：用户可能自己开了浏览器；等他回来时结果要已就绪，
    //    不能让他再等一轮）
    final result = await _auth.finish(info);
    if (!mounted) return;
    _ticker?.cancel();

    if (result is GitHubAuthSuccess) {
      setState(() => _phase = _Phase.done);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _phase = _Phase.failed;
        _error = (result as GitHubAuthFailure).reason;
      });
    }
  }

  /// 用户点按钮后才跳浏览器。
  Future<void> _openBrowser() async {
    final info = _info;
    if (info == null) return;
    final ok = await _auth.openVerificationPage(info);
    if (!mounted) return;
    if (!ok) {
      showIosToast(context, '打不开浏览器，请手动访问 ${info.verificationUri}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              HSpace.lg, HSpace.xs, HSpace.lg, HSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 抓手
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: HSpace.sm),
                  decoration: BoxDecoration(
                    color: h.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '连接 Github',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: h.text,
                ),
              ),
              const SizedBox(height: HSpace.sm),
              ..._body(h),
            ],
          ),
        ),
      ),
    );
  }

  /// 各阶段内容。
  ///
  /// ## ★ 为什么「申请中」和「等待」画成**同一套骨架**（2026-10-28 真机 bug）
  ///
  /// `BwSheetShell` 的高度是**首帧量一次**（`_natural`）再按它确定 `_extent`。
  /// 第一版让 `requesting` 阶段只画一行 spinner（高度 ≈ 170dp），
  /// 之后切到 `waiting` 才画出码块 + 按钮（高度 ≈ 340dp）——
  /// **面板高度没跟着长**，结果：
  ///
  /// ```
  /// 真机实测（1080×2400）：面板高 458px，码块占到 y=2397（屏幕底），
  /// 「打开 GitHub 授权页」按钮**根本不在视图树里** —— 用户看到码，却没地方点。
  /// ```
  ///
  /// ⇒ 现在两个阶段共用同一套骨架（码位在申请中显示占位），**首帧高度 =
  /// 最终高度**，不依赖"内容变高后能否重新测量"这种脆弱假设。
  /// 顺带的好处：状态切换时**布局不跳**。
  List<Widget> _body(Hue h) {
    switch (_phase) {
      // ---------------------------------------------------------------
      // 失败态：内容短，不需要骨架（此时面板已经量过高，收缩不影响可用性）
      // ---------------------------------------------------------------
      case _Phase.failed:
        return [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CupertinoIcons.exclamationmark_circle_fill,
                size: 19, color: HColors.errorOn(h.dark)),
            const SizedBox(width: HSpace.sm),
            Expanded(
              child: Text(
                _error ?? '连接失败',
                style: TextStyle(fontSize: 13.5, color: h.text, height: 1.45),
              ),
            ),
          ]),
          const SizedBox(height: HSpace.md),
          FilledButton(
            onPressed: () {
              setState(() {
                _phase = _Phase.requesting;
                _error = null;
                _ticker?.cancel();
              });
              unawaited(_start());
            },
            child: const Text('重试'),
          ),
          const SizedBox(height: HSpace.xs),
          _cancelButton(h, label: '关闭'),
        ];

      // ---------------------------------------------------------------
      // 成功态：短暂显示后自动关闭
      // ---------------------------------------------------------------
      case _Phase.done:
        return [
          Row(children: [
            Icon(CupertinoIcons.checkmark_circle_fill,
                size: 19, color: HColors.successOn(h.dark)),
            const SizedBox(width: HSpace.sm),
            Text('已连接 Github',
                style: TextStyle(fontSize: 15, color: h.text)),
          ]),
        ];

      // ---------------------------------------------------------------
      // ★ 骨架：requesting 与 waiting 共用（高度恒定）
      // ---------------------------------------------------------------
      case _Phase.requesting:
      case _Phase.waiting:
        final waiting = _phase == _Phase.waiting;
        final info = _info;
        final mm = (_remaining ~/ 60).toString().padLeft(2, '0');
        final ss = (_remaining % 60).toString().padLeft(2, '0');
        return [
          Text(
            waiting
                ? '先在浏览器输入这个码，再回来这里（会自动连上）：'
                : '正在向 GitHub 申请验证码…',
            style: TextStyle(fontSize: 13, color: h.textDim, height: 1.4),
          ),
          const SizedBox(height: HSpace.sm),

          // ---- 码位（申请中显示占位，保持同样的高度）----
          GestureDetector(
            onTap: info == null
                ? null
                : () async {
                    await Clipboard.setData(
                        ClipboardData(text: info.userCode));
                    if (mounted) showIosToast(context, '已复制验证码');
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: h.surfaceAlt,
                borderRadius: BorderRadius.circular(HRadius.lg),
                border: Border.all(color: h.border),
              ),
              child: Column(
                children: [
                  if (info == null)
                    // 占位：高度与真码那行一致（26px 字号 + 行高）
                    SizedBox(
                      height: 34,
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: h.accent),
                        ),
                      ),
                    )
                  else
                    Text(
                      info.userCode,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3,
                        fontFamily: 'monospace',
                        color: h.text,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                    info == null
                        ? '稍等…'
                        : (_copied ? '已自动复制 · 点码可再复制' : '点码可复制'),
                    style: TextStyle(fontSize: 11, color: h.textFaint),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: HSpace.md),

          // ---- 主按钮：用户确认看清了才跳浏览器（教训 1）----
          FilledButton(
            onPressed: info == null ? null : () => unawaited(_openBrowser()),
            child: const Text('打开 GitHub 授权页'),
          ),
          const SizedBox(height: HSpace.sm),

          // ---- 等待 + 倒计时 ----
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (waiting) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: h.accent),
                ),
                const SizedBox(width: HSpace.xs),
              ],
              Text(
                waiting ? '等待授权 · 剩余 $mm:$ss' : '准备中…',
                style: TextStyle(fontSize: 12, color: h.textDim),
              ),
            ],
          ),
          const SizedBox(height: HSpace.xs),

          // ---- 授权范围 + 数据用途 + 撤销入口（用户要求必须写明）----
          Text(
            '授权范围：读写你的仓库 + 读用户名。'
            '从 GitHub 获取的数据只用来帮你完成当前工作，'
            '可以随时在 GitHub 设置里撤销访问权限。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: h.textFaint, height: 1.45),
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () async {
              try {
                await launchUrl(Uri.parse(GitHubConfig.revokeUri),
                    mode: LaunchMode.externalApplication);
              } catch (_) {
                if (mounted) {
                  showIosToast(
                      context, '撤销地址：${GitHubConfig.revokeUri}');
                }
              }
            },
            child: Text(
              '去 GitHub 管理授权',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: h.accent,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          const SizedBox(height: HSpace.sm),
          _cancelButton(h),
        ];
    }
  }

  Widget _cancelButton(Hue h, {String label = '取消'}) => TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(label,
            style: TextStyle(color: h.textDim, fontSize: 14)),
      );
}

enum _Phase { requesting, waiting, done, failed }
