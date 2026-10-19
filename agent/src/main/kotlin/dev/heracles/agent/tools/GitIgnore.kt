package dev.heracles.agent.tools

/**
 * **工作区根 `.gitignore` 的最小解析器**（2026-10-19）。
 *
 * ## 为什么需要
 *
 * `find_files` / `grep_files` 目前只有一份**固定忽略目录**（`.git` / `build` / `node_modules` …）。
 * 真实项目自己的产物目录（`app/build`、`dist`、`*.log`、`local.properties`）
 * 不在那份名单里 —— 搜索会把它们全扫进来，白烧 token，还可能把构建产物误当成源码。
 *
 * ## 刻意只做"根目录 + 常见子集"
 *
 * | 支持 | 语义 |
 * |---|---|
 * | `# 注释` / 空行 | 忽略 |
 * | `name` | 任意层级同名文件/目录（= basename 匹配） |
 * | `*.log` / `?.tmp` | 段内通配（`*` 不跨目录） |
 * | `build/` | **只匹配目录**（文件叫 build 不忽略） |
 * | `/dist` 或 `src/gen` | 带 `/` ⇒ 从工作区根按路径匹配 |
 * | `**` | 任意层目录 |
 * | `!keep.log` | 反选（**后出现的规则覆盖先出现的**，与 git 一致） |
 *
 * **不做**：嵌套 `.gitignore`、`[abc]` / `{a,b}`、`\` 转义、`**` + 斜杠开头的边角语义。
 * 这些会当字面量/按上面子集解释（最坏 = 少忽略几个文件，**不会误删/误读**）。
 *
 * ## 为什么忽略失败不影响搜索
 *
 * `.gitignore` 读不到/编码坏 ⇒ 返回 [EMPTY]（不抛）。忽略规则是**优化**，
 * 不是正确性前提；因为它让整个搜索失败是本末倒置。
 */
internal class GitIgnore private constructor(private val rules: List<Rule>) {

    private class Rule(
        val pattern: String,
        val negated: Boolean,
        val dirOnly: Boolean,
        /** 以 `/` 开头 ⇒ 从根匹配 */
        val anchored: Boolean,
    )

    fun isEmpty(): Boolean = rules.isEmpty()

    /**
     * @param relativePath 工作区相对路径（`a/b/c.txt`）
     * @param isDirectory 目录要用**目录自身**的路径判断（我们会在遍历时跳过整棵）
     */
    fun isIgnored(relativePath: String, isDirectory: Boolean): Boolean {
        if (rules.isEmpty()) return false
        val path = relativePath.trim().trim('/')
        if (path.isEmpty()) return false
        var ignored = false
        for (rule in rules) {
            if (rule.dirOnly && !isDirectory) continue
            if (matches(rule, path)) ignored = !rule.negated
        }
        return ignored
    }

    private fun matches(rule: Rule, path: String): Boolean {
        // 带 `/`（或显式锚定）⇒ 按完整路径匹配；否则按 basename（任意深度）
        if (rule.anchored || rule.pattern.contains('/')) {
            return globMatch(rule.pattern, path)
        }
        return globMatch(rule.pattern, path.substringAfterLast('/'))
    }

    companion object {
        /** 空规则（读不到 .gitignore 时的唯一值，行为 = 与加本功能之前一致）。 */
        val EMPTY = GitIgnore(emptyList())

        /** 解析 `.gitignore` 文本。**任何异常都不抛** —— 解析失败的规则直接跳过。 */
        fun parse(text: String): GitIgnore {
            val rules = mutableListOf<Rule>()
            for (rawLine in text.lineSequence()) {
                var line = rawLine.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                // 行尾空格在 git 里有转义语义；这里直接裁掉（子集实现，不会误忽略）
                line = line.trimEnd()
                var negated = false
                if (line.startsWith("!")) {
                    negated = true
                    line = line.substring(1)
                }
                var dirOnly = false
                if (line.endsWith("/")) {
                    dirOnly = true
                    line = line.dropLast(1)
                }
                var anchored = false
                if (line.startsWith("/")) {
                    anchored = true
                    line = line.substring(1)
                }
                line = line.trim()
                if (line.isEmpty()) continue
                rules += Rule(line, negated, dirOnly, anchored)
            }
            return GitIgnore(rules)
        }

        /**
         * 逐段 glob：`**` 匹配零或多段，`*`/`?` 只在段内生效。
         * 段内用正则（字符转义过），避免自己手写通配回溯出错。
         */
        private fun globMatch(pattern: String, path: String): Boolean {
            val p = pattern.split('/').filter { it.isNotEmpty() }
            val s = path.split('/').filter { it.isNotEmpty() }
            if (p.isEmpty()) return false

            fun rec(pi: Int, si: Int): Boolean {
                if (pi == p.size) return si == s.size
                if (p[pi] == "**") {
                    for (k in si..s.size) {
                        if (rec(pi + 1, k)) return true
                    }
                    return false
                }
                if (si >= s.size) return false
                if (!segmentMatch(p[pi], s[si])) return false
                return rec(pi + 1, si + 1)
            }
            return rec(0, 0)
        }

        private fun segmentMatch(pattern: String, segment: String): Boolean {
            val sb = StringBuilder("^")
            for (ch in pattern) {
                when (ch) {
                    '*' -> sb.append(".*")
                    '?' -> sb.append('.')
                    else -> sb.append(java.util.regex.Pattern.quote(ch.toString()))
                }
            }
            sb.append('$')
            return Regex(sb.toString()).matches(segment)
        }
    }
}
