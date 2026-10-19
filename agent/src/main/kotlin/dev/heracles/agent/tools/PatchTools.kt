package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.patch.ApplyResult
import dev.heracles.core.patch.UnifiedPatch
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
