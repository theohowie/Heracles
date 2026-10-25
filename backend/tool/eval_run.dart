// **E1 评估集跑分器**（2026-10-24 脚手架）。
//
// ## 这是什么
//
// 对照表 E1（"固定真实任务用例，可重复运行对比"）的**最小可跑形态**：
// 固定用例（`eval_cases.json`）+ 临时 fixture 工作区 + 真 provider 跑分 +
// 结果落盘（可与基线对比）。判定是**要点命中粗筛**（expectContains 大小写
// 不敏感的 contains）—— 它能抓住"答非所问/编造路径"这类硬伤，
// 抓不住"回答质量好不好"。质量判据的演进是这个工具的后续工作。
//
// ## 用法（在装了 Key 的机器上）
//
// ```bash
// cd backend
// dart run tool/eval_run.dart --base-url https://xx/v1 --api-key sk-xx --model xxx
//   [--filter locate-function] [--window 128000]
// ```
// 环境变量等价：EVAL_BASE_URL / EVAL_API_KEY / EVAL_MODEL。
//
// ## 刻意不做的
//
// · 不接 shell/APK 能力（用例只考读/改文件 —— 少一层不确定性，
//   判定才可复现）；
// · 不写进 test/（它要真 Key、要网络，不是 CI 单测 —— 它是**手动跑分工具**）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:heracles_backend/heracles_backend.dart';
import 'package:heracles_backend/src/capability/local_workspace_capability.dart';

