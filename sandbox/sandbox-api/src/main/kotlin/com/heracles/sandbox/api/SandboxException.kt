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

/**
 * 沙箱错误码与异常。
 *
 * <p>跨进程时错误码通过 {@code IExecutionCallback.onError} 或
 * {@code FileResult.errorCode} 传递；同进程直接抛本异常。
 * <b>错误码是契约的一部分</b>：宿主按码分支比按文案匹配稳。
 */
open class SandboxException(
    val code: Int,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause) {

    companion object {
        /** 参数非法（空命令、越界路径、不支持的 pathView…）。 */
        const val CODE_INVALID_ARGUMENT = 1

        /** rootfs 还没装（既没 OCI 也没内置解包）。 */
        const val CODE_ROOTFS_NOT_READY = 2

        /** rootfs 解包/校验失败。 */
        const val CODE_ROOTFS_CORRUPT = 3

        /** 指定的通道当前不可用（前置条件不满足）。 */
        const val CODE_CHANNEL_UNAVAILABLE = 4

        /** 没有可用通道。 */
        const val CODE_NO_CHANNEL = 5

        /** 并发超限（前台有界命令通道已满）。 */
        const val CODE_BUSY = 6

        /** 沙箱自身 I/O 失败。 */
        const val CODE_IO = 7

        /** 执行超时。 */
        const val CODE_TIMEOUT = 8

        /** 被宿主取消。 */
        const val CODE_CANCELLED = 9

        /** 沙箱内部错误（不应发生；带堆栈）。 */
        const val CODE_INTERNAL = 10

        /** 网络不可用（OCI 拉取、ADB 配对需要网络/端口）。 */
        const val CODE_NETWORK = 11

        /**
         * 引用了**未注册**的逻辑挂载名（如 `@nope/x`）。
         *
         * ⚠️ 这种情况**不回退到物理路径猜测** —— 猜路径会让模型以为拼对了，
         * 换设备时才炸，而且炸得莫名其妙。
         */
        const val CODE_MOUNT_UNKNOWN = 12

        /**
         * 对**只读挂载点**执行了写操作。
         *
         * 由宿主**在写入前**直接拒绝，不进 PRoot 去靠文件权限兜底：
         * 进 PRoot 再失败的话，错误会变成 EACCES，宿主无法区分
         * 「挂载点只读」和「磁盘满/权限异常」。
         */
        const val CODE_MOUNT_READ_ONLY = 13
    }
}

/**
 * 对只读挂载点写入时抛出。
 *
 * 单独一个类型是为了让宿主能 `catch (e: MountReadOnlyException)` 直接给用户
 * 明确提示（「@libs 是只读挂载」），而不用去比对字符串或码值。
 *
 * @property mountName 被拒的挂载点名（不含 `@`）
 * @property attemptedPath 调用方给的原路径（含 `@name/...`）
 */
class MountReadOnlyException(
    val mountName: String,
    val attemptedPath: String,
) : SandboxException(
    CODE_MOUNT_READ_ONLY,
    "挂载点 @$mountName 是只读的，拒绝写入：$attemptedPath",
)
