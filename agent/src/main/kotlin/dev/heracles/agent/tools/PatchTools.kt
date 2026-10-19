package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.patch.ApplyResult
import dev.heracles.core.patch.UnifiedPatch
import dev.heracles.core.tool.ToolGroup
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs

/**
 * **补丁工具** —— `26-编码层工具链与逆向引擎.md` §4.3。
 *
 * ## 为什么需要它（不是有 `write_file` 就够了吗）
 *
 * 够，但代价高。`write_file` 是**整文件重写**：
 *
 * | | write_file 重写 | apply_patch |
 * |---|---|---|
 * | 输出 token | 整个文件（smali 动辄几百行） | 只有差异那几行 |
 * | 出错面 | 任何抄错的行都会**静默**改掉 | 上下文对不上就**整体失败** |
 * | 缓存 | 每轮都要重新生成全文 | 生成量小一个量级 |
 *
 * 逆向改包时（`smali` 改一行 `const/4 v0, 0x1` → `0x0`），
 * 整文件重写几乎必然抄错别的地方 —— 这是 `apply_patch` 存在的全部理由。
 *
 * ## 生成通道（ADR-019）
 *
 * 走**标签 + CDATA**：
 *
 * ```
 * <apply_patch path="smali/com/x/App.smali">
 * <![CDATA[
 * @@ -12,7 +12,6 @@
 * -    const/4 v0, 0x1
 * +    const/4 v0, 0x0
 * ]]>
 * </apply_patch>
 * ```
 *
 * 原因与 `write_file` 相同：diff 正文里必然含双引号与反斜杠，
 * 塞进 JSON 的 `str`（不允许转义）根本生成不出来。
 *
 * ## 原子性
 *
 * 修改块有任何一块匹配不上 → **整体失败**，文件**一个字节都不改**。
 * 判定与拼接全在 [UnifiedPatch]（纯函数，已穷举测试）。
 */
/**
 * **`edit`** —— old_string → new_string 的精确文本替换（2026-10-19）。
 *
 * ## 为什么在 `apply_patch` 之外还要它
 *
 * `apply_patch` 要求模型写 unified diff（带 `@@` 行号与上下文）。Codex / Cursor
 * 训练出来的模型更习惯 **`edit(old_string, new_string)`** 这种形状：
 * 一次改一处、不用算行号。两者服务同一件事，但**模型对哪种更熟**直接决定它改得对不对。
 *
 * ## 安全语义（照着成熟产品的规矩来）
 *
 * · `old_string` 必须在文件里**恰好出现一次**；出现多次 ⇒ **失败**并提示提供更多上下文
 *   （猜着改一处是最坏的结果：改错地方、还没人知道）
 * · `replace_all=true` 才允许批量替换
 * · 改之前存快照（与 `apply_patch` 相同），出错可用 `restore_path` 退回
 * · 匹配按**字面**（不解释正则）—— 代码里的 `.` / `(` 不该被当元字符
 */
class EditFileTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "edit",
        description = "把文件里的 old_string（原文，必须逐字符一致、含缩进）替换成 new_string。" +
            "默认要求 old_string 在文件中只出现一次；出现多次会失败（请提供更多上下文，或 replace_all=true）。" +
            "new_string 传空字符串 = 删除该段。比 write_file 重写整个文件更安全省 token；" +
            "用之前先 read_file 确认原文。",
        parameters = listOf(
            ToolParam("path", "string", "要修改的文件路径（必须已存在）"),
            ToolParam("old_string", "string", "要被替换的原文（逐字符一致，含缩进换行）"),
            ToolParam("new_string", "string", "替换后的文本；空字符串表示删除", allowEmpty = true),
            ToolParam(
                "replace_all", "string",
                "true = 替换所有出现处；默认 false（多处出现时报错）",
                allowEmpty = true, optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val path = args["path"].orEmpty().trim()
        val old = args["old_string"].orEmpty()
        val new = args["new_string"].orEmpty()
        val replaceAll = args["replace_all"].orEmpty().trim().lowercase() in setOf("true", "1", "yes")

        if (path.isBlank()) return ToolOutcome.Failure("path 为空")
        if (old.isEmpty()) {
            return ToolOutcome.Failure("old_string 不能为空（要删除整段请用 write_file / delete_path）")
        }

        val original = try {
            fs.readText(path)
        } catch (e: PathEscapeException) {
            return ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            return ToolOutcome.Failure("读取失败（文件可能存在但读不了）：${e.message}")
        }

        val count = countOccurrences(original, old)
        if (count == 0) {
            return ToolOutcome.Failure(
                "文件里没有找到 old_string（逐字符匹配，含缩进）。" +
                    "请先 read_file 再看一遍原文；不要把行号或省略号写进 old_string。",
            )
        }
        if (count > 1 && !replaceAll) {
            return ToolOutcome.Failure(
                "old_string 在文件里出现了 $count 次，无法确定改哪一处。" +
                    "请把上下文（前后若干行）一起放进 old_string，或传 replace_all=true 全部替换。",
            )
        }

        val updated = if (replaceAll) {
            original.replace(old, new)
        } else {
            val i = original.indexOf(old)
            original.substring(0, i) + new + original.substring(i + old.length)
        }
        if (updated == original) {
            return ToolOutcome.Success("文件内容未变化：$path（old_string 与 new_string 相同）")
        }

        return try {
            val snapshotted = Checkpoints.save(fs, path, original)
            val bytes = fs.writeText(path, updated)
            val snapNote = if (snapshotted) {
                "（原内容已存快照，可用 restore_path 撤销）"
            } else {
                "（原文件超过快照上限，**未保存快照**）"
            }
            ToolOutcome.Success(
                "已修改 $path：替换 $count 处，共 ${bytes} 字节\n\n" +
                    DiffReceipt.render(original, updated) + snapNote,
            )
        } catch (e: PathEscapeException) {
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("写回失败：${e.message}")
        }
    }

    /** 字面计数（不重叠；`old` 非空由调用方保证）。 */
    private fun countOccurrences(text: String, old: String): Int {
        var count = 0
        var from = 0
        while (true) {
            val i = text.indexOf(old, from)
            if (i < 0) return count
            count++
            from = i + old.length
        }
    }
}

