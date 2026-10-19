package dev.heracles.workspace

import java.io.BufferedOutputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream

/** 一次对齐的结果。 */
data class AlignOutcome(
    /** 包内条目总数 */
    val entries: Int,
    /** 实际插入了填充的条目数 */
    val padded: Int,
    val bytesIn: Long,
    val bytesOut: Long,
    /**
     * 对齐后**仍然**不对齐的条目数。
     *
     * 正常情况下必须是 0 —— 不为 0 就说明**这个实现有 bug**，
     * 调用方应当把这件事说出来，而不是继续拿"已对齐"去汇报（H-1 教训）。
     */
    val stillMisaligned: Int,
) {
    val ok: Boolean get() = stillMisaligned == 0
}

/**
 * 对齐检查报告 —— **可独立验证**的那种。
 *
 * 说"对齐过"而没有检查手段，等于假信息：本仓库不再依赖外部 `zipalign`
 * （Android 上没有这个二进制，ADR-026），所以"怎么证明对齐了"必须自己给出答案。
 */
data class AlignmentReport(
    /** 包内条目总数 */
    val total: Int,
    /** 真正需要对齐的条目数（STORED 且非空 —— 压缩数据不参与） */
    val checked: Int,
    /** 不满足对齐的条目：名字 → 数据起始偏移 */
    val misaligned: List<Pair<String, Long>>,
) {
    val ok: Boolean get() = misaligned.isEmpty()

    /** 一行结论（给日志/上下文用） */
    fun summary(): String = if (ok) {
        "已对齐：$checked/$total 条需要对齐的条目全部满足"
    } else {
        "**未对齐**：$checked 条里有 ${misaligned.size} 条不满足 —— " +
            misaligned.take(5).joinToString("；") { "${it.first}@${it.second}" }
    }
}

/**
 * **进程内 4 字节对齐** —— `26-编码层工具链与逆向引擎.md` §3.1、ADR-026 的欠账还清。
 *
 * ## 为什么必须有这个东西
 *
 * 对齐是 `zipalign` 的活，而 **Android 上根本没有 `zipalign`**
 * （Termux 3006 个包 + `android-tools` 都没有；SDK 自带的是 glibc 二进制，
 * 在 bionic 上起不来 —— ADR-025/026，2026-10-16 真机实测）。
 *
 * 当时的选择是"跳过并**明说**"（未对齐的 APK 照样能装），把真正的对齐
 * 登记为欠账 —— 本类就是还这笔账：**不依赖任何外部二进制**。
 *
 * ## 对齐规则（自己定的，也说清依据）
 *
 * | 条目 | 对齐 |
 * |---|---|
 * | `method == STORED`（未压缩） | 4 字节 |
 * | 未压缩且以 `.so` 结尾（`lib/` 下） | 4096 字节（页对齐） |
 * | 其余（DEFLATE 压缩数据、目录条目、空数据） | **不动** |
 *
 * 依据：对齐的意义是让**未压缩**数据能按固定步长被 mmap 直读；
 * 压缩数据本来就要解压，给它插填充只是让文件变大。
 * 所以本实现只动真正需要的条目 —— 少改字节，就少一分把包写坏的风险。
 *
 * ## 怎么对齐：插"额外字段"，不动数据
 *
 * ZIP 的每个条目的数据位置 = 本地头(30B) + 文件名 + **额外字段**。
 * 额外字段是可以自由增加的（`id + 长度 + 载荷` 的序列），所以在里面加一个
 * 填充字段就能把数据起始偏移推到对齐位置 —— **不用重压缩、不用碰数据字节**。
 * （外部 `zipalign` 用的是同一个手法）
 *
 * 具体做法与取舍：
 *
 * - 字段 id 用 **`0xd935`**（AOSP `zipalign` 用的就是它），载荷前 2 字节写
 *   **对齐值本身**（小端 uint16）—— `libziparchive` 读这个字段当"该条目对齐到几"。
 *   ⚠️ 本机**无法访问 AOSP 源码核对**（网络受限），所以按最保守解读写：写对齐值，
 *   不写 0。见 [padField] 的说明。
 * - 字段**放在最前面**：额外字段是从头扫的序列，放最前面才能保证被读到 ——
 *   aapt2 有时会给 `resources.arsc` 留一个**残缺**的额外字段（真机实测到 1 字节），
 *   残缺字节留在后面不影响我的字段。
 * - **中心目录里的额外字段原样保留**：数据偏移只由本地头决定，少改一处少一分风险，
 *   也能让产物不因"镜像一份额外字段"而悄悄变大。
 *
 * ## 三道自证（"我说对齐了"不算数）
 *
 * 1. **写完自检**：[check] 重新按本地头算一遍偏移，`stillMisaligned` 必须为 0
 * 2. **CRC 全量校验**：用 `ZipInputStream` 把每个条目读一遍（它是会验 CRC 的），
 *    确认字节级改写没有把包写坏
 * 3. **拒绝已签名的包**：包里有 v2/v3 签名块（`APK Sig Block 42`）时**直接报错**
 *    —— 对齐会移动字节，任何 v2 签名都会因此失效。对齐**必须**在签名之前，
 *    这是流水线顺序（`build_apk.sh` 里 zipalign 在 apksigner 之前），不是可选项。
 *
 * ## 幂等
 *
 * 二次对齐会先**剥掉**旧的填充字段再重算 ⇒ 文件不会一轮一轮地变大。
 */
