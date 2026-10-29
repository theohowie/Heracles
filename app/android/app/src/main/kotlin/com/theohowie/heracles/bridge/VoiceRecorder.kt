package com.theohowie.heracles.bridge

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * **麦克风录音**（2026-10-29，语音识别用）—— AudioRecord 录
 * 16kHz / 单声道 / PCM16，停时封成标准 WAV 交回 Dart 侧喂
 * sherpa-onnx。录音文件只进 cache/voice，不落用户目录。
 *
 * ## 2026-10-29 追加：边录边发 PCM 分片（流式语音，方案 A）
 *
 * 契约见 `docs/INTERFACE.md` §N13.2。除写文件外，录音线程把每片
 * **≈100ms**（16000Hz × 2 字节 × 0.1s = 3200 字节）的 PCM 通过
 * `EventChannel('heracles/voice')` 发给 Dart：
 *
 * ```text
 * {type:"chunk", sessionId, seq, pcm:ByteArray, sampleRate:16000}
 * {type:"end",   sessionId, seq}   // 正常结束（stop）；cancel 不发
 * ```
 *
 * 三条硬约束：
 * 1. **旧三方法语义不变**：`start`/`stop`/`cancel` 的返回 map 与旧版
 *    一致（`start` 只**增**了 `sessionId`/`sampleRate`/`chunkBytes`
 *    三个字段，旧 Dart 忽略即可）；`stop` 照旧封 WAV 并回文件信息。
 * 2. **取消立即停发**：事件先进主线程队列（Flutter 的 EventSink 要求
 *    主线程），出队时核对[generation] —— `cancel` 先自增代次再停录，
 *    已排队的片段也会被丢弃，不会在取消后漏出去。
 * 3. **没有订阅者时退化成旧行为**：`eventSink == null` 就只写文件。
 *
 * 权限口径不变：RECORD_AUDIO 未授权直接回错误 map，不在这里弹申请
 * （申请走权限页 / Dart 侧 requestPermission 的既有链）。一次只允许
 * 一段录音：重复 start 先把上一段作废。
 */
class VoiceRecorder(private val activity: Activity) {

    companion object {
        const val SAMPLE_RATE = 16000

        /** 一片 ≈100ms：16000 采样/秒 × 2 字节/采样 ÷ 10。 */
        const val CHUNK_BYTES = 3200

        /** Kotlin → Dart 的流式分片事件通道（§N13.2）。 */
        const val EVENT_CHANNEL = "heracles/voice"
    }

    private var recorder: AudioRecord? = null
    private var worker: Thread? = null
    @Volatile private var capturing = false
    private var pcmFile: File? = null
    private var startedAtMs = 0L

    /** EventChannel 的 sink（Dart 未订阅时 null ⇒ 只写文件 = 旧行为）。 */
    @Volatile private var eventSink: EventChannel.EventSink? = null

    /** 事件投递必须回主线程（Flutter 的 `EventSink` 是 `@UiThread`）。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 当前录音会话的**代次**，每次 start/cancel 自增。
     *
     * 分片事件是「录音线程 post → 主线程跑」的两段式，`cancel` 之后
     * 队列里可能还压着几片；出队时比对代次就能把它们全部丢掉 ⇒
     * 「取消立即停发」不依赖录音线程恰好在那一刻收手。
     */
    @Volatile private var generation = 0L

    /** 本次会话 id（发给 Dart，用于丢弃旧会话的迟到事件）。 */
    private var sessionId: String? = null

    /** 本次会话已发出的分片数（**单调递增，从 0 开始**）。 */
    private var seq = 0

    val isRecording: Boolean get() = capturing

