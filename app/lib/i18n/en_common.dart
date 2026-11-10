/// 通用英文词条（按钮 / 状态 / 单位 / 跨模块文案）。
///
/// 归属：国际化基础设施。区域词条请写 `en_screens.dart`（screens）或
/// `en_widgets.dart`（widgets），不要往这里堆。
///
/// 规则：
/// - **key = 代码里的中文原文，逐字一致**（含全角标点、空格）。
/// - value 简短、祈使句；技术名词保留原样（MCP / JSONL / token / diff…）。
library;

Map<String, String> get enCommon => const <String, String>{
      // ---- 通用动作 ----
      '取消': 'Cancel',
      '确定': 'OK',
      '保存': 'Save',
      '保存中': 'Saving',
      '已保存': 'Saved',
      '删除': 'Delete',
      '编辑': 'Edit',
      '关闭': 'Close',
      '完成': 'Done',
      '返回': 'Back',
      '重试': 'Retry',
      '刷新': 'Refresh',
      '复制': 'Copy',
      '已复制': 'Copied',
      '粘贴': 'Paste',
      '清空': 'Clear',
      '新建': 'New',
      '添加': 'Add',
      '移除': 'Remove',
      '导入': 'Import',
      '导出': 'Export',
      '搜索': 'Search',
      '全部': 'All',
      '更多': 'More',
      '展开': 'Expand',
      '收起': 'Collapse',

      // ---- 通用状态 ----
      '加载中…': 'Loading…',
      '加载中': 'Loading',
      '失败': 'Failed',
      '成功': 'Success',
      '未知': 'Unknown',
      '跳过': 'Skip',
      '待处理': 'Pending',
      '进行中': 'In progress',
      '已完成': 'Done',
      '已取消': 'Cancelled',
      '已拒绝': 'Denied',
      '已允许': 'Allowed',
      '正在生成…': 'Generating…',
      '停止': 'Stop',
      '继续': 'Continue',
      '允许一次': 'Allow once',
      '始终允许': 'Always allow',
      '拒绝': 'Deny',
      '退出码': 'Exit code',
      '退出码 未知': 'Exit code unknown',
      '就绪': 'Ready',
      '未设置': 'Not set',
      '未启用': 'Disabled',
      '已启用': 'Enabled',
      '未连接': 'Not connected',
      '已连接': 'Connected',
      '未安装': 'Not installed',
      '已安装': 'Installed',

      // ---- 通用占位 ----
      '请输入': 'Enter a value',
      '搜索…': 'Search…',
      '无': 'None',
      '暂无': 'Nothing yet',
      '（空）': '(empty)',

      // ---- 代码门禁/审批 ----
      '放行': 'Allow',
      '需确认': 'Needs approval',
      '需要你确认': 'Needs your approval',
      '这次放行': 'Allow this time',
      '本会话始终允许': 'Always allow in this session',

      // ---- 语言 ----
      '语言': 'Language',
      '中文': '中文',
      'English': 'English',
      '界面语言': 'App language',
    };
