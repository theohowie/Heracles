package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolGroup
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs
import java.util.Base64

/**
 * **让模型"看到"工作区里的一张图** —— `view_image`（2026-10-19）。
 *
 * ## 为什么需要（安卓上尤其需要）
 *
 * 手机上的开发任务经常围绕图片：用户报 UI bug 的截图、设计稿、报错截图、生成的图表。
 * 没有这个工具时，模型只能读文件名 —— 然后**猜**图片内容（幻觉）。
 *
 * ## 它和其它工具不同的地方
 *
 * 它返回 [ToolOutcome.SuccessWithImage]：文字结果只是"已读取"，**图片本身**
 * 由 `AgentLoop` 加进本 run 的图片列表，随下一次请求作为多模态输入发出去。
 * 也就是说：模型调一次 `view_image`，之后每一轮都能"看到"这张图（不用重复调用）。
 *
 * ## 边界
 *
 * · 只读**工作区内**路径（`WorkspaceFs` 负责越界拒绝）
 * · 只支持 `png` / `jpg` / `jpeg` / `webp` / `gif`（按扩展名；不做内容嗅探 —— 成本/复杂度不划算）
 * · 单张 ≤ [Contract.Media.MAX_IMAGE_BYTES]；本 run 累计张数由 `AgentLoop` 按
 *   [Contract.Media.MAX_IMAGES_PER_RUN] 控制
 * · 读不到 / 太大 / 扩展名不认识 ⇒ **明确失败**（模型应改为让用户描述，而不是瞎猜）
 */
class ViewImageTool(private val fs: WorkspaceFs) : AgentTool {

    /** 纯读（只读图片字节）⇒ 可并发。 */
    override val parallelSafe: Boolean get() = true

    override val spec = ToolSpec(
        name = "view_image",
        description = "读取工作区里的一张图片（截图/照片/设计稿），让模型真正看到图片内容。" +
            "支持 png/jpg/jpeg/webp/gif，单张不超过 ${Contract.Media.MAX_IMAGE_BYTES / 1024 / 1024} MB。" +
            "读取成功后图片会附在后续请求里，不需要重复调用。" +
            "用于：用户提供的截图、UI 设计稿、报错截图。" +
            "如果只是想知道文件是否存在，用 list_files / find_files 更省。",
        parameters = listOf(
            ToolParam("path", "string", "图片相对工作区的路径，例如 screenshots/bug.png"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val raw = args["path"].orEmpty().trim()
        if (raw.isEmpty()) return ToolOutcome.Failure("path 不能为空")
        val path = raw.replace('\\', '/')
        if (path.startsWith("/")) {
            return ToolOutcome.Failure("path 必须是工作区内的相对路径，收到：$raw")
        }
        val ext = path.substringAfterLast('.', "").lowercase()
        val mime = when (ext) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            else -> return ToolOutcome.Failure(
                "不支持的图片格式「.$ext」；支持 png / jpg / jpeg / webp / gif",
            )
        }

        val exists = runCatching { fs.exists(path) }.getOrElse { e ->
            if (e is PathEscapeException) throw e
            return ToolOutcome.Failure("检查图片失败：${e.message ?: e.javaClass.simpleName}")
        }
        if (!exists) return ToolOutcome.Failure("图片不存在：$path")

        val bytes = try {
            fs.readBytes(path)
        } catch (e: PathEscapeException) {
            throw e
        } catch (e: Exception) {
            return ToolOutcome.Failure("读取图片失败：${e.message ?: e.javaClass.simpleName}")
        }
        if (bytes.isEmpty()) return ToolOutcome.Failure("图片是空文件：$path")
        if (bytes.size > Contract.Media.MAX_IMAGE_BYTES) {
            return ToolOutcome.Failure(
                "图片太大（${bytes.size} 字节 > 上限 ${Contract.Media.MAX_IMAGE_BYTES}）；" +
                    "请先压缩/缩小后再试",
            )
        }

        val dataUrl = "data:$mime;base64," +
            Base64.getEncoder().encodeToString(bytes)
        return ToolOutcome.SuccessWithImage(
            detail = "已读取图片 $path（${bytes.size} 字节，$mime）—— 图片内容已附在后续请求里，" +
                "可以直接描述它；不需要重复调用 view_image",
            imageDataUrl = dataUrl,
        )
    }
}

/**
 * 图片工具的分组表（`search_tools` 用）与装配入口。
 */
object ImageTools {
    val GROUPS: Map<String, ToolGroup> = mapOf(
        // ★ 2026-10-19 真机修复：早先挂在 FILE 组，而 FILE 的关键词只有「文件/读/写」
        //   ⇒ 模型搜「查看图片」搜不到 ⇒ 它回"我没有看图的工具"。改用专用 IMAGE 组。
        "view_image" to ToolGroup.IMAGE,
    )

    fun create(fs: WorkspaceFs): List<AgentTool> = listOf(ViewImageTool(fs))
}
