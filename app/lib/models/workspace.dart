/// 工作区与会话模型 —— 对应「电脑上 Agent 的项目结构」。
///
/// ## 概念层级（与桌面版 Agent 一致）
///
/// ```
/// 工作区（Workspace）= 一个项目文件夹
///   └── 会话（Session）= 该文件夹下的一次对话
///         └── 消息 / 工具调用
/// ```
///
/// **一个工作区可以有多个会话**，会话之间互不干扰
/// （对应 `09-决策记录.md` ADR-015：切换上下文必须开启新会话）。
library;

/// 一个会话（一次对话）。
class HSession {
  const HSession({
    required this.id,
    required this.title,
    this.lastActivity,
    this.starred = false,
    this.archived = false,
    this.active = false,
  });

  final String id;

  /// 会话标题。通常由第一次请求自动生成
  final String title;

  /// 最后活动时间 —— UI 显示相对时间（"21分钟"）
  final DateTime? lastActivity;

  /// 收藏（桌面版的 ⭐）
  final bool starred;

  /// 已归档（AI 编程工具的常见概念：不再活跃但保留）
  final bool archived;

  /// 当前选中
  final bool active;

  HSession copyWith({
    String? title,
    bool? starred,
    bool? archived,
    bool? active,
  }) =>
      HSession(
        id: id,
        title: title ?? this.title,
        lastActivity: lastActivity,
        starred: starred ?? this.starred,
        archived: archived ?? this.archived,
        active: active ?? this.active,
      );

  /// 从 Kotlin 侧返回的 Map 构造。
  ///
  /// Kotlin 用 `updatedAt`（毫秒时间戳），0 表示从未活动。
  factory HSession.fromMap(Map<String, dynamic> m) {
    final ts = (m['updatedAt'] as num?)?.toInt() ?? 0;
    return HSession(
      id: (m['id'] as String?) ?? '',
      title: (m['title'] as String?) ?? '新会话',
      lastActivity: ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
      starred: (m['starred'] as bool?) ?? false,
      archived: (m['archived'] as bool?) ?? false,
    );
  }

  /// 相对时间文案。
  ///
  /// 手机上没有鼠标悬浮，时间信息必须**直接可读**，
  /// 不能依赖 tooltip。
  String get relativeTime {
    final t = lastActivity;
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes}分钟';
    if (d.inHours < 24) return '${d.inHours}小时';
    if (d.inDays < 30) return '${d.inDays}天';
    return '${(d.inDays / 30).floor()}个月';
  }
}

/// 一个工作区（项目文件夹）。
class HWorkspace {
  const HWorkspace({
    required this.id,
    required this.name,
    required this.path,
    this.sessions = const [],
    this.expanded = false,
    this.writable = true,
    this.treeUri = '',
    this.exists = true,
  });

  final String id;

  /// 显示名（默认取文件夹名）
  final String name;

  /// 手机上的绝对路径
  final String path;

  final List<HSession> sessions;

  /// 是否展开显示会话列表
  final bool expanded;

  /// **POSIX 级可写**（2026-10-10 新增）。
  ///
  /// 分区存储下，SAF 授权给的是 `content://` 权限 ——
  /// 应用进程对真实路径**可能仍然没有 write 权限**。
  /// Kotlin 侧在选中时探测一次，把结论如实告诉用户。
  ///
  /// 不可写时 UI 必须**明确警告** —— 否则用户选完、发消息，
  /// 才看到「写入失败」，那时已经太晚。
  final bool writable;

  /// SAF 的 tree URI（2026-10-10）。
  ///
  /// 分区存储下**必须**靠它才能读写 —— 用户目录属 media_rw 组，
  /// 我们的 App 不在组里，java.io.File 写不了。
  /// 空字符串表示走 POSIX（应用私有目录 / 已获全盘权限）。
  final String treeUri;

  /// **工作区指向的文件夹是否还在**（2026-10-20）。
  ///
  /// ## 为什么要有它
  ///
  /// 用户在文件管理器里把工作区文件夹删掉后，原来那条 `listWorkspaces` 会
  /// **静默跳过**这类记录 ⇒ 侧边栏里工作区**凭空消失**，而且用户既看不到、
  /// 也没法把它移除（记录还留在 prefs 里）。
  ///
  /// ⇒ Kotlin 侧现在保留记录并标 `exists=false`，UI 显示成**失效状态**：
  ///   看得见、点它会被明确告知"工作区已失效"、也能从菜单移除。
  ///   **看得见的坏状态，好过看不见的坏状态。**
  final bool exists;

  /// 是否走 SAF 路径
  bool get isSaf => treeUri.isNotEmpty;

  /// 会话数（折叠时显示）
  int get sessionCount => sessions.length;

  HWorkspace copyWith({
    String? name,
    List<HSession>? sessions,
    bool? expanded,
    bool? writable,
    String? treeUri,
    bool? exists,
  }) =>
      HWorkspace(
        id: id,
        name: name ?? this.name,
        path: path,
        sessions: sessions ?? this.sessions,
        expanded: expanded ?? this.expanded,
        writable: writable ?? this.writable,
        treeUri: treeUri ?? this.treeUri,
        exists: exists ?? this.exists,
      );
}

/// 侧边栏里的一条"功能入口"（插件 / 自动化任务 / 上下文洞察）。
class HDrawerEntry {
  const HDrawerEntry({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final int icon;
}
