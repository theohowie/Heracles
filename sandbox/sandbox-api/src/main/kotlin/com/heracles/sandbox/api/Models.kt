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
 */

package com.heracles.sandbox.api

import android.os.Parcel
import android.os.Parcelable

/**
 * 路径视角 —— 沙箱里**最容易出错**的一个概念，所以做成显式类型而不是注释。
 *
 * <p>同一个字符串（如 `/data/data/com.example/app.bin`）在两套语义下指向**不同文件**：
 *
 * <ul>
 *   <li>{@link #HOST}：**宿主进程视角**。真实 Android 文件系统路径。
 *       沙箱的零宽通道（ZeroWidthFileChannel）直接按这个路径打开文件；
 *       在普通 App 身份下，能读到本 App 可读的一切，以及通过零宽通道
 *       穿透到的其它 App data 目录。</li>
 *   <li>{@link #SANDBOX}：**PRoot 根文件系统内视角**。`/workspace`、`/usr/bin/...`
 *       这些路径只有在 PRoot 的 `-b` 绑定建立之后才存在。宿主进程自己是
 *       **看不见** `/workspace` 的 —— 它实际长在
 *       `{app.filesDir}/sandbox/rootfs/workspace`。</li>
 * </ul>
 *
 * <p>两者叠加是 taixu 的 PRoot 绑定与 baicodex 的零宽通道合流时最大的坑：
 * `execute` 里跑的 `cat /data/data/x` 走的是**沙箱视角**（被 PRoot 重写），
 * 而 `readFile` 传同一个字符串走的是**宿主视角**。两者能读到的范围不同，
 * 结果也可能不同。因此本类必须显式传参，禁止默认值。
 */
enum class PathView(val wireValue: Int) {
    /**
     * 宿主进程视角：真实 Android 文件系统路径。
     *
     * <p>零宽通道只在这个视角下生效。
     */
    HOST(0),

    /**
     * 沙箱视角：PRoot 根文件系统内的路径。
     *
     * <p>由 runtime 通过 `ProotEngine.toHostPath()` 映射到宿主路径再落盘。
     * 沙箱视角**不经过**零宽通道 —— 它的能力边界由 PRoot 绑定决定。
     */
    SANDBOX(1),
    ;

    companion object {
        /** AIDL 的 `int pathView` 转枚举；非法值抛 [SandboxException.CODE_INVALID_ARGUMENT]。 */
        @JvmStatic
        fun fromWire(value: Int): PathView =
            entries.firstOrNull { it.wireValue == value }
                ?: throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "未知的 pathView: $value（只接受 0=HOST / 1=SANDBOX）",
                )
    }
}

/**
 * 一次执行请求。
 *
 * <p>{@code command} 由 rootfs 内的 `/bin/sh -c` 解释，因此可以带管道与重定向。
 * {@code workingDirectory} 是**沙箱视角**路径。
 */
data class ExecutionRequest(
    val command: String,
    val workingDirectory: String = "/workspace",
    val environment: List<String> = emptyList(),
    val timeoutMillis: Long = 0L,
    val usePty: Boolean = false,
    val ptyColumns: Int = 80,
    val ptyRows: Int = 24,
    /** -1 表示自动选路（ChannelSelector 决定）。 */
    val channelType: Int = -1,
    /** 一次性写入 PTY 的标准输入；空串表示不喂。 */
    val inputData: String = "",
) : Parcelable {

    init {
        if (command.isBlank()) {
            throw SandboxException(SandboxException.CODE_INVALID_ARGUMENT, "command 不能为空")
        }
    }

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeString(command)
        dest.writeString(workingDirectory)
        dest.writeStringList(environment)
        dest.writeLong(timeoutMillis)
        dest.writeInt(if (usePty) 1 else 0)
        dest.writeInt(ptyColumns)
        dest.writeInt(ptyRows)
        dest.writeInt(channelType)
        dest.writeString(inputData)
    }

    override fun describeContents(): Int = 0

    companion object CREATOR : Parcelable.Creator<ExecutionRequest> {
        override fun createFromParcel(parcel: Parcel) = ExecutionRequest(
            command = parcel.readString().orEmpty(),
            workingDirectory = parcel.readString().orEmpty(),
            environment = parcel.createStringArrayList().orEmpty(),
            timeoutMillis = parcel.readLong(),
            usePty = parcel.readInt() != 0,
            ptyColumns = parcel.readInt(),
            ptyRows = parcel.readInt(),
            channelType = parcel.readInt(),
            inputData = parcel.readString().orEmpty(),
        )

        override fun newArray(size: Int) = arrayOfNulls<ExecutionRequest>(size)
    }
}

/**
 * 一次执行的最终结果。
 *
 * <p>{@code stdout}/{@code stderr} 是聚合且可能被截断的文本；
 * 流式增量以 [IExecutionCallback.onOutput] 为准。
 */
data class ExecutionResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
    val durationMillis: Long,
    val timedOut: Boolean,
    val cancelled: Boolean,
    val truncated: Boolean,
    val channelType: Int,
) : Parcelable {

    /** 是否「正常成功」（退出码 0 且没超时/取消）。 */
    val isSuccess: Boolean get() = exitCode == 0 && !timedOut && !cancelled

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeInt(exitCode)
        dest.writeString(stdout)
        dest.writeString(stderr)
        dest.writeLong(durationMillis)
        dest.writeInt(if (timedOut) 1 else 0)
        dest.writeInt(if (cancelled) 1 else 0)
        dest.writeInt(if (truncated) 1 else 0)
        dest.writeInt(channelType)
    }

    override fun describeContents(): Int = 0

    companion object CREATOR : Parcelable.Creator<ExecutionResult> {
        override fun createFromParcel(parcel: Parcel) = ExecutionResult(
            exitCode = parcel.readInt(),
            stdout = parcel.readString().orEmpty(),
            stderr = parcel.readString().orEmpty(),
            durationMillis = parcel.readLong(),
            timedOut = parcel.readInt() != 0,
            cancelled = parcel.readInt() != 0,
            truncated = parcel.readInt() != 0,
            channelType = parcel.readInt(),
        )

        override fun newArray(size: Int) = arrayOfNulls<ExecutionResult>(size)
    }
}

