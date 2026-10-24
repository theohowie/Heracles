/// **交互类工具** —— 问用户、写长期记忆。
///
/// ## `ask_user` 为什么必须存在
///
/// 模型经常遇到"信息不足但可以推断"的情况。没有这个工具时它会**猜**，
/// 猜错了就白干。有了它，它可以停下来问一句。
///
/// ## 实现方式：`stopFlag` + 挂起
///
/// `dart_agent_core` 的 `AgentToolResult` 有 `stopFlag`，但它会**结束整个循环**。
/// 我们要的是"暂停等回答，拿到回答后继续"。
///
/// 两种做法：
/// - **A. 工具内部 await**（挂起当前工具调用，等用户回答）
/// - **B. stopFlag 结束，由外层重新发起**
///
/// 选 A：B 会让"对话历史"被切成两段，模型会以为自己被中断了。
/// A 只要 UI 侧能等待，语义最自然 —— 而且与旧实现一致（`AskReplyQueue`）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 提问门禁 —— 由宿主（UI）实现。
///
/// ## 为什么是接口而不是回调参数
///
/// 工具是**长生命周期**对象（一次组装，整个 run 复用）。
/// 用接口能让 UI 侧持有一个稳定的「回答泵」，而不是给每个工具塞闭包。
abstract class AskGate {
  /// 问用户，挂起直到回答或超时。返回渲染好的回答文本（喂回模型）。
  ///
  /// 返回 `null` = 用户没回答（超时/关闭）。**绝不编造答案**。
  Future<String?> askUser(List<AskQuestion> questions);

  /// 请求用户批准一次工具调用（2026-10-24 接线）。
  ///
  /// 由 `_ApprovalHook`（`heracles_agent.dart`）在**工具执行前**调用 ——
  /// 返回 `true` 放行执行，`false` 则该工具以"用户拒绝"的合成失败结果回给模型。
  ///
  /// ## 语义约定（宿主实现必须遵守）
  ///
  /// · **白名单先行**：宿主自己维护的「始终允许」名单命中时直接回 `true`，
  ///   不弹窗 —— 后端不感知白名单，只负责"需要批谁"。
  /// · **挂起**：与 [askUser] 同理，实现应当**挂起等用户决定**（带超时兜底），
  ///   绝不能发完事件就返回 —— 那等于替用户做决定。
  /// · **拿不到答案 = 拒绝**：超时 / 用户关闭 / 通道不可用一律回 `false`
  ///   （fail-closed），后端会把"用户拒绝"如实回给模型。
  ///
  /// ## 参数（INTERFACE.md N1 的载荷，2026-10-24 升级为结构化形状）
  ///
  /// · [callId]：框架调用 id（答复必须带回它配对）；
  /// · [toolName] / [args]：工具与参数（值已字符串化，弹窗展示完整内容，
  ///   **不要在宿主侧截断** —— 审批的意义就是"看清楚再点允许"）；
  /// · [risk]：一句话风险说明；
  /// · [workspaceInside]：操作对象是否在工作区内（shell/APK 恒 false ——
  ///   静态判不了/在工作区外）。
  Future<bool> requestApproval({
    required String callId,
    required String toolName,
    required Map<String, String> args,
    required String risk,
    required String detail,
    required bool workspaceInside,
  });
}

/// 疑似密钥/令牌的特征（SEC4）。宽匹配宁可误拦 —— 误拦的代价是
/// 模型换一句脱敏写法，漏拦的代价是凭据进了明文文件。
final RegExp _secretPattern = RegExp(
    r'(sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}'
    r'|gho_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{15,}|[A-Fa-f0-9]{32,})');

