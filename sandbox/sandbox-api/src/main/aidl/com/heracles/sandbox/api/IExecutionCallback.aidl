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

package com.heracles.sandbox.api;

import com.heracles.sandbox.api.ExecutionRequest;
import com.heracles.sandbox.api.ExecutionResult;

/**
 * 执行过程的单向回调。
 *
 * <p>方向：沙箱 → 宿主（{@link #onOutput}、{@link #onProgress}、{@link #onExit}、
 * {@link #onError}），以及宿主 → 沙箱的**取消信号**（{@link #isCancelled()}）。
 *
 * <p>取消是「拉」模型而不是「推」模型：沙箱在输出循环里周期性调用
 * {@link #isCancelled()}，返回 true 就向进程组发 SIGTERM，宽限期后再 SIGKILL。
 * 这样宿主只需改一个 volatile 标志，不需要额外的事务性 cancel 调用，
 * 也就不会出现「cancel 到达时任务已经结束」的竞态。
 *
 * <p><b>所有回调都可能来自后台线程</b>，宿主实现必须自己切回主线程再更新 UI。
 * 回调实现绝不能阻塞（沙箱会按顺序投递并等待返回）。
 */
interface IExecutionCallback {
    /**
     * 增量输出。
     *
     * @param stream {@link #STREAM_STDOUT} 或 {@link #STREAM_STDERR}
     * @param chunk  本次到达的文本片段（UTF-8 已做增量解码，不会切坏多字节字符）
     * @param sequence 从 0 单调递增的序号，用于宿主侧检测丢失/重排
     */
    void onOutput(int stream, String chunk, long sequence);

    /**
     * 长任务进度上报（构建、rootfs 安装等）。
     *
     * @param percent 0..100；**负数表示不确定进度**（只更新消息）
     * @param message 人类可读的阶段描述，可为空串
     */
    void onProgress(int percent, String message);

    /**
     * 执行正常结束（包括非 0 退出码、超时、被取消 —— 三者都在 result 里区分）。
     */
    void onExit(in ExecutionResult result);

    /**
     * 沙箱自身出错（没装 rootfs、通道不可用、参数非法等），此时不会有 onExit。
     *
     * @param code    {@link SandboxException} 的 {@code CODE_*} 常量
     * @param message 可直接展示给用户的中文/英文说明
     */
    void onError(int code, String message);

    /**
     * 取消信号。沙箱轮询此方法；宿主实现必须**立即返回**且不得阻塞。
     */
    boolean isCancelled();

    /** stdout 流标识。 */
    const int STREAM_STDOUT = 1;
    /** stderr 流标识。 */
    const int STREAM_STDERR = 2;
}
