/// **工具定义层** —— 把能力层包装成 `dart_agent_core` 的 [Tool]。
///
/// ## 核心原则：工具是**薄壳**
///
/// 每个工具只做三件事：
/// 1. 声明 JSON Schema（给模型看）
/// 2. 从 `Map<String, dynamic>` 取参数（**类型化取值，不手工解引号**）
/// 3. 调能力层，把 [CapabilityResult] 翻译成模型读得懂的文字
///
/// **业务逻辑不在这一层**。文件怎么读写、APK 怎么构建，都是 [Capabilities] 的事。
///
/// ## 为什么参数是 `Map<String, dynamic>`
///
/// `dart_agent_core` 的 `ToolParameterMode.object` 直接把解码后的 Map 交给我们，
/// **`int` 就是 `int`、`bool` 就是 `bool`**。旧 Kotlin 实现用 `Map<String, String>`
/// 导致"参数值带引号"的 bug（`read_file` 拿到的路径是 `"a.txt"` 而不是 `a.txt`），
/// 模型重试 20 轮都失败。这里从类型上就不可能犯那个错。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../capability/capabilities.dart';

/// 工具构建器 —— 统一处理"能力缺失"和"结果翻译"。
class ToolFactory {
  const ToolFactory(this.caps);

  final Capabilities caps;

  /// 造一个工具。
  ///
  /// [requiredCapability] 名字用于错误信息；对应能力为 `null` 时返回的工具
  /// **一调用就失败**，但**仍会出现在 tools 列表里**。
  ///
  /// ## 为什么"缺能力也让工具可见"
  ///
  /// 两种设计的对比：
  /// - **不列出来**：模型不知道有这个工具，但它从上下文/历史里看到过，
  ///   会尝试"凭记忆"调用一个不存在的工具 ⇒ 报"未知工具"，更难排查
  /// - **列出来但调用即失败**：模型看到明确的"当前环境不支持 X"，
  ///   可以换路（比如改用 shell），且用户能看到原因
  ///
  /// 选后者。失败原因必须写清楚是"环境不支持"而不是"参数错"。
  Tool build({
    required String name,
    required String description,
    required Map<String, dynamic> parameters,
    required bool Function() isAvailable,
    required String unavailableReason,
    required Future<CapabilityResult> Function(Map<String, dynamic> args) run,
  }) {
    return Tool(
      name: name,
      description: description,
      parameters: parameters,
      parameterMode: ToolParameterMode.object,
      // ★ **失败必须被框架认成失败**（2026-10-22 修假信息）★
      //
      // ## 踩到的真 bug
      //
      // `_translate` 把 `CapabilityFailure` 变成一句普通字符串
      // （`'失败（这条路不通，不要重试）：不是文件'`）。这对**模型**是对的
      // （它读得懂人话），但框架只看到"工具正常返回了一个字符串" ⇒
      // 它给 `FunctionExecutionResult.isError` 打 **false**。
      //
      // 后果：UI 工具卡片按 `isError` 上色 ⇒ **失败的工具画成绿色成功卡**。
      // 这正是 `AgentTurn` 的 KDoc 里记的 H-1 那类"比失败更糟的假信息"：
      // 用户以为命令跑成功了，而它根本没执行。
      //
      // 框架为此提供了 `resultIsError` 钩子（见 `Tool` 的 KDoc：
      // "Optionally classifies a successfully returned value as a tool error"），
      // 正是给"保留旧返回类型 + 用哨兵值表示失败"这种形状用的。这里就用它：
      // **返回值仍是那句人话**（模型读的东西不变），但框架能正确判定 isError。
      resultIsError: _looksLikeFailure,
      executable: (Map<String, dynamic> args) async {
        if (!isAvailable()) {
          return _fail(unavailableReason);
        }
        // ★ 本地 schema 校验（2026-10-24，H2/T3）：执行前把参数按声明校一遍
        //   —— 未知字段 / 类型不符在这里就挡下并给模型可读的错，
        //   不让垃圾进能力层。（重复键在这一层测不到：参数已是解码后的
        //   Map，provider/框架解码时后者覆盖前者 —— 如实记为已知边界。）
        try {
          _validateAgainstSchema(name, args, parameters);
        } catch (e) {
          return _fail(_humanize(e));
        }
        try {
          final result = await run(args);
          return _translate(result);
        } catch (e) {
          // 能力实现抛了异常 ⇒ 变成模型能读的失败，不让它看到堆栈
          return _fail('工具执行出错：${_humanize(e)}');
        }
      },
    );
  }

