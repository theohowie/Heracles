package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import dev.heracles.workspace.WorkspaceFs
import java.nio.file.Files
import java.nio.file.Path

/**
 * SAF 工作区的**构建暂存区**（2026-10-18，F6b / ADR-032）。
 *
 * ## 为什么需要它
 *
 * 构建/逆向的整条流水线（`aapt2` / `javac` / `d8` / `ZipFs` / `ZipAligner`）都要**真实路径**；
 * 而 SAF 工作区只有 `content://` 授权（`WorkspaceInfo.hasRealPath = false`）。
 * F6a 之前只能在 SAF 工作区上**拒绝**构建；F6b 的办法是：
 *
 * ```
 * 用户工作区（SAF）──镜像──▶ App 内部 staging（真实路径）──现有管线──▶ 产物 ──回写──▶ 用户工作区
 * ```
 *
 * 引擎内部逻辑**一行不改**（内层仍是同一个 `AndroidBuildEngine`，只是换了一个
 * `WorkspaceFs`），本对象只负责"抄进去、抄回来、擦干净"。
 *
 * ## 镜像排除了什么（以及为什么安全）
 *
 * 只镜像 `projectDir` 子树。**顶层 `.heracles/` 是 App 管理的元数据**，不是构建输入：
 *
 * | 内容 | 为什么不必镜像 |
 * |---|---|
 * | `.heracles/toolchain/` | 工具链定位用的是**设备绝对路径**（环境变量 / `/data/local/tmp`），与工作区内副本无关 |
 * | `.heracles/build/` | 上一次构建的中间产物，脚本自己会重建 |
 * | `.heracles/logs/`、`.heracles/sessions/`、`memory.md` | 与构建无关 |
 *
 * ⚠️ **唯一例外：`.heracles/keys/heracles.jks`（签名密钥）必须带过去** ——
 * 它是**构建输入**（决定产物签名身份）。不带过去的话，每次 SAF 构建都会在 staging 里
 * 重新生成一把新调试密钥 ⇒ 同一项目连续两次构建得到"签名不同"的包，
 * 覆盖安装时会被系统当成另一个应用。
 *
 * ## 上限（**已迁入契约**）
 *
 * 三道上限现在定义在 [Contract.Toolchain]（`STAGING_MAX_FILES` / `STAGING_MAX_BYTES` /
 * `STAGING_MAX_DEPTH`）—— 仓库规矩是"魔法数字必须在 `core/contract/Contract.kt`"，
 * F6b 当时因 `:core` 正被别的批次改而暂放本文件，F10 收尾已还清（2026-10-18）。
 * 本对象**只引用**那些常量，不再自带副本（两处副本 = 两套真相）。
 * 取值依据见 [Contract.Toolchain.STAGING_MAX_FILES] 的 KDoc。
 */
internal object BuildStaging {

    /** App 管理的元数据目录（顶层）—— 除签名密钥外一律不镜像。 */
    private const val APP_META_DIR = ".heracles"

    /** 唯一必须带过去的 App 元数据：签名密钥（构建输入）。 */
    private const val KEYSTORE_REL = ".heracles/keys/heracles.jks"

    /** 一次镜像的统计（回给工具层做如实汇报，不做二次猜测）。 */
    data class MirrorStats(
        val files: Int,
        val bytes: Long,
        /** 因属 App 元数据而跳过的条目数（给日志/排查用） */
        val skippedAppMeta: Int,
    )

