package com.theohowie.heracles.bridge

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.locks.ReentrantLock

/**
 * **长期记忆存储**（2026-10-23）—— `heracles/device` 通道里 `memory.*` 的实现。
 *
 * ## 为什么必须搬到 App 全局（用户报的问题）
 *
 * 改动之前，记忆写在 `<工作区>/.heracles/memory.md`，带来两个**功能性**缺陷：
 *
 * | 缺陷 | 后果 |
 * |---|---|
 * | 存工作区里 | 换个工作区 ⇒ 记忆全没了（用户的心智是"这个 App 记得我"） |
 * | 只写不读 | `renderMemory()` 全仓 0 处调用 ⇒ 记了也用不上，换会话必失忆 |
 *
 * 现在固定放在 **App 级私有目录**：
 *
 * ```
 * <getExternalFilesDir(null)>/heracles/memory.md
 * ```
 *
 * 三个**为什么选这里**的理由：
 *
 * 1. **与工作区无关** ⇒ 跨工作区共享，符合"长期记忆"的语义；
 * 2. **不受 SAF 限制** ⇒ 不依赖用户授权、不需要 `MANAGE_EXTERNAL_STORAGE`，
 *    也不会因为用户删了工作区就丢记忆；
 * 3. **App 自己的目录** ⇒ 读写不会被 `media_rw` 权限卡住（真机实测过
 *    `/sdcard` 用户目录写必 `EPERM`，见 `docs/20`）。
 *
 * ⚠️ **如实记下的代价**：**卸载 App 即丢**（`allowBackup=false`，见 Manifest）。
 * 这是有意的取舍 —— 记忆属于"本机这个 App 的长期状态"，
 * 跟着备份漂移反而有隐私风险。
 *
 * ## 并发安全（本类的核心难点）
 *
 * 记忆是**跨会话、跨工作区共享**的，而 agent 可能同时跑几路
 * （用户在两个工作区各发一条、或者工具并行执行）。若两路同时
 * "读-改-写"，后写的会覆盖先写的 ⇒ **静默丢记忆**。
 *
 * 所以：
 *
 * · 三个入口全部 [lock] 里跑，**同一时刻只有一个线程能碰文件**；
 * · [lock] 是 `ReentrantLock`（不是普通锁）—— 因为 [append] 内部
 *   会调 [readBytesLocked]，可重入才不会自锁死；
 * · 读改写的"读"和"写"在**同一个临界区**内，不存在 TOCTOU 窗口。
 *
 * 为什么不在 Kotlin 侧用 `Mutex`：这里是 `suspend` 上下文，但临界区里
 * 是纯本地文件 IO（微秒级），用 `ReentrantLock` + `withContext(IO)` 更直接，
 * 也避免"持锁跨越挂起点"那类容易写错的写法。
 *
 * ## 上限：256 KB，超了**拒绝**（绝不静默截断）
 *
 * 记忆会**整段进 system prompt** ⇒ 它的大小 = 每一轮的固定开销
 * （来源 `Contract.Memory.maxBytes`）。写满之后再追加**必须拒绝**并说明，
 * 因为"静默丢掉最旧的"会让用户以为记住了、实际没有。
 */
class MemoryStore(private val context: Context) {