class ZipAligner(rootPath: Path) {

    private val root: Path = rootPath.toAbsolutePath().normalize()

    /**
     * 对齐：`srcRel` → `dstRel`（**另写一个文件**，不动源包）。
     *
     * 之所以不原地改：对齐是字节级手术，失败时源包必须完好无损
     * —— 流水线里的 `base.apk` 重做一次 `prepare` 要几秒，但"包被写坏"
     * 会让失败原因完全指错方向。
     */
    fun align(srcRel: String, dstRel: String, pageAlignSharedLibs: Boolean = true): AlignOutcome {
        val src = PathGuard.resolve(root, srcRel)
        val dst = PathGuard.resolve(root, dstRel)
        require(Files.isRegularFile(src)) { "文件不存在：$srcRel" }
        require(src.normalize() != dst.normalize()) { "源与目标不能是同一个文件：$srcRel" }
        dst.parent?.let { Files.createDirectories(it) }

        val bytesIn = Files.size(src)
        var entries = 0
        var padded = 0

        RandomAccessFile(src.toFile(), "r").use { input ->
            val eocd = findEocd(input)
            if (hasApkSigningBlock(input, eocd.centralOffset)) {
                throw IllegalStateException(
                    "包里有 APK 签名块（APK Sig Block 42）—— 对齐会移动字节、令 v2/v3 签名失效。" +
                        "对齐必须发生在**签名之前**（流水线顺序：zipalign → apksigner）。",
                )
            }
            val list = readCentralDirectory(input, eocd)

            BufferedOutputStream(Files.newOutputStream(dst)).use { bos ->
                val out = CountingOutputStream(bos)
                val cd = ArrayList<CentralRecord>(list.size)
                for (e in list) {
                    val local = readLocalHeader(input, e)
                    val nameBytes = local.nameBytes
                    val base = stripPadding(local.extra)
                    val align = alignmentFor(e, pageAlignSharedLibs)

                    val here = out.position
                    val pad = if (align == 0) 0 else paddingLength((here + 30 + nameBytes.size + base.size) % align, align)
                    // ★ 我们的填充字段**放在最前面**：额外字段是一串 `id+长度+载荷`，
                    //   AOSP 的解析器从头扫、遇到 `0xd935` 就停。aapt2 有时会在
                    //   `resources.arsc` 上留一个**残缺**的额外字段（真机上实测到 1 字节，
                    //   它自己的对齐小把戏）—— 残缺字节留在后面不影响我的字段被读到。
                    val extra = if (pad == 0) base else padField(pad, align) + base
                    if (pad > 0) padded++

                    val headerAt = out.position
                    writeLocalHeader(out, e, nameBytes, extra)
                    require(out.position == headerAt + 30 + nameBytes.size + extra.size) { "本地头长度算错了" }
                    copyRange(input, local.dataOffset, out, e.compressedSize)
                    // 中心目录里的额外字段**原样保留**（不动它）：只有本地头决定数据偏移，
                    // 少改一处就少一分风险，也不会让包悄悄变大。
                    cd += CentralRecord(e, nameBytes, extra, e.centralExtra, headerAt)
                    entries++
                }

                val cdAt = out.position
                for (r in cd) writeCentralRecord(out, r)
                val cdSize = out.position - cdAt
                writeEocd(out, entries, cdSize, cdAt, eocd.comment)
                out.flush()
            }
        }

        val bytesOut = Files.size(dst)
        // ① 自证：重新按字节算一遍偏移
        val report = check(dst, pageAlignSharedLibs)
        require(report.ok) {
            "对齐失败（这是实现 bug，不是数据问题）：${report.summary()}"
        }
        // ② 自证：全量读一遍（ZipInputStream 会验 CRC），确认没有把包写坏
        verifyReadable(dst)

        return AlignOutcome(
            entries = entries,
            padded = padded,
            bytesIn = bytesIn,
            bytesOut = bytesOut,
            stillMisaligned = report.misaligned.size,
        )
    }