    /**
     * 把 `projectDir` 子树镜像到 [dest]（一个**真实**目录）。
     *
     * @param maxFiles / maxBytes / maxDepth 默认取 [Contract.Toolchain] 的三道 staging 上限；
     *   **测试可传小值**（否则为了测上限得真造 2000 个文件 / 64MB 数据，又慢又没必要）
     * @throws IllegalArgumentException 读取失败 / 超过任一条上限（消息里带**收到了多少**）
     */
    suspend fun mirrorInto(
        fs: WorkspaceFs,
        projectDir: String,
        dest: Path,
        maxFiles: Int = Contract.Toolchain.STAGING_MAX_FILES,
        maxBytes: Long = Contract.Toolchain.STAGING_MAX_BYTES,
        maxDepth: Int = Contract.Toolchain.STAGING_MAX_DEPTH,
    ): MirrorStats {
        val base = projectDir.trim().trim('/')
        val root = dest.toAbsolutePath().normalize()
        Files.createDirectories(root)

        /** staging 相对路径 → 工作区相对路径 */
        fun ws(rel: String): String = when {
            base.isEmpty() -> rel
            rel.isEmpty() -> base
            else -> "$base/$rel"
        }

        var files = 0
        var bytes = 0L
        var skipped = 0
        val stack = ArrayDeque<Pair<String, Int>>() // (staging 相对路径, 深度)
        stack.addLast("" to 0)

        while (stack.isNotEmpty()) {
            val (rel, depth) = stack.removeLast()
            val entries = try {
                fs.list(ws(rel))
            } catch (e: Exception) {
                throw IllegalArgumentException("读取工作区目录失败（${ws(rel).ifEmpty { "根" }}）：${e.message}")
            }
            for (entry in entries) {
                val name = entry.relativePath.substringAfterLast('/')
                val childRel = if (rel.isEmpty()) name else "$rel/$name"

                // ★ 顶层 .heracles（含子项）：只放行签名密钥，其余跳过（见类 KDoc）
                if (childRel == APP_META_DIR || childRel.startsWith("$APP_META_DIR/")) {
                    if (!entry.isDirectory && childRel == KEYSTORE_REL) {
                        // 签名密钥是**构建输入**：不带过去，每次 SAF 构建都会换一把 key
                        val data = try {
                            fs.readBytes(entry.relativePath)
                        } catch (e: Exception) {
                            throw IllegalArgumentException("读取签名密钥失败（${entry.relativePath}）：${e.message}")
                        }
                        if (files + 1 > maxFiles) {
                            throw IllegalArgumentException("镜像文件数超过上限（${maxFiles} 个）—— 见类 KDoc 的取值依据")
                        }
                        if (bytes + data.size > maxBytes) {
                            throw IllegalArgumentException(
                                "镜像总大小超过上限（${maxBytes} 字节）—— 已拷 ${bytes} 字节，" +
                                    "再加 ${data.size} 字节（${entry.relativePath}）会超限"
                            )
                        }
                        val target = root.resolve(childRel)
                        target.parent?.let { Files.createDirectories(it) }
                        Files.write(target, data)
                        files++
                        bytes += data.size
                        continue
                    }
                    // 唯一继续下潜的情形：通往签名密钥的那几层目录（.heracles、.heracles/keys）
                    if (entry.isDirectory && KEYSTORE_REL.startsWith("$childRel/")) {
                        if (depth + 1 > maxDepth) {
                            throw IllegalArgumentException("镜像超过 ${maxDepth} 层（在 $childRel）—— 目录异常深或成环")
                        }
                        Files.createDirectories(root.resolve(childRel))
                        stack.addLast(childRel to (depth + 1))
                    } else {
                        skipped++
                    }
                    continue
                }

                if (entry.isDirectory) {
                    if (depth + 1 > maxDepth) {
                        throw IllegalArgumentException(
                            "镜像超过 ${maxDepth} 层（在 $childRel）—— 目录异常深或成环，请检查工程结构"
                        )
                    }
                    Files.createDirectories(root.resolve(childRel))
                    stack.addLast(childRel to (depth + 1))
                } else {
                    if (files + 1 > maxFiles) {
                        throw IllegalArgumentException(
                            "镜像文件数超过上限（${maxFiles} 个）—— 工程太大，不该整体拷进 staging 构建；" +
                                "请把工程收窄到需要构建的目录（用 project_dir 指定）"
                        )
                    }
                    val data = try {
                        fs.readBytes(entry.relativePath)
                    } catch (e: Exception) {
                        throw IllegalArgumentException("读取文件失败（${entry.relativePath}）：${e.message}")
                    }
                    if (bytes + data.size > maxBytes) {
                        throw IllegalArgumentException(
                            "镜像总大小超过上限（${maxBytes} 字节）—— 已拷 ${bytes} 字节，" +
                                "再加 ${data.size} 字节（${entry.relativePath}）会超限"
                        )
                    }
                    val target = root.resolve(childRel)
                    target.parent?.let { Files.createDirectories(it) }
                    Files.write(target, data)
                    files++
                    bytes += data.size
                }
            }
        }
        return MirrorStats(files = files, bytes = bytes, skippedAppMeta = skipped)
    }

    /** 回写结果 —— `Exists` 是**正常业务分支**（用户文件不可覆盖）。 */
    sealed interface WriteBack {
        data class Ok(val relativePath: String, val bytes: Int) : WriteBack
        data class Exists(val relativePath: String) : WriteBack
    }

    /**
     * 把产物回写到**用户工作区**。
     *
     * ## 目标已存在 ⇒ **不覆盖**
     *
     * 产物路径落在用户自己的项目里，覆盖不可逆（可能与用户手写的文件同名）。
     * ⇒ 先看存在性，存在就如实返回 [WriteBack.Exists]，由调用方给"换个名字"的提示。
     */
    suspend fun writeBack(fs: WorkspaceFs, relativePath: String, bytes: ByteArray): WriteBack {
        if (fs.exists(relativePath)) return WriteBack.Exists(relativePath)
        fs.writeBytes(relativePath, bytes)
        return WriteBack.Ok(relativePath, bytes.size)
    }

    /**
     * 尽力删除 staging 目录（**不抛**）。
     *
     * 清理失败不该掩盖构建结果，但也不能假装干净 —— 返回 `false` 让调用方留痕/汇报。
     */
    fun deleteRecursively(dir: Path): Boolean {
        if (!Files.exists(dir)) return true
        var ok = true
        try {
            Files.walk(dir).use { stream ->
                stream.sorted(Comparator.reverseOrder()).forEach { p ->
                    try {
                        Files.deleteIfExists(p)
                    } catch (e: Exception) {
                        ok = false
                    }
                }
            }
        } catch (e: Exception) {
            ok = false
        }
        return ok
    }
}
