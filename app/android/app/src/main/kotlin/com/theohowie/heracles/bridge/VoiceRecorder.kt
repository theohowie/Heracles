package com.theohowie.heracles.bridge

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
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
 * 权限口径：RECORD_AUDIO 未授权直接回错误 map，不在这里弹
 * 申请（申请走权限页 / Dart 侧 requestPermission 的既有链）。
 * 一次只允许一段录音：重复 start 先把上一段作废。
 */
class VoiceRecorder(private val activity: Activity) {

    companion object {
        const val SAMPLE_RATE = 16000
    }

    private var recorder: AudioRecord? = null
    private var worker: Thread? = null
    @Volatile private var capturing = false
    private var pcmFile: File? = null
    private var startedAtMs = 0L

    val isRecording: Boolean get() = capturing

    /** 开始录音。回 {ok:true} 或 {ok:false,error}。 */
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
                maxOf(minBuffer, 4096),
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
        recorder = rec
        pcmFile = pcm
        capturing = true
        startedAtMs = System.currentTimeMillis()
        rec.startRecording()
        worker = thread(name = "heracles-voice-recorder") {
            val out = FileOutputStream(pcm)
            val buffer = ByteArray(4096)
            try {
                while (capturing) {
                    val n = rec.read(buffer, 0, buffer.size)
                    if (n > 0) out.write(buffer, 0, n)
                    else if (n < 0) break
                }
            } catch (_: Exception) {
                // 停录时 read 被打断属正常收尾，数据以文件为准。
            } finally {
                runCatching { out.flush() }
                runCatching { out.close() }
            }
        }
        return mapOf("ok" to true)
    }

    /**
     * 停止录音并封 WAV。回 pickFiles 同形状
     * {ok:true, path, name, size, durationMs}。
     */
    fun stop(): Map<String, Any?> {
        val pcm = pcmFile
        if (!capturing || pcm == null) {
            return mapOf("ok" to false, "error" to "现在没有在录音")
        }
        stopInternal(discard = false)
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
        )
    }

    /** 放弃当前录音（如果有）。 */
    fun cancel(): Map<String, Any?> {
        stopInternal(discard = true)
        return mapOf("ok" to true)
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