/// 构建交互工具。
///
/// [askGate] 为 `null` 时 `ask_user` 会明确告诉模型"当前无法询问用户"，
/// 而不是假装问过了 —— 后者会让模型基于**编造的答案**继续干活，后果严重。
List<Tool> buildInteractionTools(
  ToolFactory f, {
  required AskGate? askGate,
  required Capabilities caps,
}) {
  final memory = caps.memory;

  return [
    // --------------------------------------------------------------- 问用户
    f.build(
      name: 'ask_user',
      description: '向用户提问并等待回答。返回：用户逐题回答的文本（未答的题如实标注）。'
          '当关键信息缺失且无法从工作区推断时使用（例如"要覆盖还是另存？"）。'
          '⚠️ 不要用它确认显而易见的事；也不要问用户本来就能自己查的东西。',
      parameters: {
        'type': 'object',
        'properties': {
          'questions': {
            'type': 'array',
            'description': '要问的问题列表（1~4 个）。',
            'items': {
              'type': 'object',
              'properties': {
                'question': {
                  'type': 'string',
                  'description': '问题正文，要具体。',
                },
                'options': {
                  'type': 'array',
                  'description': '可选项（留空 = 自由输入）。',
                  'items': {'type': 'string'},
                },
                'multi': {
                  'type': 'boolean',
                  'description': '是否允许多选。默认 false。',
                  'default': false,
                },
              },
              'required': ['question'],
            },
          },
        },
        'required': ['questions'],
      },
      isAvailable: () => askGate != null,
      unavailableReason: '当前环境不支持向用户提问（请自行做出合理决定并说明理由）',
      run: (args) async {
        final raw = args['questions'];
        if (raw is! List || raw.isEmpty) {
          return const CapabilityFailure(
            'questions 必须是非空数组',
            isRetryable: true,
          );
        }

        final questions = <AskQuestion>[];
        for (var i = 0; i < raw.length; i++) {
          final item = raw[i];
          if (item is! Map) {
            return CapabilityFailure(
              'questions[$i] 必须是对象，收到 ${item.runtimeType}',
              isRetryable: true,
            );
          }
          final q = item['question'];
          if (q is! String || q.trim().isEmpty) {
            return CapabilityFailure(
              'questions[$i].question 必须是非空字符串',
              isRetryable: true,
            );
          }
          final opts = <AskOption>[];
          final rawOpts = item['options'];
          if (rawOpts is List) {
            for (final o in rawOpts) {
              if (o is String && o.trim().isNotEmpty) opts.add(AskOption(o));
            }
          }
          questions.add(AskQuestion(
            id: 'q${i + 1}',
            question: q,
            multi: item['multi'] == true,
            options: opts,
          ));
        }

        final answer = await askGate!.askUser(questions);
        if (answer == null) {
          // ★ 如实说"没回答"，**绝不编造**
          return const CapabilityFailure(
            '用户没有回答（超时或关闭了提问）。'
            '请根据已有信息做出最合理的决定，并在最终回答里说明你假设了什么。',
            isRetryable: false,
          );
        }
        return CapabilitySuccess('用户回答：\n$answer');
      },
    ),

    // ----------------------------------------------------------- 长期记忆
    f.build(
      name: 'save_memory',
      description: '把一条**跨会话有用**的信息记进长期记忆。返回：写入确认或失败原因（含敏感内容拒收）。'
          '适合：项目约定（构建命令、代码风格）、用户偏好、踩过的坑。'
          '⚠️ 不适合记任务进度（那属于当前对话）；也不适合记一次性信息。',
      parameters: {
        'type': 'object',
        'properties': {
          'note': {
            'type': 'string',
            'description': '要记住的一句话。要具体、可复用，不要写"用户喜欢简洁"。',
          },
        },
        'required': ['note'],
      },
      isAvailable: () => memory != null,
      unavailableReason: '当前环境不支持长期记忆',
      run: (args) async {
        final note = requireString(args, 'note');
        if (note.trim().length < 4) {
          return const CapabilityFailure(
            '记忆内容太短，至少写一句完整的话',
            isRetryable: true,
          );
        }
        // ★ SEC4（2026-10-24）：疑似密钥/令牌拒绝入记忆 —— 记忆是明文文件
        //   且整段进 system prompt，存 Key = 每轮都把它送进上下文。
        final secret = _secretPattern.firstMatch(note);
        if (secret != null) {
          return const CapabilityFailure(
            '未执行：内容疑似包含密钥/令牌（API Key、token 类字符串）。'
            '长期记忆是明文存储且每轮进入上下文，绝不写入凭据。'
            '如需记录配置方式，请写"密钥存放在何处"而不是密钥本身。',
            isRetryable: false,
          );
        }
        return memory!.append(note);
      },
    ),
  ];
}

/// 读取长期记忆的渲染格式（由装配层在 system prompt 里注入）。
///
/// ## 谁在调它（2026-10-23 接通）
///
/// `HeraclesAgent._buildSystemPrompts()`。接通之前这个函数
/// **全仓 0 处调用** —— 记忆只能靠 `save_memory` 写进去，却从来没被读出来
/// 进上下文 ⇒ 换一个会话就"失忆"，写了等于没写。
///
/// ## 为什么带一段行为约束（不是光贴原文）
///
/// 光贴原文有两个真实风险：
///
/// 1. **模型会把记忆当回答复述给用户**（"我记得你之前说过…"），
///    用户会觉得莫名其妙 —— 他要的是干活，不是听你背笔记。
/// 2. **记忆是旧的**，当前对话可能已经推翻了它（比如构建命令改过）。
///    此时若盲信记忆，就会按过时的约定办事。
///
/// 所以标题里点明"越早越旧"，并明确"冲突时以当前对话为准"。
///
/// ## 为什么只说一句、不写成手册
///
/// 与 `system_prompt.dart` 的原则一致：**给事实，不给教练**。
/// 这里只交代两件模型自己无法从环境推断的事（要不要复述、冲突听谁的），
/// 其余交给它自己判断。
String renderMemory(String raw) {
  if (raw.trim().isEmpty) return '';
  return '\n\n## 长期记忆（跨会话沉淀，越早越旧）\n'
      '$raw\n'
      '\n'
      '记忆是**事实沉淀**，不用复述给用户看，只在需要时使用；'
      '若与当前对话冲突，**以当前对话为准**。';
}
