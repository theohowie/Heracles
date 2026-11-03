// vendored: modified by Heracles
// 断言口径补丁：`skill_path` 期望值改为产品规范形态（`/`），使该用例在 Windows
// 上可用。POSIX 下等价、强度不变。详见文件末尾 `_asProductPath`。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDirectory;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync(
      'dart_agent_core_directory_skills_',
    );
  });

  tearDown(() {
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('blank roots do not enable directory skill mode', () {
    final agent = _createAgent(
      skillDirectoryPaths: const ['', '   '],
      javaScriptRuntime: _RecordingJavaScriptRuntime(),
    );

    expect(
      agent.composeTools().where((tool) => tool.name == 'RunJavaScript'),
      isEmpty,
    );
  });

  test('blank roots do not conflict with in-memory skills', () {
    expect(
      () => StatefulAgent(
        name: 'directory-skills-test',
        client: _CapturingLLMClient(),
        modelConfig: ModelConfig(model: 'fake-model'),
        state: AgentState.empty(),
        skills: [_TestSkill()],
        skillDirectoryPaths: const ['   '],
      ),
      returnsNormally,
    );
  });

  test(
    'blank roots cannot expand JavaScript access to the working directory',
    () async {
      final allowedRoot = Directory('${tempDirectory.path}/allowed')
        ..createSync();
      final outsideScript = File(
        '${Directory.current.path}/.directory_skill_security_test_$pid.js',
      )..writeAsStringSync('// regression test');
      addTearDown(() {
        if (outsideScript.existsSync()) outsideScript.deleteSync();
      });
      final runtime = _RecordingJavaScriptRuntime();
      final agent = _createAgent(
        skillDirectoryPaths: [allowedRoot.path, '   '],
        javaScriptRuntime: runtime,
      );
      final runJavaScript = agent.composeTools().singleWhere(
        (tool) => tool.name == 'RunJavaScript',
      );

      final result =
          await Function.apply(runJavaScript.executable!, [
                outsideScript.absolute.path,
                null,
                null,
              ])
              as String;

      expect(
        result,
        contains('must stay under one of the skillDirectoryPaths'),
      );
      expect(runtime.executedPaths, isEmpty);
    },
  );

  test('overlapping roots inject the same skill only once', () async {
    final parentRoot = Directory('${tempDirectory.path}/skills')..createSync();
    final projectRoot = Directory('${parentRoot.path}/project')..createSync();
    final skillFile = _writeSkill(
      projectRoot,
      'demo',
      'Duplicate-root regression skill.',
    );
    final client = _CapturingLLMClient();
    final state = AgentState.empty();
    final agent = _createAgent(
      client: client,
      state: state,
      skillDirectoryPaths: [parentRoot.path, projectRoot.path],
    );

    await agent.run([UserMessage.text(r'Use $demo')], useStream: false);

    final injectedSkills = state.history.messages
        .whereType<UserMessage>()
        .where((message) => message.metadata?['type'] == 'skill_instructions')
        .toList();
    expect(injectedSkills, hasLength(1));
    expect(
      injectedSkills.single.metadata?['skill_path'],
      // 与产品同口径比较（说明见文件末尾 `_asProductPath`）：
      // 产品把 skill_path 统一成 `/`，而 `Directory.path` 在 Windows 上给 `\`。
      // POSIX 下两者字面相同 ⇒ 断言等价；不做这一步则 Windows 恒红。
      _asProductPath(skillFile.absolute.path),
    );

    final systemPrompt = client.capturedMessages.single
        .whereType<SystemMessage>()
        .single
        .content;
    expect(
      RegExp('Duplicate-root regression skill').allMatches(systemPrompt),
      hasLength(1),
    );
  });

  test('a single valid root discovers and injects a named skill', () async {
    final root = Directory('${tempDirectory.path}/single')..createSync();
    final skillFile = _writeSkill(root, 'single', 'Single-root skill.');
    final state = AgentState.empty();
    final agent = _createAgent(state: state, skillDirectoryPaths: [root.path]);

    await agent.run([UserMessage.text(r'Use $single')], useStream: false);

    final injectedSkills = _injectedSkillMessages(state);
    expect(injectedSkills, hasLength(1));
    expect(
      injectedSkills.single.metadata?['skill_path'],
      // 同上：按产品的规范形态（`/`）比较，理由见 `_asProductPath`。
      _asProductPath(skillFile.absolute.path),
    );
  });

  test('distinct roots discover and inject all named skills', () async {
    final systemRoot = Directory('${tempDirectory.path}/system')..createSync();
    final projectRoot = Directory('${tempDirectory.path}/project')
      ..createSync();
    final systemSkill = _writeSkill(
      systemRoot,
      'system_skill',
      'System-level skill.',
    );
    final projectSkill = _writeSkill(
      projectRoot,
      'project_skill',
      'Project-level skill.',
    );
    final state = AgentState.empty();
    final agent = _createAgent(
      state: state,
      skillDirectoryPaths: [systemRoot.path, projectRoot.path],
    );

    await agent.run([
      UserMessage.text(r'Use $system_skill and $project_skill'),
    ], useStream: false);

    expect(
      _injectedSkillMessages(
        state,
      ).map((message) => message.metadata?['skill_path']),
      unorderedEquals([
        // 同上：按产品的规范形态（`/`）比较，理由见 `_asProductPath`。
        _asProductPath(systemSkill.absolute.path),
        _asProductPath(projectSkill.absolute.path),
      ]),
    );
  });

  test(
    'JavaScript execution allows files inside roots and rejects outside files',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final insideScript = File('${root.path}/inside.js')
        ..writeAsStringSync('// allowed');
      final outsideScript = File('${tempDirectory.path}/outside.js')
        ..writeAsStringSync('// rejected');
      final runtime = _RecordingJavaScriptRuntime();
      final agent = _createAgent(
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );
      final runJavaScript = agent.composeTools().singleWhere(
        (tool) => tool.name == 'RunJavaScript',
      );

      final insideResult =
          await Function.apply(runJavaScript.executable!, [
                insideScript.absolute.path,
                null,
                null,
              ])
              as String;
      final outsideResult =
          await Function.apply(runJavaScript.executable!, [
                outsideScript.absolute.path,
                null,
                null,
              ])
              as String;

      expect(jsonDecode(insideResult), containsPair('success', true));
      expect(outsideResult, contains('must stay under'));
      expect(runtime.executedPaths, [insideScript.absolute.path]);
    },
  );

  // ==========================================================================
  // ★ 2026-11-03（QA，T-core-1-VERIFY）：`..` 折叠的回归门禁
  //
  // 为什么单独加这两条：修 `76d969a` 里「`_comparisonPath` 必须折叠 `..`」是全
  // 套件**零覆盖**的安全加固 —— 实测把折叠摘掉，原有 13 条**全绿**
  // （0 条红），也就是说这条越权通道此前没有任何测试守着。
  //
  // 失败模式（不折叠时）：`<root>/../outside.js` 以 `<root>/` 为前缀 ⇒ 通过
  // 白名单 ⇒ 被放行并执行。同时补一条正向用例，防止将来有人用「一律拒绝」蒙混
  // 过负向用例。
  // ==========================================================================

  test(
    'skill roots reject .. traversal that escapes the root',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      // 与白名单根**同级**的外部脚本：只有把 `..` 折叠掉才能判出它越界
      final outsideScript = File('${tempDirectory.path}/outside.js')
        ..writeAsStringSync('// must not run');
      final traversalPath = '${root.path}/../outside.js';

      final runtime = _RecordingJavaScriptRuntime();
      final agent = _createAgent(
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );
      final runJavaScript = agent.composeTools().singleWhere(
        (tool) => tool.name == 'RunJavaScript',
      );

      final result =
          await Function.apply(runJavaScript.executable!, [
                traversalPath,
                null,
                null,
              ])
              as String;

      expect(
        result,
        contains('script path must stay under one of the skillDirectoryPaths.'),
        reason: '`<root>/../outside.js` 折叠后越出白名单根，必须被拒（否则是越权通道）',
      );
      expect(runtime.executedPaths, isEmpty, reason: '被拒绝的脚本绝不能被运行时执行');
      // 反向确认这条用例的确触到了"越界"而不是别的原因（如文件不存在）
      expect(outsideScript.existsSync(), isTrue, reason: '外部脚本必须真实存在');
    },
  );

  test(
    'skill roots allow .. that folds back inside the root',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      // `../` 拐一下仍落在根内 ⇒ 折叠后应判为合法，必须放行并执行
      Directory('${tempDirectory.path}/allowed2')..createSync();
      final insideScript = File('${root.path}/inside.js')
        ..writeAsStringSync('// allowed');
      final foldedInsidePath = '${tempDirectory.path}/allowed2/../allowed/inside.js';

      final runtime = _RecordingJavaScriptRuntime();
      final agent = _createAgent(
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );
      final runJavaScript = agent.composeTools().singleWhere(
        (tool) => tool.name == 'RunJavaScript',
      );

      final result =
          await Function.apply(runJavaScript.executable!, [
                foldedInsidePath,
                null,
                null,
              ])
              as String;

      expect(
        jsonDecode(result),
        containsPair('success', true),
        reason: '折叠后落在根内的脚本必须放行 —— 不许用"一律拒绝"糊过负向用例',
      );
      expect(runtime.executedPaths, [File(foldedInsidePath).absolute.path],
          reason: '放行的就是这一条，且交给运行时的仍是原生路径');
    },
  );

  test(
    'agent loop executes RunJavaScript through the central tool path',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final script = File('${root.path}/skill.js')
        ..writeAsStringSync('ctx.args.n');
      final runtime = _RecordingJavaScriptRuntime();
      final client = _CapturingLLMClient([
        _runJavaScriptCall(
          id: 'js-1',
          scriptPath: script.absolute.path,
          args: '{"n":1}',
        ),
        ModelMessage(
          model: 'fake-model',
          textOutput: 'done',
          stopReason: 'stop',
        ),
      ]);
      final agent = _createAgent(
        client: client,
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );

      await agent.run([
        UserMessage.text('Run the skill script.'),
      ], useStream: false);

      expect(runtime.executedPaths, [script.absolute.path]);
      expect(runtime.executedArgs, [
        {'n': 1},
      ]);
      expect(runtime.executionContexts.single?.agent, same(agent));
      expect(runtime.executionContexts.single?.state, same(agent.state));
      final toolResult = agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(toolResult.isError, isFalse);
      expect(
        jsonDecode((toolResult.content.single as TextPart).text),
        containsPair('success', true),
      );
    },
  );

  test('custom RunJavaScript tools use their registered executable', () async {
    var customToolCalls = 0;
    final client = _CapturingLLMClient([
      ModelMessage(
        model: 'fake-model',
        functionCalls: [
          FunctionCall(
            id: 'custom-js',
            name: 'RunJavaScript',
            arguments: jsonEncode({'value': 'custom'}),
          ),
        ],
        stopReason: 'tool_use',
      ),
      ModelMessage(model: 'fake-model', textOutput: 'done', stopReason: 'stop'),
    ]);
    final agent = _createAgent(
      client: client,
      skillDirectoryPaths: const [],
      tools: [
        Tool(
          name: 'RunJavaScript',
          description: 'A user-defined tool with the same name.',
          executable: (String value) {
            customToolCalls++;
            return 'custom:$value';
          },
          parameters: {
            'type': 'object',
            'properties': {
              'value': {'type': 'string'},
            },
            'required': ['value'],
          },
        ),
      ],
    );

    await agent.run([
      UserMessage.text('Run the custom JavaScript tool.'),
    ], useStream: false);

    expect(customToolCalls, 1);
    final toolResult = agent.state.history.messages
        .whereType<FunctionExecutionResultMessage>()
        .single
        .results
        .single;
    expect(toolResult.isError, isFalse);
    expect((toolResult.content.single as TextPart).text, 'custom:custom');
  });

  test('cancelled runs do not start registered tools', () async {
    var toolCalls = 0;
    final cancelToken = CancelToken();
    final client = _CancelAfterGenerateClient(cancelToken, [
      ModelMessage(
        model: 'fake-model',
        functionCalls: [
          FunctionCall(
            id: 'cancelled-tool',
            name: 'custom_tool',
            arguments: '{}',
          ),
        ],
        stopReason: 'tool_use',
      ),
    ]);
    final agent = _createAgent(
      client: client,
      skillDirectoryPaths: const [],
      tools: [
        Tool(
          name: 'custom_tool',
          description: 'Must not run after cancellation.',
          executable: () {
            toolCalls++;
            return 'unexpected';
          },
          parameters: const {'type': 'object', 'properties': {}},
        ),
      ],
    );

    await expectLater(
      agent.run(
        [UserMessage.text('Run then cancel.')],
        useStream: false,
        cancelToken: cancelToken,
      ),
      throwsA(
        isA<AgentException>().having(
          (error) => error.code,
          'code',
          AgentExceptionCode.cancelled,
        ),
      ),
    );
    expect(toolCalls, 0);
  });

  test(
    'agent loop sandbox rejects RunJavaScript paths outside skill roots',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final outside = File('${tempDirectory.path}/outside.js')
        ..writeAsStringSync('// rejected');
      final runtime = _RecordingJavaScriptRuntime();
      final client = _CapturingLLMClient([
        _runJavaScriptCall(id: 'js-out', scriptPath: outside.absolute.path),
        ModelMessage(
          model: 'fake-model',
          textOutput: 'done',
          stopReason: 'stop',
        ),
      ]);
      final agent = _createAgent(
        client: client,
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );

      await agent.run([
        UserMessage.text('Run a script outside the skill root.'),
      ], useStream: false);

      expect(runtime.executedPaths, isEmpty);
      final toolResult = agent.state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single
          .results
          .single;
      expect(toolResult.isError, isTrue);
      expect(
        (toolResult.content.single as TextPart).text,
        contains('must stay under one of the skillDirectoryPaths'),
      );
    },
  );

  test(
    'cancelled RunJavaScript does not start the JavaScript runtime',
    () async {
      final root = Directory('${tempDirectory.path}/allowed')..createSync();
      final script = File('${root.path}/skill.js')..writeAsStringSync('1');
      final runtime = _RecordingJavaScriptRuntime();
      final cancelToken = CancelToken();
      final client = _CancelAfterGenerateClient(cancelToken, [
        _runJavaScriptCall(id: 'js-cancel', scriptPath: script.absolute.path),
      ]);
      final agent = _createAgent(
        client: client,
        skillDirectoryPaths: [root.path],
        javaScriptRuntime: runtime,
      );

      await expectLater(
        agent.run(
          [UserMessage.text('Run then cancel.')],
          useStream: false,
          cancelToken: cancelToken,
        ),
        throwsA(
          isA<AgentException>().having(
            (error) => error.code,
            'code',
            AgentExceptionCode.cancelled,
          ),
        ),
      );
      expect(runtime.executedPaths, isEmpty);
    },
  );

  test('clone sub-agents inherit every configured skill root', () async {
    final systemRoot = Directory('${tempDirectory.path}/system')..createSync();
    final projectRoot = Directory('${tempDirectory.path}/project')
      ..createSync();
    _writeSkill(systemRoot, 'system_skill', 'Inherited system skill.');
    _writeSkill(projectRoot, 'project_skill', 'Inherited project skill.');
    final client = _CapturingLLMClient([
      ModelMessage(
        model: 'fake-model',
        functionCalls: [
          FunctionCall(
            id: 'delegate-1',
            name: 'delegate_task',
            arguments: jsonEncode({
              'assignee': 'clone',
              'task_description': 'Complete the delegated task.',
            }),
          ),
        ],
        stopReason: 'tool_use',
      ),
      ModelMessage(
        model: 'fake-model',
        textOutput: 'worker done',
        stopReason: 'stop',
      ),
      ModelMessage(
        model: 'fake-model',
        textOutput: 'parent done',
        stopReason: 'stop',
      ),
    ]);
    final agent = _createAgent(
      client: client,
      skillDirectoryPaths: [systemRoot.path, projectRoot.path],
      disableSubAgents: false,
    );

    await agent.run([
      UserMessage.text('Delegate this task to a clone.'),
    ], useStream: false);

    final workerMessages = client.capturedMessages.singleWhere(
      (messages) => messages.whereType<SystemMessage>().any(
        (message) => message.content.contains('WORKER AGENT PROTOCOL'),
      ),
    );
    final workerSystemPrompt = workerMessages
        .whereType<SystemMessage>()
        .single
        .content;
    expect(workerSystemPrompt, contains('Inherited system skill.'));
    expect(workerSystemPrompt, contains('Inherited project skill.'));
  });
}

