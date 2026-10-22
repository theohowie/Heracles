package dev.heracles.workspace

import java.nio.file.Files
import java.nio.file.Path

/**
 * 路径越界防护 —— **安全关键组件**。
 *
 * ## 为什么必须有
 *
 * agent 会从**模型输出**里拿到文件路径。模型可能：
 * - 被用户诱导（"把 ../ 删掉"）
 * - 自己编造（`../../etc/passwd`）
 * - 被注入的 Skill / MCP 工具内容污染
 *
 * **一旦路径逃出工作区，agent 就能读写整个文件系统。**
 * 这是本地沙箱（`00-需求文档.md` §2.13.1）的第一道也是最重要的一道防线。
 *
 * ## 防护的三类攻击
 *
 * | 攻击 | 例子 | 防护 |
 * |---|---|---|
 * | 相对路径穿越 | `../../etc/passwd` | 规范化后**必须**仍在工作区内 |
 * | 绝对路径 | `/data/data/other.app/` | 一律拒绝绝对路径 |
 * | 符号链接逃逸 | `link -> /etc` 然后 `link/passwd` | 规范化时解析链接，再校验 |
 *
 * ## 与权限三档的关系
 *
 * `00-需求文档.md` §2.13.2 要求三档权限。**本防护不属于任何档位** ——
 * 即使"完全访问"档，也**不允许**逃出工作区。
 * 权限档位控制的是"要不要用户确认"，不是"能不能越界"。
 */
object PathGuard {

    /**
     * 把用户/模型给的相对路径，解析为工作区内的绝对路径。
     *
     * @param workspaceRoot 工作区根（绝对路径）
     * @param requested 可能是任意字符串
     * @return 解析后的绝对路径
     * @throws PathEscapeException 越界时抛出
     */
    fun resolve(workspaceRoot: Path, requested: String): Path {
        val root = workspaceRoot.toAbsolutePath().normalize()

        // ★★ 先确认工作区根**还在**（2026-10-20 真机修）★★
        //
        // ## 修的是什么
        //
        // 工作区目录被外部删除后，用户看到的错误是：
        //   `路径被拒绝（符号链接指向工作区外：/storage/emulated/0/Android/data/…/files）`
        // —— 那是**误报**：没有任何符号链接问题，真实原因是**工作区根不存在**。
        //
        // 根因就在下面的 `resolveSymlinksSafely`：它"向上找到最近的已存在祖先再解析"，
        // 而根被删掉时，那个祖先会一路落到**根之外**（如 `…/files`），
        // 于是 `real` 当然不以 `root` 开头 ⇒ 抛出"符号链接指向工作区外"。
        // 这个判定对本意（防 `link -> /etc`）是对的，但**用错了场景**。
        //
        // ⇒ 根不存在时，先说清是"工作区没了"，别让用户去怀疑符号链接。
        //   这也是用户明确要求的口径：「此时输出：xxx 工作区已失效」。
        if (!Files.exists(root)) {
            throw PathEscapeException(requested, "工作区已失效：它指向的文件夹不存在")
        }

        val cleaned = requested.trim()
        if (cleaned.isEmpty()) {
            throw PathEscapeException(requested, "路径为空")
        }
        // 绝对路径一律拒绝 —— 即使它"碰巧"在工作区内，
        // 允许绝对路径会让防护依赖"字符串是否以 root 开头"这种脆弱的判断。
        if (cleaned.startsWith("/") || cleaned.startsWith("\\") ||
            Regex("^[A-Za-z]:").containsMatchIn(cleaned)
        ) {
            throw PathEscapeException(requested, "不允许绝对路径")
        }
        // 显式的父目录引用直接拒绝（比"规范化后再比"更早、更清楚）
        if (cleaned.split('/', '\\').any { it == ".." }) {
            throw PathEscapeException(requested, "路径包含 .. —— 不允许向上穿越")
        }

        val candidate = root.resolve(cleaned).normalize()

        // 规范化后必须仍在 root 之下（含 root 本身）
        if (!candidate.startsWith(root)) {
            throw PathEscapeException(requested, "路径逃出工作区：$candidate")
        }

        // 符号链接解析后再验一次 —— 防止 link -> /etc 这类逃逸
        resolveSymlinksSafely(candidate).let { real ->
            if (!real.startsWith(root)) {
                throw PathEscapeException(requested, "符号链接指向工作区外：$real")
            }
        }

        return candidate
    }

    /**
     * 解析已存在的路径上的符号链接。
     *
     * 目标可能尚不存在（新建文件），此时向上找到最近的已存在祖先再解析 ——
     * 这是 `Files.toRealPath` 报 `NoSuchFileException` 的标准绕法。
     */
    private fun resolveSymlinksSafely(path: Path): Path {
        var p: Path? = path
        while (p != null && !Files.exists(p)) {
            p = p.parent
        }
        return if (p == null) path else p.toRealPath()
    }
}

/** 路径越界。**必须**被上层捕获并转换为用户可见的拒绝，不得静默忽略。 */
class PathEscapeException(
    val requested: String,
    val reason: String,
) : SecurityException("路径被拒绝（$reason）：$requested")
