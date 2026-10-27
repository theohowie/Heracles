# VENDOR.md — 这个目录是 vendored 的第三方代码

**不要把它当成 Heracles 自己的代码来读。** 它是上游框架裁剪后的副本。

| 项 | 值 |
|---|---|
| 上游 | https://github.com/memex-lab/dart_agent_core |
| 内联日期 | 2026-10-27 |
| 内联时 HEAD | `09c88ef` — `fix: account for Claude cached tokens and release 2.1.8` |
| 版本 | `2.1.8` |
| 行数 | `lib/` 17,214 行 Dart |
| 许可 | MIT（版权归 Memex Lab）—— 声明见仓库根 `THIRD_PARTY_NOTICES.md` |

## 保留了哪些、删掉了哪些

**保留**（Heracles 实际会用到的）：

- `lib/` —— 全部源码，一行没删（后端几乎每一层都依赖它）
- `test/` —— 上游测试，改框架时用来验证没把别人的东西改坏
- `pubspec.yaml` / `pubspec.lock` / `analysis_options.yaml`

**删掉**（对运行没有影响，需要时从上游取）：

- `example/` `doc/` `bin/` —— 示例、文档、CLI 工具
- `README.md` `README.zh-CN.md` `CHANGELOG.md` `AGENTS.md` —— 上游说明文件
- `LICENSE` —— 许可证正文统一收在仓库根 `THIRD_PARTY_NOTICES.md`
- `.git` `.github` —— VCS 与 CI 元数据（所以这里**不能** `git pull`）

## 为什么内联

这个包原来是 hosted 依赖，改不动；而 Heracles 需要改的挂载点全在它里面：
`state.systemReminders` 的注入时机、`ToolResultHookResult.injectedMessages`、
工具的流式输出、并行工具的调度策略。走 fork 也行，但每次上游发版都要手动合一次。

## 许可证边界（重要）

本仓库整体是 **GPL-3.0**，这个目录是 **MIT**。两者兼容，但 **MIT 要求保留版权声明**：

- 不要删除仓库根目录的 `THIRD_PARTY_NOTICES.md`；
- 在本目录内修改文件时，在文件头加一行 `// vendored: modified by Heracles`，
  将来升级时 `git diff` 才认得出哪些是我们改的、哪些是上游的。

## 怎么升级上游

这里**没有 `.git`**，不能 `git pull`：

```bash
# 1) 在仓库外重新克隆（本机 github.com 走代理不通时用镜像）
git clone https://ghproxy.net/https://github.com/memex-lab/dart_agent_core.git /tmp/dac

# 2) 看新版改了什么
cd /tmp/dac && git log --oneline 09c88ef..HEAD

# 3) 先看我们的改动会不会被覆盖
diff -r --strip-trailing-cr /tmp/dac/lib D:/AllCode/Agent/Heracles/core/lib

# 4) 覆盖后重跑
cd D:/AllCode/Agent/Heracles/backend && dart pub get && dart test
```

⚠️ 上游**不打 git tag**，版本只能按 commit 钉。

## 这里改了哪些文件

每次修改请往下追加一行，否则下次升级无从对比。

| 日期 | 文件 | 改了什么 |
|---|---|---|
| 2026-10-27 | — | 内联，与 `09c88ef` 一致，未改代码 |
