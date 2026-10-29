/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 *
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/exec/Router.kt
 *           - variants 列表（六条零宽候选变换，逐条实测）
 *           - probe()：只信 File.list()，不信 canRead / isExternalStorageManager
 *           - map(path) / reset() / reprobe()
 *           - restricted / DATA_ROOT / OBB_ROOT 常量
 *   原文件：app/src/main/kotlin/b/ai/exec/FileOps.kt
 *           - real(route, path)：ZERO_WIDTH 时走 Router.map(path) 再 new File(...)
 *           - readJava / writeJava 的 400_000 字节分块读与二进制探测
 *
 * ★ 本文件**只移植文件访问**，不移植 FileOps 里的 zip/unzip/grep/move/info。
 *   那些属于「Agent 工具层」，不是「沙箱文件通道」；搬进来会让沙箱变胖、
 *   并且把它们与具体的工具语义绑死。
 */

package com.heracles.sandbox.file

import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import java.io.File

/**
 * 「零宽」路径变异是否可用。
 *
 * <p>这不是「有没有权限」的问题，而是「这台 ROM 的 FUSE 层对哪些畸形路径
 * 放行」的问题。上游注释写得很直接：
 *
 *   「零宽（CVE-2024-43093 一类）在不同 ROM 上行为不一致，这里不做版本猜测，
 *     而是启动时/开关打开时按候选变换逐个实测 list() 是否成功，命中哪个就用哪个。
 *     全部未命中 = 该设备不支持零宽。」
 *
 * 所以本类**不猜版本、不猜机型**，只实测。
 */
enum class ZeroWidthStatus {
    /** 还没探测过。 */
    UNPROBED,

    /**
     * **原生路径就能列** `Android/data`。
     *
     * <p>通常是拿到了「所有文件访问」（MANAGE_EXTERNAL_STORAGE），
     * 或者运行在 Android 10 及以下。此时不需要任何零宽技巧，
     * 上游也是同样的处理（`nativeOk` 优先）。
     */
    NATIVE,

    /** 零宽变换命中了某一条候选；[ZeroWidthFileChannel.activeVariant] 给出是哪条。 */
    ZERO_WIDTH,

    /**
     * 全部候选以及原生路径都失败。
     *
     * <p>这台设备上访问不了其它 App 的 `Android/data`；沙箱如实报告，
     * 由宿主决定要不要提示用户去开「所有文件访问」。
     */
    UNSUPPORTED,
}

/**
 * `Android/data` 与 `Android/obb` 的访问通道（零宽文件通道）。
 *
 * ============================================================================
 * 它**实际**能穿透什么 / 不能穿透什么（务必如实告知宿主）
 * ============================================================================
 * **能**（前提是零宽变换在这台 ROM 上命中，或已获「所有文件访问」）：
 * - `/storage/emulated/0/Android/data/<任意包名>/files/…`
 * - `/storage/emulated/0/Android/obb/<任意包名>/…`
 *
 * **不能**（这是本模块最容易被人误解的地方，上游也一样）：
 * - ❌ `/data/data/<其它包名>` —— 这是**真的**其它 App 私有目录，
 *   在 FUSE 之外，受 SELinux domain 与 Unix 权限双重限制。
 *   除 root（uid 0）之外没有绕过办法。零宽技巧对它完全无效。
 * - ❌ `/data/user/0/<其它包名>`
 * - ❌ 需要 MANAGE_EXTERNAL_STORAGE 之外的特殊豁免的路径
 * - ❌ 跨用户的 `/storage/emulated/<其它用户>/…`
 *
 * 换句话说：**零宽通道 = 外部存储（FUSE）上的 App 专属目录**，
 * 不是「所有 App 的所有数据」。这一点必须写进给宿主的文档里，
 * 否则「沙箱能读别的 App 数据」会变成一句危险的谎。
 *
 * ============================================================================
 * 三条硬边界（宿主必须按这三条来设计提示语）
 * ============================================================================
 * 1. **作用范围只限 `/storage/emulated/0/Android/{data,obb}`。**
 *    其它任何路径（包括 `/data/data/<pkg>`、`/system`、`/data/adb`）都**不在**它的
 *    能力范围内 —— 见 [ZeroWidthFileChannel.isInZeroWidthScope] 与
 *    [ZeroWidthFileChannel.isRootOnly]。对后者做零宽变换只是把路径弄脏，
 *    不会多读到任何一个字节。
 *
 * 2. **绕不过 SELinux。** 零宽变换能骗过 FUSE 的路径解析，但骗不过内核的
 *    LSM 检查。`/data/data/<pkg>` 属于 `app_data_file` 类型，`untrusted_app`
 *    域（本应用）对它没有 `read` 权限，**这与路径长什么样无关**。
 *    同理，shell 域（uid 2000，Shizuku / 无线 ADB）也读不到 `app_data_file`。
 *    只有 uid 0（root）能越过这条界线。
 *
 * 3. **ROM 打补丁后自动降级。** 这是「零宽」本质上是 ROM 的 FUSE 实现对
 *    畸形路径规范化不足导致的，**任何一次系统更新都可能把它修掉**。
 *    因此本类从不假设它可用：
 *    - 启动/开关变化时用 [probe] **实测**六条候选（只信 `File.list()` 是否成功）；
 *    - 实测意味着「补丁后自动降级」：命中不了就返回 [ZeroWidthStatus.UNSUPPORTED]，
 *      读写退回原生路径，由真实 IO 报错。**不需要任何人工干预，也不会崩**；
 *    - 反过来，用户事后开了「所有文件访问」也会自动升级成 [ZeroWidthStatus.NATIVE]
 *      （调 [reset] 后重探即可），同样不需要改代码。
 *
 *    这也是上游 baicodex Router.kt 的原始设计意图（原文：「不做版本猜测，
 *    而是按候选变换逐个实测 list() 是否成功」）；本类原样保留该策略。
 *
 * ============================================================================
 * 为什么需要它
 * ============================================================================
 * Android 11+ 的 scoped storage 把 `Android/data` 从 `File` API 里藏掉了
 * （`canRead()` 报 true 但 `list()` 返回 null —— 上游特意强调
 * 「canRead 与 isExternalStorageManager 在 FUSE 上都会骗人」）。
 * 零宽路径是少数能让 `File.list()` 重新工作的办法，且不需要 root。
 *
 * ============================================================================
 * 线程
 * ============================================================================
 * [probe] 会做真实的文件系统 IO，**不要在主线程调用**。
 * 结论缓存在 [status] 里，之后读它没有 IO。
 */
