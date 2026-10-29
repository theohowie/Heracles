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

import com.heracles.sandbox.api.ChannelInfo;
import com.heracles.sandbox.api.ExecutionRequest;
import com.heracles.sandbox.api.ExecutionResult;
import com.heracles.sandbox.api.FileResult;
import com.heracles.sandbox.api.IExecutionCallback;
import com.heracles.sandbox.api.RootfsStatus;
import com.heracles.sandbox.api.MountEntry;

/**
 * Heracles-taixu-sandbox 对外的**唯一**契约。
 *
 * <p>只暴露四类能力：执行 / 文件 / 通道查询 / rootfs 管理。
 *
 * <p><b>权限决策（允许 / 需确认 / 拒绝）不在本服务内实现。</b>
 * 沙箱只回答「现在有哪些通道可用、各自风险等级是多少」，
 * 由宿主按自己的信任策略决定放行与否。这样任何 Android Agent 项目
 * 都能复用本沙箱而不被迫接受 Heracles 的策略。
 *
 * <p>路径语义：{@link #readFile} / {@link #writeFile} 的 {@code path} 与
 * {@code pathView} 参数共同决定解读方式 —— 见 {@code docs/api-reference.md}
 * 与 {@code PathSemantics.kt}。
 */
interface ISandboxService {
    /**
     * 在 PRoot 根文件系统内执行命令，可走 PTY。
     *
     * <p>非阻塞：立即返回，过程通过 {@code callback} 上报。宿主可同时发起多次执行，
     * 但同一条「前台有界命令」通道有并发上限（见 ProcessRegistry），
     * 超出时会通过 {@code onError(CODE_BUSY)} 拒绝而不是排队。
     *
     * @param request  执行参数（命令、工作目录、超时、是否 PTY…）
     * @param callback 输出/进度/结束回调，以及取消信号
     */
    void execute(in ExecutionRequest request, in IExecutionCallback callback);

    /**
     * 读取文件。
     *
     * @param path     路径；按其 {@code pathView} 语义解读
     * @param pathView {@code PathView.HOST}（宿主进程视角，含零宽通道穿透）
     *                 或 {@code PathView.SANDBOX}（PRoot 根文件系统内视角）
     * @return 结果；失败时 {@code success=false} 且带 errorCode
     */
    FileResult readFile(String path, int pathView);

    /**
     * 写入文件。
     *
     * @param path     路径；按其 {@code pathView} 语义解读
     * @param data     要写入的字节
     * @param pathView 同上
     */
    FileResult writeFile(String path, in byte[] data, int pathView);

    /**
     * 查询当前可用通道、前置条件满足状态与风险等级。
     *
     * <p>顺序稳定（NORMAL、SHIZUKU、ROOT、WIRELESS_ADB），宿主可直接按 ordinal 建索引。
     */
    List<ChannelInfo> queryChannels();

    /**
     * 从 OCI Registry 拉取并安装 rootfs（完整环境）。
     *
     * <p>与 {@link #useBundledRootfs} 并存的**双策略**：没网时用内置 minimal rootfs，
     * 有网且需要完整工具链时走 OCI。
     *
     * @param ociRef   OCI 镜像引用，如 {@code docker.io/library/alpine:3.20}
     * @param callback 进度与结束回调（进度用于下载层）
     */
    void installRootfs(String ociRef, in IExecutionCallback callback);

    /**
     * 使用 APK 内置的 minimal rootfs（离线 fallback）。
     *
     * <p>同步返回；解包失败会抛 {@code ServiceSpecificException}。
     */
    void useBundledRootfs();

    /**
     * 对当前 rootfs 做快照（用于构建前回滚）。
     *
     * @param name 快照名；同名会被覆盖
     */
    RootfsStatus snapshotRootfs(String name);

    /**
     * 重置 rootfs 到初始状态。
     *
     * @param name 上次 snapshotRootfs 的名字；传空串表示「清空重装」
     */
    void resetRootfs(String name);

    // ==========================================================================
    // 命名挂载层（MountRegistry）
    // ==========================================================================
    // ★ 这两个方法是**宿主侧配置通道**，不是第 5 类核心能力。
    //   上面四类核心能力（execute / readFile+writeFile / queryChannels /
    //   rootfs 管理）的语义**一字未改**。
    //
    // 为什么需要跨进程暴露：执行面跑在 `android:process=":sandbox"` 里，
    // 而 `@name` 的**解析必须发生在执行面进程**（SandboxFileService 在那边）。
    // 所以宿主进程注册的挂载点必须经 Binder 送过来。

    /**
     * 注册 / 覆盖一个逻辑命名挂载点。
     *
     * <p>同名会覆盖（幂等，便于宿主启动时重复注册）。
     * <p>结构非法时**立即失败**（不抛异常，返回带 errorCode 的 {@link FileResult}），
     * 避免配错了却等到第一次读文件才发现。
     *
     * @param entry 挂载条目；`name` 不含 `@`
     * @return 成功时 `success=true`；失败时 `errorCode` 为
     *         `CODE_INVALID_ARGUMENT`（结构非法）或 `CODE_MOUNT_UNKNOWN`（无法注册）
     */
    FileResult registerMount(in MountEntry entry);

    /**
     * 列出当前已注册的挂载点（宿主用来给用户展示挂载状态与只读标记）。
     *
     * <p>顺序为注册顺序，稳定。
     */
    List<MountEntry> listMounts();
}