    /** 检查工作区里某个包的对齐情况（与 [align] 用的是同一套规则）。 */
    fun check(archiveRel: String, pageAlignSharedLibs: Boolean = true): AlignmentReport =
        check(PathGuard.resolve(root, archiveRel), pageAlignSharedLibs)

    private fun check(archive: Path, pageAlignSharedLibs: Boolean): AlignmentReport {
        require(Files.isRegularFile(archive)) { "文件不存在：$archive" }
        val bad = ArrayList<Pair<String, Long>>()
        var total = 0
        var checked = 0
        RandomAccessFile(archive.toFile(), "r").use { f ->
            val eocd = findEocd(f)
            for (e in readCentralDirectory(f, eocd)) {
                total++
                val align = alignmentFor(e, pageAlignSharedLibs)
                if (align == 0) continue
                checked++
                val local = readLocalHeader(f, e)
                if (local.dataOffset % align != 0L) bad += e.name to local.dataOffset
            }
        }
        return AlignmentReport(total, checked, bad)
    }

    // ------------------------------------------------------------------ 规则

    /** 该条目需要多少字节对齐；0 = 不需要动它。 */
    private fun alignmentFor(e: CentralEntry, pageAlignSharedLibs: Boolean): Int {
        if (e.method != METHOD_STORED) return 0
        if (e.compressedSize <= 0) return 0
        if (e.name.endsWith("/")) return 0
        if (pageAlignSharedLibs && e.name.endsWith(".so")) return PAGE_ALIGNMENT
        return ALIGNMENT
    }

    /**
     * 填充字段的总长度（含 4 字节的 id+长度头）。
     *
     * 要满足 `填充长度 ≡ 还差多少 (mod 对齐)`；在这个同余类里取**最小的、且够写载荷**的值。
     *
     * 为什么载荷至少要 2 字节：载荷里要写**对齐值本身**
     * （与 AOSP `zipalign` 的 `0xd935` 字段一个意思），写不下就只能再加一个对齐周期
     * —— 多花几个字节，换"读的人能看懂"，划算。
     */
    private fun paddingLength(remainder: Long, alignment: Int): Int {
        require(alignment >= 4) { "对齐值至少要 4（拿到 $alignment）" }
        val r = (remainder % alignment).toInt()
        if (r == 0) return 0
        var len = alignment - r // 1..alignment-1
        if (len < 4) len += alignment // 字段头 4 字节不能省
        if (len < 6) len += alignment // 载荷至少 2 字节（写对齐值）
        return len
    }