class ZeroWidthFileChannel {

    /** 上游的六条候选变换（顺序即优先级）。 */
    private val variants: List<Variant> = listOf(
        Variant("原路径") { path -> path },
        Variant("尾部 /.") { path -> "$path/." },
        Variant("Android 前双斜杠") { path -> path.replace("/Android/", "//Android/") },
        Variant("Android 后零宽空格") { path -> path.replace("/Android/", "/Android\u200b/") },
        Variant("尾部零宽空格") { path -> "$path\u200b" },
        Variant("data/obb 后零宽空格") { path ->
            path.replace("/data", "/data\u200b").replace("/obb", "/obb\u200b")
        },
    )

    /** 一条零宽候选：名字（给人读）+ 变换函数。 */
    private data class Variant(val label: String, val map: (String) -> String)

    @Volatile
    private var picked: Variant? = null

    @Volatile
    private var probed = false

    /** 原生路径能不能真的列出 `Android/data`（只信 list()）。 */
    @Volatile
    private var nativeOk = false

    /** 当前结论。未探测时为 [ZeroWidthStatus.UNPROBED]。 */
    val status: ZeroWidthStatus
        get() = when {
            !probed -> ZeroWidthStatus.UNPROBED
            nativeOk -> ZeroWidthStatus.NATIVE
            picked != null -> ZeroWidthStatus.ZERO_WIDTH
            else -> ZeroWidthStatus.UNSUPPORTED
        }

    /** 命中的候选名（`ZERO_WIDTH` 时非空）。 */
    val activeVariant: String? get() = picked?.label

    /** 是否已经有可用的穿透能力（原生或零宽命中）。 */
    val usable: Boolean get() = status == ZeroWidthStatus.NATIVE || status == ZeroWidthStatus.ZERO_WIDTH

    /**
     * 探测一次。**阻塞**，只允许在工作线程调用。
     *
     * @return 探测后的 [status]
     */
    fun probe(): ZeroWidthStatus {
        probed = true
        picked = null
        nativeOk = canList(DATA_ROOT)
        // 原生路径能列出就不用零宽（上游同款短路）。
        if (nativeOk) return ZeroWidthStatus.NATIVE
        for (variant in variants) {
            if (canList(variant.map(DATA_ROOT))) {
                picked = variant
                return ZeroWidthStatus.ZERO_WIDTH
            }
        }
        return ZeroWidthStatus.UNSUPPORTED
    }