/** 一次文件读写的结果。 */
data class FileResult(
    val success: Boolean,
    val path: String,
    val data: ByteArray?,
    val size: Long,
    val lastModified: Long,
    val pathView: Int,
    val errorCode: Int,
    val errorMessage: String,
) : Parcelable {

    /** 成功且带内容时的文本视图（UTF-8）；非文本文件不要用。 */
    fun asText(): String = data?.toString(Charsets.UTF_8).orEmpty()

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeInt(if (success) 1 else 0)
        dest.writeString(path)
        dest.writeByteArray(data)
        dest.writeLong(size)
        dest.writeLong(lastModified)
        dest.writeInt(pathView)
        dest.writeInt(errorCode)
        dest.writeString(errorMessage)
    }

    override fun describeContents(): Int = 0

    companion object CREATOR : Parcelable.Creator<FileResult> {
        override fun createFromParcel(parcel: Parcel) = FileResult(
            success = parcel.readInt() != 0,
            path = parcel.readString().orEmpty(),
            data = parcel.createByteArray(),
            size = parcel.readLong(),
            lastModified = parcel.readLong(),
            pathView = parcel.readInt(),
            errorCode = parcel.readInt(),
            errorMessage = parcel.readString().orEmpty(),
        )

        override fun newArray(size: Int) = arrayOfNulls<FileResult>(size)
    }
}

/** 一个执行通道的可用性与风险描述。 */
data class ChannelInfo(
    val type: Int,
    val displayName: String,
    val available: Boolean,
    val unavailableReason: String,
    val missingPrerequisites: List<String>,
    val riskLevel: Int,
    val capabilitySummary: String,
    val supportsPty: Boolean,
    val supportsCrossAppData: Boolean,
    val executionIdentity: String,
) : Parcelable {

    val channelType: ChannelType? get() = ChannelType.entries.getOrNull(type)
    val risk: RiskLevel? get() = RiskLevel.entries.getOrNull(riskLevel)

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeInt(type)
        dest.writeString(displayName)
        dest.writeInt(if (available) 1 else 0)
        dest.writeString(unavailableReason)
        dest.writeStringList(missingPrerequisites)
        dest.writeInt(riskLevel)
        dest.writeString(capabilitySummary)
        dest.writeInt(if (supportsPty) 1 else 0)
        dest.writeInt(if (supportsCrossAppData) 1 else 0)
        dest.writeString(executionIdentity)
    }

    override fun describeContents(): Int = 0

    companion object CREATOR : Parcelable.Creator<ChannelInfo> {
        override fun createFromParcel(parcel: Parcel) = ChannelInfo(
            type = parcel.readInt(),
            displayName = parcel.readString().orEmpty(),
            available = parcel.readInt() != 0,
            unavailableReason = parcel.readString().orEmpty(),
            missingPrerequisites = parcel.createStringArrayList().orEmpty(),
            riskLevel = parcel.readInt(),
            capabilitySummary = parcel.readString().orEmpty(),
            supportsPty = parcel.readInt() != 0,
            supportsCrossAppData = parcel.readInt() != 0,
            executionIdentity = parcel.readString().orEmpty(),
        )

        override fun newArray(size: Int) = arrayOfNulls<ChannelInfo>(size)
    }
}

/** rootfs 当前状态。 */
data class RootfsStatus(
    val installed: Boolean,
    val source: Int,
    val label: String,
    val ociRef: String,
    val sizeBytes: Long,
    val snapshotName: String,
    val snapshotCount: Int,
    val rootfsPath: String,
) : Parcelable {

    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeInt(if (installed) 1 else 0)
        dest.writeInt(source)
        dest.writeString(label)
        dest.writeString(ociRef)
        dest.writeLong(sizeBytes)
        dest.writeString(snapshotName)
        dest.writeInt(snapshotCount)
        dest.writeString(rootfsPath)
    }

    override fun describeContents(): Int = 0

    companion object {
        const val SOURCE_NONE = 0
        const val SOURCE_BUNDLED = 1
        const val SOURCE_OCI = 2

        val NOT_INSTALLED = RootfsStatus(
            installed = false,
            source = SOURCE_NONE,
            label = "",
            ociRef = "",
            sizeBytes = -1L,
            snapshotName = "",
            snapshotCount = 0,
            rootfsPath = "",
        )

        @JvmField
        val CREATOR: Parcelable.Creator<RootfsStatus> = object : Parcelable.Creator<RootfsStatus> {
            override fun createFromParcel(parcel: Parcel) = RootfsStatus(
                installed = parcel.readInt() != 0,
                source = parcel.readInt(),
                label = parcel.readString().orEmpty(),
                ociRef = parcel.readString().orEmpty(),
                sizeBytes = parcel.readLong(),
                snapshotName = parcel.readString().orEmpty(),
                snapshotCount = parcel.readInt(),
                rootfsPath = parcel.readString().orEmpty(),
            )

            override fun newArray(size: Int) = arrayOfNulls<RootfsStatus>(size)
        }
    }
}