    /** EventChannel 的 StreamHandler 绑定/解绑 sink（由 MainActivity 调用）。 */
    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    /** 开始录音。回 {ok:true, sessionId, sampleRate, chunkBytes} 或 {ok:false,error}。 */
    fun start(): Map<String, Any?> {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return mapOf("ok" to false, "error" to "麦克风权限未开启")
        }
        stopInternal(discard = true)
        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) {
            return mapOf("ok" to false, "error" to "这台设备不支持 16kHz 单声道录音")
        }
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, CHUNK_BYTES * 2),
            )
        } catch (e: Exception) {
            return mapOf(
                "ok" to false,
                "error" to "无法打开麦克风（${e.javaClass.simpleName}：${e.message ?: "未知原因"}）",
            )
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            runCatching { rec.release() }
            return mapOf("ok" to false, "error" to "麦克风初始化失败")
        }
        val dir = File(activity.cacheDir, "voice").apply { mkdirs() }
        val pcm = File(dir, "rec-${System.currentTimeMillis()}.pcm")
        val gen = ++generation
        val session = "v${System.currentTimeMillis()}-$gen"
        sessionId = session
        seq = 0
        recorder = rec
        pcmFile = pcm
        capturing = true
        startedAtMs = System.currentTimeMillis()
        rec.startRecording()
        worker = thread(name = "heracles-voice-recorder") {
            val out = FileOutputStream(pcm)
            // 读满 3200 字节再发一片（≈100ms）；读不满（停录/异常）也照发，
            // 不攒着 —— 攒着会让「边说边出字」整体晚一个窗口。
            val buffer = ByteArray(CHUNK_BYTES)
            try {
                while (capturing) {
                    val n = rec.read(buffer, 0, buffer.size)
                    if (n > 0) {
                        out.write(buffer, 0, n)
                        emitChunk(gen, session, if (n == buffer.size) buffer else buffer.copyOf(n))
                    } else if (n < 0) break
                }
            } catch (_: Exception) {
                // 停录时 read 被打断属正常收尾，数据以文件为准。
            } finally {
                runCatching { out.flush() }
                runCatching { out.close() }
            }
        }
        return mapOf(
            "ok" to true,
            "sessionId" to session,
            "sampleRate" to SAMPLE_RATE,
            "chunkBytes" to CHUNK_BYTES,
        )
    }

    /**
     * 停止录音并封 WAV。回 pickFiles 同形状
     * {ok:true, path, name, size, durationMs, sessionId}；同时发
     * `{type:"end", sessionId, seq}`。
     */
    fun stop(): Map<String, Any?> {
        val pcm = pcmFile
        if (!capturing || pcm == null) {
            return mapOf("ok" to false, "error" to "现在没有在录音")
        }
        val session = sessionId ?: ""
        val gen = generation
        stopInternal(discard = false)
        // 录音线程已 join ⇒ 最后的 chunk 已入主线程队列，end 排在它们后面
        // （同一个 Handler 队列，FIFO），Dart 不会先收到 end 再收尾片。
        emitEnd(gen, session)
        sessionId = null
        val durationMs = System.currentTimeMillis() - startedAtMs
        if (!pcm.exists() || pcm.length() < 3200) { // < 0.1 秒视为没录到
            runCatching { pcm.delete() }
            return mapOf("ok" to false, "error" to "录音太短，没录到声音")
        }
        val wav = File(pcm.parentFile, pcm.nameWithoutExtension + ".wav")
        writeWav(pcm, wav)
        runCatching { pcm.delete() }
        return mapOf(
            "ok" to true,
            "path" to wav.absolutePath,
            "name" to wav.name,
            "size" to wav.length(),
            "durationMs" to durationMs,
            "sessionId" to session,
        )
    }

    /** 放弃当前录音（如果有）。**不发 end**；已排队的分片一并作废。 */
    fun cancel(): Map<String, Any?> {
        // 先让代次失效：队列里已 post 的分片出队时会被丢弃。
        generation++
        sessionId = null
        stopInternal(discard = true)
        return mapOf("ok" to true)
    }

    // ------------------------------------------------------------ 事件投递

    /** 发一片 PCM（在录音线程调用；实际发送在主线程）。 */
    private fun emitChunk(gen: Long, session: String, pcm: ByteArray) {
        val sink = eventSink ?: return
        val s = seq++
        mainHandler.post {
            if (gen != generation) return@post
            runCatching {
                sink.success(
                    mapOf(
                        "type" to "chunk",
                        "sessionId" to session,
                        "seq" to s,
                        "pcm" to pcm,
                        "sampleRate" to SAMPLE_RATE,
                    ),
                )
            }
        }
    }

    /** 发 end（在 [stop] 里主线程调用，紧跟在同一队列尾部）。 */
    private fun emitEnd(gen: Long, session: String) {
        val sink = eventSink ?: return
        mainHandler.post {
            if (gen != generation) return@post
            runCatching {
                sink.success(
                    mapOf(
                        "type" to "end",
                        "sessionId" to session,
                        "seq" to seq,
                    ),
                )
            }
        }
    }

    private fun stopInternal(discard: Boolean) {
        if (!capturing && recorder == null) return
        capturing = false
        runCatching { recorder?.stop() }
        runCatching { worker?.join(800) }
        runCatching { recorder?.release() }
        recorder = null
        worker = null
        if (discard) {
            runCatching { pcmFile?.delete() }
            pcmFile = null
        }
    }

    /** PCM16 裸数据 → 标准 44 字节头 WAV。 */
    private fun writeWav(pcm: File, wav: File) {
        val pcmBytes = pcm.readBytes()
        val dataLen = pcmBytes.size
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(36 + dataLen)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)
        header.putShort(1) // PCM
        header.putShort(1) // 单声道
        header.putInt(SAMPLE_RATE)
        header.putInt(SAMPLE_RATE * 2) // byte rate
        header.putShort(2) // block align
        header.putShort(16) // bits per sample
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(dataLen)
        RandomAccessFile(wav, "rw").use { raf ->
            raf.setLength(0)
            raf.write(header.array())
            raf.write(pcmBytes)
        }
    }
}