/** 补丁类工具的分组表与装配入口（`search_tools` 用）。 */
object PatchTools {
    val GROUPS: Map<String, ToolGroup> = mapOf(
        "apply_patch" to ToolGroup.PATCH,
        "edit" to ToolGroup.PATCH,
    )

    fun create(fs: WorkspaceFs): List<AgentTool> = listOf(ApplyPatchTool(fs), EditFileTool(fs))
}

/**
 * **`apply_patch`** —— unified diff 补丁（原实现，2026-10-18 起常驻）。
 *
 * 保留原有 KDoc 语义：修改块有任何一块匹配不上 ⇒ 整体失败、文件一个字节都不改。
 */
class ApplyPatchTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "apply_patch",
        description = "用 unified diff 补丁精确修改一个已存在的文件（只改补丁涉及的几行，其余原样保留）。修改 smali、XML、配置文件里的小改动时用它，比 write_file 重写整个文件更省更准。用之前必须先用 read_file 看清当前内容。",
        parameters = listOf(
            ToolParam("path", "string", "要修改的文件路径（必须已存在）"),
            ToolParam(
                "patch", "string",
                "补丁内容：以 @@ -旧起点,旧行数 +新起点,新行数 @@ 开头的修改块；" +
                    "上下文行以空格开头，删除行以 - 开头，新增行以 + 开头",
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val path = args["path"].orEmpty().trim()
        val patch = args["patch"].orEmpty()
        if (path.isBlank()) return ToolOutcome.Failure("path 为空")
        if (patch.isBlank()) return ToolOutcome.Failure("patch 为空")

        val original = try {
            fs.readText(path)
        } catch (e: PathEscapeException) {
            return ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            // 文件不存在 / 过大 —— 明确说清楚，别让模型在"补丁有问题"上瞎猜
            return ToolOutcome.Failure("读取失败（文件可能存在但读不了）：${e.message}")
        }

        return when (val r = UnifiedPatch.applyDiff(original, patch)) {
            is ApplyResult.Failed -> ToolOutcome.Failure(r.reason)

            is ApplyResult.Ok -> {
                // 补丁匹配得上但文本没变（例如只把 A 改成 A）—— 如实回报，别刷成功卡
                if (r.text == original) {
                    return ToolOutcome.Success("补丁已应用，但文件内容未发生变化：$path（共 ${r.hunks} 个修改块）")
                }
                try {
                    // ★ 写前快照（2026-10-19）：补丁改错了要能退回来
                    val snapshotted = Checkpoints.save(fs, path, original)
                    val bytes = fs.writeText(path, r.text)
                    val note = if (r.whitespaceTolerant) {
                        "（注意：匹配时忽略了行尾空白差异，说明补丁的上下文与原文不完全一致）"
                    } else {
                        ""
                    }
                    val snapNote = if (snapshotted) {
                        "（原内容已存快照，可用 restore_path 撤销）"
                    } else {
                        "（原文件超过快照上限，**未保存快照**）"
                    }
                    ToolOutcome.Success(
                        "已修改 $path：${r.hunks} 个修改块 / ${r.changedLines} 行改动，共 ${bytes} 字节$note" +
                            "\n\n" + DiffReceipt.render(original, r.text) + snapNote
                    )
                } catch (e: PathEscapeException) {
                    ToolOutcome.Failure("路径被拒绝：${e.reason}")
                } catch (e: Exception) {
                    ToolOutcome.Failure("写回失败：${e.message}")
                }
            }
        }
    }
}