    /**
     * 构造填充字段：`id(2) + 长度(2) + 载荷`。
     *
     * 载荷前 2 字节是**对齐值**（小端 uint16），其余补 0 ——
     * 这正是 AOSP `zipalign` 用 `0xd935` 表达的东西（`libziparchive` 读它当"这个条目对齐到几"）。
     * ⚠️ 本机**无法访问 AOSP 源码核对**（网络受限），所以这条按"最保守解读"处理：
     *    写对齐值 ≠ 写 0；就算读的人不认，也只会得到"对齐 4"，不会得到一个荒唐的值。
     */
    private fun padField(len: Int, alignment: Int): ByteArray {
        require(len >= 6) { "填充字段至少要 6 字节（拿到 $len）" }
        val b = ByteArray(len)
        val bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
        bb.putShort(PADDING_FIELD_ID.toShort())
        bb.putShort((len - 4).toShort())
        bb.putShort(alignment.toShort())
        return b
    }

    /**
     * 剥掉本类以前插入的填充字段（幂等的前提）。
     *
     * 额外字段是 `id(2)+长度(2)+载荷` 的序列；按这个结构走一遍，跳过 [PADDING_FIELD_ID]。
     * 结构不合法（长度越界）就**原样返回** —— 宁可多插一次填充，也不去猜一个坏结构。
     */
    private fun stripPadding(extra: ByteArray): ByteArray {
        if (extra.isEmpty()) return extra
        val out = ArrayList<Byte>(extra.size)
        var i = 0
        while (i + 4 <= extra.size) {
            val id = ((extra[i].toInt() and 0xFF) or ((extra[i + 1].toInt() and 0xFF) shl 8))
            val len = ((extra[i + 2].toInt() and 0xFF) or ((extra[i + 3].toInt() and 0xFF) shl 8))
            if (i + 4 + len > extra.size) return extra // 结构坏了：原样保留
            if (id != PADDING_FIELD_ID) {
                for (k in i until i + 4 + len) out += extra[k]
            }
            i += 4 + len
        }
        if (i != extra.size) return extra // 尾部有残渣：原样保留
        return out.toByteArray()
    }

    // ------------------------------------------------------------------ 解析

    private fun readLocalHeader(f: RandomAccessFile, e: CentralEntry): LocalHeader {
        f.seek(e.localHeaderOffset)
        val head = ByteArray(30)
        f.readFully(head)
        val bb = ByteBuffer.wrap(head).order(ByteOrder.LITTLE_ENDIAN)
        val sig = bb.int.toLong() and 0xFFFFFFFFL
        require(sig == SIGNATURE_LOCAL) {
            "本地头签名不对（条目 ${e.name}，偏移 ${e.localHeaderOffset}，拿到 0x%08x）".format(sig)
        }
        bb.position(26)
        val nameLen = bb.short.toInt() and 0xFFFF
        val extraLen = bb.short.toInt() and 0xFFFF
        val nameBytes = ByteArray(nameLen)
        val extra = ByteArray(extraLen)
        f.readFully(nameBytes)
        f.readFully(extra)
        return LocalHeader(nameBytes, extra, e.localHeaderOffset + 30 + nameLen + extraLen)
    }