    /** 清掉结论，下次重新探测（用户刚在系统里开了「所有文件访问」之后用）。 */
    fun reset() {
        probed = false
        picked = null
        nativeOk = false
    }

    /**
     * 把宿主路径映射成**实际要打开**的路径。
     *
     * <p>注意：这里只做「拼畸形路径」，不保证能打开。真正打开由
     * [SandboxFileService] 的 read/write 负责，失败会转成 `CODE_IO`。
     *
     * <p>只接受 [HostPath]：**沙箱视角不能用零宽** —— 零宽是 FUSE 上的
     * 一条路径解析怪癖，与 PRoot 的 `-b` 绑定毫无关系，混用只会得到
     * 「明明映射了却打不开」的困惑。类型上就把它挡住。
     *
     * @throws SandboxException `CODE_CHANNEL_UNAVAILABLE`（探测过且不可用）。
     *         未探测时**原样返回** —— 让调用方的读写去报真正的 IO 错误，
     *         不要把「还没探测」伪装成「不支持」。
     */
    @Throws(SandboxException::class)
    fun mapForAccess(path: HostPath): HostPath {
        val current = status
        if (current == ZeroWidthStatus.UNPROBED) return path
        val variant = picked ?: return path
        // 只对受限目录做变换；对 /sdcard/Download 之类做变换纯粹是给自己找麻烦。
        if (!isInRestrictedZone(path.value)) return path
        return HostPath(variant.map(path.value))
    }

    /**
     * 「所有文件访问」是否真的生效。
     *
     * <p>上游的判据：系统标志会骗人（uid op 允许但 FUSE 仍拒），
     * **必须叠加 list() 实测结果**。这里只报探测结果，不读系统标志 ——
     * 那是宿主的事（沙箱不内置权限读取）。
     */
    val nativeAccessConfirmed: Boolean get() = nativeOk

    /** 一条路径是否落在需要零宽/特殊权限的两棵子树下。 */
    fun isInRestrictedZone(path: String): Boolean =
        path.startsWith(DATA_ROOT) || path.startsWith(OBB_ROOT)

    /** 只信 `list()`：能拿到列表才算这条路通（上游注释：canRead 会骗人）。 */
    private fun canList(path: String): Boolean =
        runCatching { File(path).list() != null }.getOrDefault(false)

    companion object {
        /** `Android/data` 根（宿主视角）。 */
        const val DATA_ROOT: String = "/storage/emulated/0/Android/data"

        /** `Android/obb` 根（宿主视角）。 */
        const val OBB_ROOT: String = "/storage/emulated/0/Android/obb"

        /**
         * 需要「特殊通道」才能访问的宿主路径前缀。
         *
         * <p>与上游 `Router.restricted` 的清单一致，但**语义不同**：
         * 上游用它做「选哪条执行通道」的判据，这里只用来告诉宿主
         * 「这条路径可能需要零宽/root」。
         *
         * <p>`/data/` 一类的条目列在这里是为了**如实报告它不在零宽的能力范围内**，
         * 而不是为了声称能访问 —— 见类 KDoc 的「不能穿透什么」。
         */
        val RESTRICTED_PREFIXES: List<String> = listOf(
            DATA_ROOT,
            OBB_ROOT,
            "/data/",
            "/system/",
            "/vendor/",
            "/product/",
            "/root/",
            "/proc/",
        )

        /**
         * 这些路径**任何非 root 通道都读不到**（含零宽）。
         *
         * <p>存在的意义：让宿主能在**调用前**就知道「这条路径走零宽也没用」，
         * 而不是让用户看到一条莫名其妙的 IO 错误。
         */
        val ROOT_ONLY_PREFIXES: List<String> = listOf(
            "/data/data/",
            "/data/user/",
            "/data/system/",
            "/data/misc/",
            "/data/adb/",
            "/proc/",
            "/system/",
        )

        /** 该宿主路径是否只有 root 能访问（零宽无效）。 */
        fun isRootOnly(path: String): Boolean = ROOT_ONLY_PREFIXES.any { path.startsWith(it) }

        /** 该宿主路径是否落在零宽的能力范围内。 */
        fun isInZeroWidthScope(path: String): Boolean =
            path.startsWith(DATA_ROOT) || path.startsWith(OBB_ROOT)

        /** 给定 [PathView] 与路径，零宽通道是否适用（**只有 HOST 视角适用**）。 */
        fun appliesTo(view: PathView, hostPath: String): Boolean =
            view == PathView.HOST && isInZeroWidthScope(hostPath)
    }
}