    companion object {
        /** 记忆根目录名（`<externalFilesDir>/heracles`，不含 `memory.md`）。 */
        const val DIR = "heracles"

        /** 记忆文件名。 */
        const val FILE = "memory.md"

        /**
         * 记忆文件大小上限：**256 KB**。
         *
         * 与 backend `Contract.Memory.maxBytes` **必须同一个数** ——
         * 这边是写入口（真正的闸），那边是文档与提示词预算的声明。
         * 数值改了要两边一起改，否则会出现"Kotlin 放行、backend 认为超了"。
         */
        const val MAX_BYTES: Int = 256 * 1024

        /** ISO-8601 时间戳（固定 `Locale.US`，否则阿拉伯语/泰语环境会出乱码数字）。 */
        private fun stamp(): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US)
            return fmt.format(Date())
        }
    }

    /**
     * 唯一的那把锁。
     *
     * `ReentrantLock` 而非普通锁：[append] 持锁时会调 [readBytesLocked]，
     * 而它也要这把锁 —— 可重入才不会自己把自己锁死。
     */
    private val lock = ReentrantLock()

    /** 记忆文件的绝对路径（`<externalFilesDir>/heracles/memory.md`）。 */
    fun path(): String? {
        val base = context.getExternalFilesDir(null) ?: return null
        return File(File(base, DIR), FILE).absolutePath
    }

    /**
     * `memory.read` → `{ok, text, bytes}`
     *
     * **文件不存在 ⇒ `ok:true` + `text:""`**（第一次用还没有记忆，这是正常状态，
     * 不是错误）。只有真读不出来（IO 异常 / 目录不可用）才 `ok:false`。
     */
    suspend fun read(): Map<String, Any?> = withContext(Dispatchers.IO) {
        lock.lock()
        try {
            val f = fileOrFail() ?: return@withContext failure(
                "无法定位 App 私有目录（外部存储可能被摘除）—— 长期记忆暂不可用",
            )
            if (!f.exists()) {
                return@withContext mapOf("ok" to true, "text" to "", "bytes" to 0)
            }
            val bytes = f.readBytes()
            // allowMalformed 的等价物：String(bytes, UTF_8) 对坏字节给 U+FFFD，
            // 不抛 —— 记忆是长期数据，一处坏字节不该让整份读不出来
            mapOf(
                "ok" to true,
                "text" to String(bytes, Charsets.UTF_8),
                "bytes" to bytes.size,
            )
        } catch (e: Throwable) {
            failure("读取长期记忆失败：${e.javaClass.simpleName}: ${e.message}")
        } finally {
            lock.unlock()
        }
    }

    /**
     * `memory.append` → `{ok, bytes}`（**追加一行**，行首带 ISO 时间戳）
     *
     * ## 写成什么样
     *
     * ```
     * - 2026-10-23T09:06:29+08:00 — 项目用 Flutter，构建走 flutter build apk
     * ```
     *
     * 为什么带时间戳：记忆是长期累积的，用户（和模型）需要能判断
     * "这条是什么时候记的、还准不准"。`- ` 前缀让它读起来是一个列表。
     *
     * ## 超限就**拒绝**
     *
     * 先算 `当前字节 + 新行字节`，超 [MAX_BYTES] 直接回 `ok:false` 并说清
     * 当前多大、加完会多大、该怎么办。**绝不**写半条，也**绝不**删旧的腾地方
     * —— 那两种都会让用户以为记下了。
     */
    suspend fun append(note: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val text = note.trim()
        if (text.isEmpty()) {
            return@withContext failure("要记住的内容是空的")
        }

        lock.lock()
        try {
            val f = fileOrFail() ?: return@withContext failure(
                "无法定位 App 私有目录（外部存储可能被摘除）—— 长期记忆暂不可用",
            )
            f.parentFile?.let { parent ->
                if (!parent.isDirectory && !parent.mkdirs()) {
                    return@withContext failure("无法创建记忆目录：${parent.absolutePath}")
                }
            }

            val currentBytes = if (f.exists()) f.length().toInt() else 0
            // 单行：`- <ISO 时间戳> — <内容>\n`
            val line = "- ${stamp()} — $text\n"
            val lineBytes = line.toByteArray(Charsets.UTF_8).size
            val after = currentBytes + lineBytes

            if (after > MAX_BYTES) {
                return@withContext mapOf(
                    "ok" to false,
                    "error" to (
                        "记忆已达上限，**没有写入**：" +
                            "当前 ${currentBytes / 1024} KB，加上这条会变成 " +
                            "${after / 1024} KB，上限是 ${MAX_BYTES / 1024} KB。\n" +
                            "记忆会整段进 system prompt，所以必须有上限。" +
                            "请在「设置 → 长期记忆」里删掉过时条目后再追加。"
                        ),
                    "bytes" to currentBytes,
                )
            }

            // ★ 真正的追加：append=true，**不读旧内容**（O(追加量)）
            java.io.FileOutputStream(f, /* append = */ true).use { out ->
                out.write(line.toByteArray(Charsets.UTF_8))
                out.flush()
            }
            mapOf("ok" to true, "bytes" to after)
        } catch (e: Throwable) {
            failure("写入长期记忆失败：${e.javaClass.simpleName}: ${e.message}")
        } finally {
            lock.unlock()
        }
    }

    /**
     * `memory.clear` → `{ok}`
     *
     * 清空 = 把文件**截断成 0 字节**（而不是删文件）：
     * 删了之后 `memory.read` 与"从没用过"无法区分，而用户明确想要的是
     * "我把它清空了"，留一个空文件语义更准。
     *
     * 文件不存在也算成功（幂等）。
     */
    suspend fun clear(): Map<String, Any?> = withContext(Dispatchers.IO) {
        lock.lock()
        try {
            val f = fileOrFail() ?: return@withContext failure(
                "无法定位 App 私有目录（外部存储可能被摘除）—— 长期记忆暂不可用",
            )
            if (!f.exists()) return@withContext mapOf("ok" to true)
            java.io.FileOutputStream(f, /* append = */ false).use { out ->
                out.flush()
            }
            mapOf("ok" to true)
        } catch (e: Throwable) {
            failure("清空长期记忆失败：${e.javaClass.simpleName}: ${e.message}")
        } finally {
            lock.unlock()
        }
    }

    // ------------------------------------------------------------------ 内部

    /** 拿到文件对象；拿不到（没有外置私有目录）返回 null。 */
    private fun fileOrFail(): File? {
        val base = context.getExternalFilesDir(null) ?: return null
        return File(File(base, DIR), FILE)
    }

    private fun failure(reason: String): Map<String, Any?> =
        mapOf("ok" to false, "error" to reason)
}