    private fun readCentralDirectory(f: RandomAccessFile, eocd: Eocd): List<CentralEntry> {
        f.seek(eocd.centralOffset)
        val buf = ByteArray(eocd.centralSize.toInt())
        f.readFully(buf)
        val bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
        val list = ArrayList<CentralEntry>(eocd.centralCount)
        repeat(eocd.centralCount) {
            val sig = bb.int.toLong() and 0xFFFFFFFFL
            require(sig == SIGNATURE_CENTRAL) { "中心目录记录签名不对（拿到 0x%08x）".format(sig) }
            val versionMadeBy = bb.short.toInt() and 0xFFFF
            val versionNeeded = bb.short.toInt() and 0xFFFF
            val flags = bb.short.toInt() and 0xFFFF
            val method = bb.short.toInt() and 0xFFFF
            val time = bb.short.toInt() and 0xFFFF
            val date = bb.short.toInt() and 0xFFFF
            val crc = bb.int.toLong() and 0xFFFFFFFFL
            val csize = bb.int.toLong() and 0xFFFFFFFFL
            val size = bb.int.toLong() and 0xFFFFFFFFL
            val nameLen = bb.short.toInt() and 0xFFFF
            val extraLen = bb.short.toInt() and 0xFFFF
            val commentLen = bb.short.toInt() and 0xFFFF
            val diskStart = bb.short.toInt() and 0xFFFF
            val internalAttrs = bb.short.toInt() and 0xFFFF
            val externalAttrs = bb.int.toLong() and 0xFFFFFFFFL
            val localOffset = bb.int.toLong() and 0xFFFFFFFFL
            require(!isZip64(csize) && !isZip64(size) && !isZip64(localOffset)) {
                "不支持 zip64（条目过大或偏移超 4GB）—— 手机上的 APK 不该有这种情况"
            }
            val nameBytes = ByteArray(nameLen).also { bb.get(it) }
            val extra = ByteArray(extraLen).also { bb.get(it) }
            val comment = ByteArray(commentLen).also { bb.get(it) }
            list += CentralEntry(
                name = String(nameBytes, Charsets.UTF_8),
                versionMadeBy = versionMadeBy,
                versionNeeded = versionNeeded,
                // ★ 清掉 bit 3（"长度写在数据描述符里"）：我们会把真实长度写进本地头，
                //   于是数据描述符不再需要 —— 少一份可能与长度不一致的副本。
                flags = flags and (FLAG_DATA_DESCRIPTOR.inv()),
                method = method,
                time = time,
                date = date,
                crc = crc,
                compressedSize = csize,
                size = size,
                diskStart = diskStart,
                internalAttrs = internalAttrs,
                externalAttrs = externalAttrs,
                localHeaderOffset = localOffset,
                comment = comment,
                centralExtra = extra,
            )
        }
        return list
    }

    /** 找中央目录结束记录（EOCD）：从尾部往前扫，最多 64KB 注释。 */
    private fun findEocd(f: RandomAccessFile): Eocd {
        val fileLen = f.length()
        require(fileLen >= 22) { "文件太小，不可能是 zip（$fileLen 字节）" }
        val scan = minOf(fileLen, 22L + 65535L).toInt()
        val buf = ByteArray(scan)
        f.seek(fileLen - scan)
        f.readFully(buf)
        for (i in scan - 22 downTo 0) {
            if (buf[i] != 0x50.toByte() || buf[i + 1] != 0x4B.toByte() ||
                buf[i + 2] != 0x05.toByte() || buf[i + 3] != 0x06.toByte()
            ) {
                continue
            }
            val bb = ByteBuffer.wrap(buf, i, 22).order(ByteOrder.LITTLE_ENDIAN)
            bb.int
            val disk = bb.short.toInt() and 0xFFFF
            val cdDisk = bb.short.toInt() and 0xFFFF
            val count = bb.short.toInt() and 0xFFFF
            val cdCount = bb.short.toInt() and 0xFFFF
            val cdSize = bb.int.toLong() and 0xFFFFFFFFL
            val cdOffset = bb.int.toLong() and 0xFFFFFFFFL
            val commentLen = bb.short.toInt() and 0xFFFF
            if (i + 22 + commentLen > scan) continue // 注释长度对不上 ⇒ 不是真 EOCD
            require(disk == 0 && cdDisk == 0) { "不支持分卷 zip（disk=$disk）" }
            require(count != 0xFFFF && cdCount != 0xFFFF && cdSize != 0xFFFFFFFFL && cdOffset != 0xFFFFFFFFL) {
                "不支持 zip64（EOCD 里带 0xFFFF/0xFFFFFFFF 标记）"
            }
            return Eocd(count, cdCount, cdSize, cdOffset, buf.copyOfRange(i + 22, i + 22 + commentLen))
        }
        throw IllegalStateException("找不到中央目录结束记录（EOCD）—— 这不是一个 zip/APK 文件")
    }

