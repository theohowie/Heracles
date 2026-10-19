package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64

/**
 * `view_image` 的门禁（2026-10-19）。
 *
 * ## 为什么这些断言必须有
 *
 * "模型看到了图"在 UI 上不可见 —— 它完全可以看着空上下文编一段"图片里是个登录页"。
 * 所以必须钉住两件事：
 * 1. 工具真的把**正确的字节**转成了 data URL（mime 正确、base64 可还原）；
 * 2. 失败时**明确失败**（格式不认识 / 文件不存在 / 太大），逼模型去问用户，而不是瞎猜。
 *
 * ⚠️ "模型真的读懂了图"只有真 Key 验证才能证明 —— 这一点**未做**（见 WORKLOG）。
 */
class ImageToolsTest {

    private fun workspace(): RealWorkspaceFs {
        val dir: Path = Files.createTempDirectory("heracles-img-test")
        return RealWorkspaceFs.open(dir)
    }

    private fun view(fs: RealWorkspaceFs, path: String): ToolOutcome =
        runBlocking { ViewImageTool(fs).execute(mapOf("path" to path)) }

    private val pngBytes = byteArrayOf(
        0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
    )

    @Test
    @DisplayName("★★ 读取 PNG ⇒ SuccessWithImage，data URL 可还原原始字节")
    fun pngBecomesDataUrl() {
        val fs = workspace()
        runBlocking { fs.writeBytes("shot.png", pngBytes) }
        val out = view(fs, "shot.png")

        assertTrue(out is ToolOutcome.SuccessWithImage, "应当是 SuccessWithImage：$out")
        val r = out as ToolOutcome.SuccessWithImage
        assertTrue(r.imageDataUrl.startsWith("data:image/png;base64,"), r.imageDataUrl)
        val b64 = r.imageDataUrl.substringAfter("base64,")
        assertTrue(pngBytes.contentEquals(Base64.getDecoder().decode(b64)), "base64 必须能还原原字节")
        assertTrue(r.detail.contains("shot.png"), "文字结果要说明读了哪个文件：${r.detail}")
    }

    @Test
    @DisplayName("★ jpg / jpeg / webp / gif 的 mime 正确")
    fun mimePerExtension() {
        val fs = workspace()
        runBlocking {
            fs.writeBytes("a.jpg", pngBytes)
            fs.writeBytes("b.jpeg", pngBytes)
            fs.writeBytes("c.webp", pngBytes)
            fs.writeBytes("d.gif", pngBytes)
        }
        assertTrue((view(fs, "a.jpg") as ToolOutcome.SuccessWithImage).imageDataUrl.startsWith("data:image/jpeg;"))
        assertTrue((view(fs, "b.jpeg") as ToolOutcome.SuccessWithImage).imageDataUrl.startsWith("data:image/jpeg;"))
        assertTrue((view(fs, "c.webp") as ToolOutcome.SuccessWithImage).imageDataUrl.startsWith("data:image/webp;"))
        assertTrue((view(fs, "d.gif") as ToolOutcome.SuccessWithImage).imageDataUrl.startsWith("data:image/gif;"))
    }

    @Test
    @DisplayName("★ 不支持的格式 / 不存在 / 空 path ⇒ 明确失败（不瞎猜）")
    fun failuresAreExplicit() {
        val fs = workspace()
        runBlocking { fs.writeText("a.txt", "not an image") }
        assertTrue(view(fs, "a.txt") is ToolOutcome.Failure)
        assertTrue(view(fs, "missing.png") is ToolOutcome.Failure)
        assertTrue(view(fs, "") is ToolOutcome.Failure)
    }

    @Test
    @DisplayName("★★ 超过 4 MB ⇒ 明确失败并说明上限（不静默截断）")
    fun tooLargeFails() {
        val fs = workspace()
        // 上限 +1 字节；不真的构造 4MB 图片内容，直接写等长字节即可
        runBlocking { fs.writeBytes("big.png", ByteArray(Contract.Media.MAX_IMAGE_BYTES + 1)) }
        val out = view(fs, "big.png")
        assertTrue(out is ToolOutcome.Failure, "超限必须失败：$out")
        assertTrue(
            (out as ToolOutcome.Failure).reason.contains("太大"),
            "失败原因要说清是体积问题：${out.reason}",
        )
    }

    @Test
    @DisplayName("★ 越界路径 ⇒ 拒绝（抛 PathEscapeException，由上层转 Failure）")
    fun pathEscapeRejected() {
        val fs = workspace()
        val out = runCatching { view(fs, "../secret.png") }
        assertTrue(
            out.isFailure || out.getOrNull() is ToolOutcome.Failure,
            "越界必须被拒绝：$out",
        )
    }
}