  /// **按工具声明的 JSON Schema 校验参数**（2026-10-24，H2/T3 的落地）。
  ///
  /// 查三层：
  /// 1. **未知字段** —— schema `properties` 之外的键直接拒绝（拼错字段名
  ///    是模型最常见的错，静默忽略会让它以为生效了）；
  /// 2. **类型** —— 声明 `integer` 收到 `string` 等一律拒绝
  ///    （工具内的 `requireX` 助手仍保留：它们报错更贴近具体参数语义）；
  /// 3. **范围** —— schema 里声明了 `minimum` / `maximum` 就按它查
  ///    （工具逐个补声明，声明了的自动受保护）。
  ///
  /// 只做**顶层**校验：嵌套对象（ask_user 的 questions）由工具内部自己查 ——
  /// 它们的结构是业务语义，schema 表达 nested 校验的复杂度不值得。
  void _validateAgainstSchema(
    String toolName,
    Map<String, dynamic> args,
    Map<String, dynamic> schema,
  ) {
    final props = schema['properties'];
    if (props is! Map) return; // 没声明 properties ⇒ 无从校验，放行
    for (final key in args.keys) {
      final spec = props[key];
      if (spec is! Map) {
        throw ArgumentError(
          '工具 `$toolName` 不认识参数 `$key`。可用参数：'
          '${props.keys.join("、")}（不要编造参数名）',
        );
      }
      final value = args[key];
      if (value == null) continue; // 显式 null 按缺省处理
      final type = spec['type'];
      final mismatch = switch (type) {
        'string' => value is! String,
        'integer' => value is! int && !(value is double && value == value.truncateToDouble()),
        'number' => value is! num,
        'boolean' => value is! bool,
        'array' => value is! List,
        'object' => value is! Map,
        _ => false, // 未声明类型 ⇒ 不猜
      };
      if (mismatch) {
        throw ArgumentError(
          '工具 `$toolName` 的参数 `$key` 应是 `$type`，收到 ${value.runtimeType}',
        );
      }
      final min = (spec['minimum'] as num?)?.toInt();
      final max = (spec['maximum'] as num?)?.toInt();
      if (value is num) {
        if (min != null && value < min) {
          throw ArgumentError('工具 `$toolName` 的参数 `$key` 最小 $min，收到 $value');
        }
        if (max != null && value > max) {
          throw ArgumentError('工具 `$toolName` 的参数 `$key` 最大 $max，收到 $value');
        }
      }
    }
  }

  /// 判断返回值是不是"失败/未执行"。
  ///
  /// ⚠️ **只认我们自己写的前缀**，不猜内容。`_translate` 与 `_fail` 产出的
  /// 失败文本都以 `失败（` / `未执行：` / `需要用户批准` 开头 ——
  /// 这三个前缀是本类**唯一**的失败出口，所以判定是完备的。
  ///
  /// 为什么不用"返回值里含'失败'二字"：工具的正常输出里完全可能出现
  /// "失败"（比如 `grep` 到的源码、`run_shell_command` 的日志）。
  /// 按前缀判定才不会把成功误判成失败 —— **误判成功是假信息，
  /// 误判失败是噪音**，两者都要避免，但前者更糟。
  static bool _looksLikeFailure(dynamic result) {
    if (result is! String) return false;
    return result.startsWith('失败（') ||
        result.startsWith('未执行：') ||
        result.startsWith('需要用户批准');
  }

  /// 把 [CapabilityResult] 翻译成模型看到的文本。
  ///
  /// ⚠️ **成功时原样返回 `data`**，不加 JSON 信封。
  /// 旧实现要求模型用 `{"final":...}` 格式回答，导致"输出无法解析"熔断；
  /// 这里工具结果就是人话，模型直接读。
  dynamic _translate(CapabilityResult r) {
    return switch (r) {
      CapabilitySuccess(:final data) => data,
      CapabilityFailure(:final reason, :final isRetryable) => isRetryable
          ? '失败（可换个方式重试）：$reason'
          : '失败（这条路不通，不要重试）：$reason',
      CapabilityNeedsApproval(:final detail) => '需要用户批准才能执行：$detail',
    };
  }