    /**
     * 是否带 APK 签名块（v2/v3）。
     *
     * 签名块紧贴在中央目录之前，**最后 16 字节固定是 ASCII `APK Sig Block 42`**，
     * 所以只需要看那 16 个字节 —— 不需要把整个块解出来。
     */
    internal fun hasApkSigningBlock(f: RandomAccessFile, centralOffset: Long): Boolean {
        if (centralOffset < SIGNING_BLOCK_MAGIC.size) return false
        f.seek(centralOffset - SIGNING_BLOCK_MAGIC.size)
        val tail = ByteArray(SIGNING_BLOCK_MAGIC.size)
        f.readFully(tail)
        return tail.contentEquals(SIGNING_BLOCK_MAGIC)
    }

    // ------------------------------------------------------------------ 写出

    private fun writeLocalHeader(out: CountingOutputStream, e: CentralEntry, name: ByteArray, extra: ByteArray) {
        val bb = ByteBuffer.allocate(30).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(SIGNATURE_LOCAL.toInt())
        bb.putShort(e.versionNeeded.toShort())
        bb.putShort(e.flags.toShort())
        bb.putShort(e.method.toShort())
        bb.putShort(e.time.toShort())
        bb.putShort(e.date.toShort())
        bb.putInt(e.crc.toInt())
        bb.putInt(e.compressedSize.toInt())
        bb.putInt(e.size.toInt())
        bb.putShort(name.size.toShort())
        bb.putShort(extra.size.toShort())
        out.write(bb.array())
        out.write(name)
        out.write(extra)
    }

    private fun writeCentralRecord(out: CountingOutputStream, r: CentralRecord) {
        val e = r.entry
        val bb = ByteBuffer.allocate(46).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(SIGNATURE_CENTRAL.toInt())
        bb.putShort(e.versionMadeBy.toShort())
        bb.putShort(e.versionNeeded.toShort())
        bb.putShort(e.flags.toShort())
        bb.putShort(e.method.toShort())
        bb.putShort(e.time.toShort())
        bb.putShort(e.date.toShort())
        bb.putInt(e.crc.toInt())
        bb.putInt(e.compressedSize.toInt())
        bb.putInt(e.size.toInt())
        bb.putShort(r.name.size.toShort())
        bb.putShort(r.centralExtra.size.toShort())
        bb.putShort(e.comment.size.toShort())
        bb.putShort(e.diskStart.toShort())
        bb.putShort(e.internalAttrs.toShort())
        bb.putInt(e.externalAttrs.toInt())
        bb.putInt(r.localOffset.toInt())
        out.write(bb.array())
        out.write(r.name)
        out.write(r.centralExtra)
        out.write(e.comment)
    }

    private fun writeEocd(out: CountingOutputStream, count: Int, cdSize: Long, cdOffset: Long, comment: ByteArray) {
        val bb = ByteBuffer.allocate(22).order(ByteOrder.LITTLE_ENDIAN)
        bb.putInt(SIGNATURE_EOCD.toInt())
        bb.putShort(0.toShort())
        bb.putShort(0.toShort())
        bb.putShort(count.toShort())
        bb.putShort(count.toShort())
        bb.putInt(cdSize.toInt())
        bb.putInt(cdOffset.toInt())
        bb.putShort(comment.size.toShort())
        out.write(bb.array())
        out.write(comment)
    }