File _writeSkill(Directory root, String name, String description) {
  return File('${root.path}/$name/SKILL.md')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
---
name: $name
description: $description
---

Follow the $name instructions.
''');
}

List<UserMessage> _injectedSkillMessages(AgentState state) {
  return state.history.messages
      .whereType<UserMessage>()
      .where((message) => message.metadata?['type'] == 'skill_instructions')
      .toList();
}

/// 把「期望路径」折成**产品的规范形态**（分隔符统一为 `/`）再比较。
///
/// 为什么需要这一步（不是放宽断言）：
/// * 产品侧 `skill.dart` 的 `_normalizePath` 会把技能文件路径统一成 `/`，写进
///   `DirectorySkillMetadata.pathToSkillMd` → `metadata['skill_path']`；
/// * 测试侧用 `Directory('${tempDirectory.path}/x')` 拼路径，在 Windows 上
///   `Directory.path` / `File.absolute.path` 保留 `\`，于是期望值是
///   `F:\...\x/y/SKILL.md` 这种**混合形态**，与产品的 `/` 形态字面不等；
/// * POSIX 下两者都是 `/`，本函数是 no-op ⇒ 断言**语义与强度完全不变**，
///   差别只在「不再假设平台分隔符等于框架归一化结果」。
///
/// 也就是说：断言仍然钉住同一个规范路径；去掉这一步，Windows 上恒红（红的是
/// 断言的可移植性，不是产品行为）。产品侧的对应修复见
/// `lib/src/agent/stateful_agent.dart` 的 `_comparisonPath`。
String _asProductPath(String path) => path.replaceAll(r'\', '/');

StatefulAgent _createAgent({
  LLMClient? client,
  AgentState? state,
  required List<String> skillDirectoryPaths,
  JavaScriptRuntime? javaScriptRuntime,
  List<Tool>? tools,
  bool disableSubAgents = true,
}) {
  return StatefulAgent(
    name: 'directory-skills-test',
    client: client ?? _CapturingLLMClient(),
    modelConfig: ModelConfig(model: 'fake-model'),
    state: state ?? AgentState.empty(),
    tools: tools,
    skillDirectoryPaths: skillDirectoryPaths,
    javaScriptRuntime: javaScriptRuntime,
    withGeneralPrinciples: false,
    disableSubAgents: disableSubAgents,
  );
}

class _CapturingLLMClient extends LLMClient {
  final capturedMessages = <List<LLMMessage>>[];
  final List<ModelMessage> replies;
  int _replyIndex = 0;

  _CapturingLLMClient([this.replies = const []]);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    capturedMessages.add(List<LLMMessage>.from(messages));
    if (replies.isNotEmpty) {
      return replies[_replyIndex++];
    }
    return ModelMessage(
      model: modelConfig.model,
      textOutput: 'done',
      stopReason: 'stop',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    capturedMessages.add(List<LLMMessage>.from(messages));
    final reply = replies.isEmpty
        ? ModelMessage(
            model: modelConfig.model,
            textOutput: 'done',
            stopReason: 'stop',
          )
        : replies[_replyIndex++];
    return Stream.value(StreamingMessage(modelMessage: reply));
  }
}

class _CancelAfterGenerateClient extends _CapturingLLMClient {
  final CancelToken tokenToCancel;

  _CancelAfterGenerateClient(this.tokenToCancel, [super.replies]);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final reply = await super.generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    tokenToCancel.cancel('stop');
    return reply;
  }
}

class _RecordingJavaScriptRuntime implements JavaScriptRuntime {
  final executedPaths = <String>[];
  final executedArgs = <Map<String, dynamic>?>[];
  final executionContexts = <AgentCallToolContext?>[];

  @override
  Future<JavaScriptExecutionResult> executeFile({
    required String scriptPath,
    Map<String, dynamic>? args,
    Duration? timeout,
    required JavaScriptBridgeRegistry bridgeRegistry,
    required JavaScriptBridgeContext bridgeContext,
  }) async {
    executedPaths.add(scriptPath);
    executedArgs.add(args);
    executionContexts.add(AgentCallToolContext.current);
    return JavaScriptExecutionResult(success: true);
  }
}

ModelMessage _runJavaScriptCall({
  required String id,
  required String scriptPath,
  String? args,
}) {
  return ModelMessage(
    model: 'fake-model',
    functionCalls: [
      FunctionCall(
        id: id,
        name: 'RunJavaScript',
        arguments: jsonEncode({'script_path': scriptPath, 'args': ?args}),
      ),
    ],
    stopReason: 'tool_use',
  );
}

class _TestSkill extends Skill {
  _TestSkill()
    : super(
        name: 'in-memory',
        description: 'In-memory regression skill.',
        systemPrompt: 'Use the in-memory skill.',
      );
}