Future<void> main(List<String> args) async {
  String opt(String name, String env) {
    final i = args.indexOf('--$name');
    if (i >= 0 && i + 1 < args.length) return args[i + 1];
    final v = Platform.environment[env];
    if (v == null || v.isEmpty) {
      stderr.writeln('缺少 --$name（或环境变量 $env）');
      exit(2);
    }
    return v;
  }

  final baseUrl = opt('base-url', 'EVAL_BASE_URL');
  final apiKey = opt('api-key', 'EVAL_API_KEY');
  final model = opt('model', 'EVAL_MODEL');
  final filter =
      args.contains('--filter') ? args[args.indexOf('--filter') + 1] : null;
  final window = args.contains('--window')
      ? int.parse(args[args.indexOf('--window') + 1])
      : 128000;

  final casesFile = File('tool/eval_cases.json');
  final spec = jsonDecode(casesFile.readAsStringSync()) as Map<String, dynamic>;
  var cases = (spec['cases'] as List).cast<Map<String, dynamic>>();
  if (filter != null) {
    cases = cases.where((c) => (c['id'] as String).contains(filter)).toList();
  }
  if (cases.isEmpty) {
    stderr.writeln('没有命中的用例');
    exit(2);
  }

  // ---- fixture 工作区（每个 case 重建一份，互不污染）----
  Future<Directory> makeFixture() async {
    final dir = await Directory.systemTemp.createTemp('heracles_eval_');
    File('${dir.path}${Platform.pathSeparator}README.md').writeAsStringSync(
        '# Eval Fixture\n'
        '\n运行命令：`dart run bin/main.dart`\n');
    Directory('${dir.path}${Platform.pathSeparator}lib').createSync();
    File('${dir.path}${Platform.pathSeparator}lib${Platform.pathSeparator}math.dart')
        .writeAsStringSync('int add(int a, int b) => a + b;\n');
    Directory('${dir.path}${Platform.pathSeparator}bin').createSync();
    File('${dir.path}${Platform.pathSeparator}bin${Platform.pathSeparator}main.dart')
        .writeAsStringSync(
            "import 'package:fixture/math.dart' as math;\n"
            "\nvoid main() { print(math.add(1, 2)); }\n");
    Directory('${dir.path}${Platform.pathSeparator}test').createSync();
    File('${dir.path}${Platform.pathSeparator}test${Platform.pathSeparator}math_test.dart')
        .writeAsStringSync(
            "import 'package:test/test.dart';\n"
            "import 'package:fixture/math.dart';\n"
            "\nvoid main() { test('add', () { expect(add(1, 2), 3); }); }\n");
    return dir;
  }

  final results = <Map<String, dynamic>>[];
  var pass = 0;
  Map<String, dynamic>? baseline;
  final basePath = args.contains('--baseline')
      ? args[args.indexOf('--baseline') + 1]
      : null;
  if (basePath != null) {
    // ★ E2（2026-10-24）：基线对比 —— 与上次跑分逐用例比 PASS，退化能被发现
    baseline = jsonDecode(File(basePath).readAsStringSync())
        as Map<String, dynamic>;
  }

  for (final c in cases) {
    final id = c['id'] as String;
    final fixture = await makeFixture();
    try {
      final agent = HeraclesAgent(
        config: BackendConfig(
          apiKey: apiKey,
          modelName: model,
          baseUrl: baseUrl,
          modelWindowTokens: window,
        ),
        capabilities: Capabilities(
          workspace: LocalWorkspaceCapability(fixture.path),
        ),
        options: RunOptions(maxTurns: 12, maxToolCalls: 60),
      );

      String finalText = '';
      var turns = 0;
      var tokens = 0;
      var dangerCalls = 0; // E3 安全维度：高危工具调用次数
      const dangerTools = {
        'delete_path', 'move_path', 'run_shell_command', 'install_apk',
      };
      final sw = Stopwatch()..start();
      try {
        await for (final ev in agent.run(c['task'] as String)) {
          switch (ev) {
            case HeraclesFinished():
              finalText = ev.finalText;
              turns = ev.turns;
            case HeraclesToolRequested(:final toolName):
              if (dangerTools.contains(toolName)) dangerCalls++;
            case HeraclesTurnUsage(:final promptTokens, :final outputTokens):
              tokens += promptTokens + outputTokens;
            default:
              break;
          }
        }
      } on Exception catch (e) {
        finalText = '（run 异常：$e）';
      }
      sw.stop();

      final lower = finalText.toLowerCase();
      final missing = <String>[];
      for (final e in (c['expectContains'] as List? ?? const [])) {
        if (!lower.contains((e as String).toLowerCase())) missing.add(e);
      }
      var fileOk = true;
      final fileCheck = c['expectFileContains'] as Map<String, dynamic>?;
      if (fileCheck != null) {
        final f = File('${fixture.path}${Platform.pathSeparator}'
            '${(fileCheck['path'] as String).replaceAll('/', Platform.pathSeparator)}');
        final content = f.existsSync() ? f.readAsStringSync() : '';
        if (!content.contains(fileCheck['contains'] as String)) {
          fileOk = false;
          missing.add('文件未含预期内容：${fileCheck['path']}');
        }
      }

      final ok = missing.isEmpty && fileOk;
      if (ok) pass++;
      results.add({
        'id': id,
        'pass': ok,
        'missing': missing,
        'finalText': finalText,
        'wallMs': sw.elapsedMilliseconds,
        // ★ E3 多维：正确性=pass；效率=轮次/token；安全=高危调用计数
        'dims': {'turns': turns, 'tokens': tokens, 'dangerCalls': dangerCalls},
      });
      stdout.writeln('${ok ? "PASS" : "FAIL"}  $id  (${sw.elapsedMilliseconds}ms)'
          '${missing.isEmpty ? "" : "  缺：${missing.join("；")}"}');
    } finally {
      await fixture.delete(recursive: true);
    }
  }

  // ---- 落盘（与基线对比的原料）----
  final ts = DateTime.now().millisecondsSinceEpoch;
  final out = Directory('tool${Platform.pathSeparator}eval_results');
  out.createSync(recursive: true);
  final f = File('${out.path}${Platform.pathSeparator}eval-$ts.json');
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'model': model,
    'baseUrl': baseUrl,
    'window': window,
    'pass': pass,
    'total': results.length,
    'results': results,
  }));

  stdout.writeln('==== $pass/${results.length} PASS（结果已写 ${f.path}）====');

  // ★ E2：基线对比 —— 逐用例找退化
  if (baseline != null) {
    final baseCases = {
      for (final r in (baseline['results'] as List).cast<Map<String, dynamic>>())
        r['id'] as String: r,
    };
    final regressions = <String>[];
    for (final r in results) {
      final id = r['id'] as String;
      if (!baseCases.containsKey(id)) continue;
      if (baseCases[id]?['pass'] == true && r['pass'] == false) {
        regressions.add(id);
      }
    }
    if (regressions.isEmpty) {
      stdout.writeln('基线对比：无退化（${baseline['pass']}→$pass PASS）');
    } else {
      stderr.writeln('⚠️ 基线退化用例：${regressions.join("、")}');
      exitCode = 3;
    }
  }
}
