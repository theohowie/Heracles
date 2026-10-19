package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.ZipFs
import java.util.zip.ZipException

/**
 * **解压工具** —— `26-编码层工具链与逆向引擎.md` §4.2。
 *
 * ## 什么时候用
 *
 * · 拿到一个 APK / ZIP，要看清里面有什么、把内容摊开再改
 * · 逆向闭环的第一步（摊开 apk → 改 smali → 重打包）
 *
 * ## 为什么不做成 shell 里的 `unzip`
 *
 * 设备上**没有** `unzip`、`zip` 这些命令（Android 精简掉了）。
 * 而且真起进程要洗一遍权限与超时 —— 用 `ZipFs`（纯 JVM）更稳、更快、
 * 也更容易在 PC 上测。
 *
 * ## 安全
 *
 * 包内条目名是**外部输入**，`ZipFs` 会逐条做 zip-slip 校验（见其类注释）。
 */
class UnzipFileTool(private val fs: WorkspaceFs) : AgentTool {

    private val zipFs by lazy { ZipFs(fs.info.rootPath) }

    override val spec = ToolSpec(
        name = "unzip_file",
        description = "把一个压缩包（.zip / .apk / .jar）解压到工作区目录里。用于摊开 APK 看清内部结构，或释放下载的压缩包。",
        parameters = listOf(
            ToolParam("archive", "string", "压缩包的相对路径，例如 app.apk 或 downloads/lib.zip"),
            // ★ optional = true（2026-10-18，F7b）：缺键 ⇒ `orEmpty()` ⇒ 解压到工作区根
            //   （与传空字符串同义；成功文案里会写"（工作区根）"）。
            ToolParam(
                "dest_dir", "string", "解压到的目录（相对工作区），不填（或传空字符串）= 工作区根目录",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val archive = args["archive"].orEmpty().trim()
        val dest = args["dest_dir"].orEmpty().trim()
        if (archive.isBlank()) return ToolOutcome.Failure("archive 为空")
        return try {
            val out = zipFs.unzip(archive, dest)
            ToolOutcome.Success(
                "已解压 $archive → ${dest.ifBlank { "（工作区根）" }}：${out.entries} 个条目，${out.bytes} 字节"
            )
        } catch (e: PathEscapeException) {
            // ★ zip-slip / 越界必须**显式失败**。静默跳过会让人以为解压成功了。
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: ZipException) {
            ToolOutcome.Failure("不是有效的压缩包（${e.message}）：$archive")
        } catch (e: Exception) {
            ToolOutcome.Failure("解压失败：${e.message}")
        }
    }
}

/**
 * **打包工具** —— `26-编码层工具链与逆向引擎.md` §4.2。
 *
 * ## 什么时候用
 *
 * · 逆向闭环的最后一步：把改好的目录重新压成包，再交给 `apk_sign`
 * · 把一堆输出文件收成一个便于分享的包
 *
 * ## ⚠️ 不是用来构建 APK 的
 *
 * 从零构建 APK 走 `build_apk`（有 `aapt2` / `d8` 的完整流水线）。
 * 本工具只会**原样压缩目录内容** —— 它不会生成 `resources.arsc`、
 * 不会编译 `classes.dex`。把 Java 源码目录压成 .apk 得到的是一个
 * **装不上的**文件（这一点在描述里已写明，避免模型走错路）。
 *
 * ## 确定性
 *
 * 条目顺序按路径排序、时间戳固定 —— 同一份内容产出同一份字节，
 * 这是重打包后能用签名哈希比对的前提。
 */
class ZipFileTool(private val fs: WorkspaceFs) : AgentTool {

    private val zipFs by lazy { ZipFs(fs.info.rootPath) }

    override val spec = ToolSpec(
        name = "zip_file",
        description = "把一个目录的内容压缩成一个 .zip 包（条目原样打包，不做编译）。用于把改好的文件重新打包，之后交给 apk_sign 签名。注意：它不会编译 dex 或生成资源表，不要用它替代 build_apk。",
        parameters = listOf(
            // ★ optional = true（2026-10-18，F7b）：缺键 ⇒ `orEmpty()` ⇒ 压缩工作区根
            //   （与传空字符串同义；成功文案里会写"（工作区根）"）。
            ToolParam(
                "src_dir", "string", "要压缩的源目录（相对工作区），不填（或传空字符串）= 工作区根目录",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam("archive", "string", "输出的压缩包路径，例如 build/patched.zip（会被覆盖）"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val src = args["src_dir"].orEmpty().trim()
        val archive = args["archive"].orEmpty().trim()
        if (archive.isBlank()) return ToolOutcome.Failure("archive 为空")
        return try {
            val out = zipFs.zip(src, archive)
            ToolOutcome.Success(
                "已打包 ${src.ifBlank { "（工作区根）" }} → $archive：${out.entries} 个条目，${out.bytes} 字节"
            )
        } catch (e: PathEscapeException) {
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("打包失败：${e.message}")
        }
    }
}