  dynamic _fail(String reason) => '未执行：$reason';

  /// 把异常变成一句人话（不暴露堆栈给模型）。
  String _humanize(Object e) {
    final s = e.toString();
    // 常见异常去掉类型前缀，留下有用信息
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }
}

// ============================================================================
// 参数取值助手 —— 类型安全，绝不手工解引号
// ============================================================================

/// 必填字符串。
///
/// 缺失或类型不对时**抛出 `ArgumentError`**，由 `dart_agent_core` 转成
/// "工具参数错误"回给模型 —— 模型看到"缺少参数 path"能自己改对。
/// 这正是我们要的：**报具体错，让它自愈**，而不是正则修补。
String requireString(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v is String) return v;
  if (v == null) {
    throw ArgumentError('缺少必填参数 `$key`（字符串）。收到的参数：${args.keys.join(", ")}');
  }
  throw ArgumentError('参数 `$key` 应是字符串，收到 ${v.runtimeType}');
}

/// 可选字符串。
String? optionalString(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is String) return v;
  // 模型偶尔把数字写成字符串之外的类型 —— 这里明确报错，不静默转
  throw ArgumentError('参数 `$key` 应是字符串，收到 ${v.runtimeType}');
}

/// 可选整数（**接受 int，不接受 "80" 这样的字符串**）。
///
/// 为什么不宽容：`"80"` 说明模型填错了类型。宽容会让它一直错下去；
/// 明确的"期望整数，收到字符串"它一轮就能改对。
int? optionalInt(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is double && v == v.truncateToDouble()) return v.toInt();
  throw ArgumentError('参数 `$key` 应是整数，收到 ${v.runtimeType}（值：$v）');
}

/// 可选布尔。
bool? optionalBool(Map<String, dynamic> args, String key) {
  final v = args[key];
  if (v == null) return null;
  if (v is bool) return v;
  throw ArgumentError('参数 `$key` 应是布尔值，收到 ${v.runtimeType}（值：$v）');
}

/// **"先读再改"追踪器**（2026-10-24，K1 的工具层强制 —— Claude Code
/// FileEditTool 的形态："把正确用法从靠 LLM 自觉变成靠工具强制"）。
///
/// ## 规则
///
/// · `edit` / `apply_patch`：目标路径必须**被读过**或**被本会话写过**；
/// · `write_file`：目标文件**已存在**时同上；新文件随便写；
/// · `read_file` 成功 ⇒ 记入已读；写成功 ⇒ 同时记入已读+已写
///   （自己写的内容就是"知道的"，不必再读一遍）；
/// · `delete_path` ⇒ 忘掉该路径；`move_path` ⇒ 迁移记录。
///
/// ## 边界（如实记录）
///
/// · 只认**路径字符串**：同一文件经不同相对写法（`a/../b.dart`）进来
///   会被当成两个路径 —— 能力层反正会归一化拒绝越界，这里从宽；
/// · 无 mtime 防陈旧：读之后文件被外部改动，本层不察觉
///   （Claude Code 有 stale 检查，v1 不做，记为已知边界）；
/// · 子代理与主线程**共享**同一个 tracker（工具对象相同）：
///   worker 读过的文件主线程也算读过 —— 从宽取向，避免重复读浪费。
class EditReadTracker {
  final _read = <String>{};
  final _written = <String>{};

  void markRead(String path) => _read.add(path);

  void markWritten(String path) {
    _read.add(path);
    _written.add(path);
  }

  void forget(String path) {
    _read.remove(path);
    _written.remove(path);
  }

  void moved(String from, String to) {
    if (_read.remove(from)) _read.add(to);
    if (_written.remove(from)) _written.add(to);
  }

  /// edit/apply_patch/write(已存在) 的准入判定。
  bool canEdit(String path) => _read.contains(path) || _written.contains(path);

  /// 该文件是否被本会话写过（= 内容已知，无需再读）。
  bool wasWrittenByUs(String path) => _written.contains(path);
}
