/// 侧边栏的视图选项 —— 对应「视图选项」菜单（2026-10-10）。
///
/// ## 为什么做成独立模型而不是几个 bool
///
/// 三组选项是**互斥单选**（分组方式三选一、排序两选一、筛选三选一），
/// 用枚举能在类型层面排除"同时选了两个分组方式"这种非法状态。
///
/// 而且它们要**持久化** —— 用户选过"单列表"就不该每次重启都变回去。
library;

/// 分组方式
enum SessionGrouping {
  /// 按工作区分组（每个工作区一个可折叠的组）—— 默认
  byWorkspace('按工作区'),

  /// 单列表（所有会话平铺，不分组）
  flatList('单列表');

  const SessionGrouping(this.label);
  final String label;

  static SessionGrouping fromName(String? n) =>
      values.firstWhere((e) => e.name == n, orElse: () => byWorkspace);
}

/// 排序方式
enum SessionSorting {
  /// 最近更新（默认 —— 最常用的排最前）
  recent('最近更新');

  const SessionSorting(this.label);
  final String label;

  static SessionSorting fromName(String? n) =>
      values.firstWhere((e) => e.name == n, orElse: () => recent);
}

/// 会话筛选
enum SessionFilter {
  /// 隐藏已归档
  hideArchived('隐藏已归档'),

  /// 全部对话（显示已归档）
  all('全部对话'),

  /// 仅显示已归档
  onlyArchived('仅显示已归档');

  const SessionFilter(this.label);
  final String label;

  static SessionFilter fromName(String? n) =>
      values.firstWhere((e) => e.name == n, orElse: () => hideArchived);
}

/// 视图选项的组合
///
/// ## 持久化
///
/// 用 [toJson] / [fromJson] 存进 `shared_preferences`。
/// **用户选过「单列表」不该每次重启都变回去** —— 这是常识性的期待。
class ViewOptions {
  const ViewOptions({
    this.grouping = SessionGrouping.byWorkspace,
    this.sorting = SessionSorting.recent,
    this.filter = SessionFilter.hideArchived,
  });

  final SessionGrouping grouping;
  final SessionSorting sorting;
  final SessionFilter filter;

  ViewOptions copyWith({
    SessionGrouping? grouping,
    SessionSorting? sorting,
    SessionFilter? filter,
  }) =>
      ViewOptions(
        grouping: grouping ?? this.grouping,
        sorting: sorting ?? this.sorting,
        filter: filter ?? this.filter,
      );

  Map<String, dynamic> toJson() => {
        'grouping': grouping.name,
        'sorting': sorting.name,
        'filter': filter.name,
      };

  /// 从存储恢复。
  ///
  /// **任何字段缺失或非法都回退到默认** —— 不能因为一条脏数据
  /// 让整个侧边栏打不开。
  factory ViewOptions.fromJson(Map<String, dynamic>? m) {
    if (m == null) return const ViewOptions();
    return ViewOptions(
      grouping: SessionGrouping.fromName(m['grouping'] as String?),
      sorting: SessionSorting.fromName(m['sorting'] as String?),
      filter: SessionFilter.fromName(m['filter'] as String?),
    );
  }

  /// 判断某个会话是否应当显示
  bool shows(bool? archived) => switch (filter) {
        SessionFilter.hideArchived => archived != true,
        SessionFilter.all => true,
        SessionFilter.onlyArchived => archived == true,
      };
}