    /** 原样搬运 `[from, from+len)` 区间（**不重压缩**，逐字节复制压缩流）。 */
    private fun copyRange(input: RandomAccessFile, from: Long, out: OutputStream, len: Long) {
        input.seek(from)
        val buf = ByteArray(COPY_BUFFER)
        var left = len
        while (left > 0) {
            val n = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            require(n > 0) { "读取源包时提前结束（还差 $left 字节）" }
            out.write(buf, 0, n)
            left -= n
        }
    }

    /** 全量读一遍：`ZipInputStream` 会逐条验 CRC，能抓出字节级改写引入的损坏。 */
    private fun verifyReadable(archive: Path) {
        var n = 0
        ZipInputStream(Files.newInputStream(archive)).use { zin ->
            while (true) {
                val e: ZipEntry = zin.nextEntry ?: break
                val sink = ByteArray(COPY_BUFFER)
                while (zin.read(sink) >= 0) { /* 读到底就会触发 CRC 校验 */ }
                n++
                zin.closeEntry()
            }
        }
        // 再用 ZipFile 对一遍条目数：两个独立实现看到同样的条目，才说明结构没坏
        ZipFile(archive.toFile()).use { zf -> require(zf.size() == n) { "条目数不一致：ZipFile=${zf.size()} ZipInputStream=$n" } }
    }

    private fun isZip64(v: Long): Boolean = v == 0xFFFFFFFFL

    // ------------------------------------------------------------------ 内部类型

    /** 输出流包一层计数（`BufferedOutputStream` 没有 `position()`）。 */
    private class CountingOutputStream(private val out: OutputStream) : OutputStream() {
        var position: Long = 0
            private set

        override fun write(b: Int) {
            out.write(b)
            position++
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            out.write(b, off, len)
            position += len
        }

        override fun flush() = out.flush()
        override fun close() = out.close()
    }

    private class CentralEntry(
        val name: String,
        val versionMadeBy: Int,
        val versionNeeded: Int,
        val flags: Int,
        val method: Int,
        val time: Int,
        val date: Int,
        val crc: Long,
        val compressedSize: Long,
        val size: Long,
        val diskStart: Int,
        val internalAttrs: Int,
        val externalAttrs: Long,
        val localHeaderOffset: Long,
        val comment: ByteArray,
        /** 中心目录里的额外字段（**原样保留**，不参与对齐） */
        val centralExtra: ByteArray,
    )

    private class CentralRecord(
        val entry: CentralEntry,
        val name: ByteArray,
        /** 本地头里用的额外字段（含我们的填充） */
        val localExtra: ByteArray,
        /** 中心目录里用的额外字段（原样） */
        val centralExtra: ByteArray,
        val localOffset: Long,
    )

    private class LocalHeader(val nameBytes: ByteArray, val extra: ByteArray, val dataOffset: Long)

    private class Eocd(
        val entryCount: Int,
        val centralCount: Int,
        val centralSize: Long,
        val centralOffset: Long,
        val comment: ByteArray,
    )

    companion object {
        /** 默认对齐（同 `zipalign -a 4`） */
        const val ALIGNMENT = 4

        /** `.so` 的页对齐（同 `zipalign -p`） */
        const val PAGE_ALIGNMENT = 4096

        /** 填充字段的 id（与外部 `zipalign` 用的一致） */
        private const val PADDING_FIELD_ID = 0xD935

        private const val METHOD_STORED = 0

        /** 通用标志位 3：长度写在数据描述符里 */
        private const val FLAG_DATA_DESCRIPTOR = 0x0008

        private const val SIGNATURE_LOCAL = 0x04034B50L
        private const val SIGNATURE_CENTRAL = 0x02014B50L
        private const val SIGNATURE_EOCD = 0x06054B50L
        private val SIGNING_BLOCK_MAGIC = "APK Sig Block 42".toByteArray(Charsets.US_ASCII)

        private const val COPY_BUFFER = 64 * 1024
    }
}
