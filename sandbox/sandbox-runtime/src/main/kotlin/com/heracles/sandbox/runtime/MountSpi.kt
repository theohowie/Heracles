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

package com.heracles.sandbox.runtime

/**
 * 执行层对「命名挂载层」需要的最小接口集合（SPI）。
 *
 * ============================================================================
 * 为什么要有这个文件（依赖方向问题）
 * ============================================================================
 * 模块依赖是单向的：
 *
 * ```
 * sandbox-api  ←  sandbox-runtime  ←  sandbox-file
 *                      ↑
 *                      └── sandbox-channel
 * ```
 *
 * `sandbox-file` 依赖 `sandbox-runtime`，**反过来不成立**。
 * 但 `ProotEngine` 需要拿到「要 bind 进 rootfs 的挂载点」，
 * 如果直接 import `MountRegistry` 就会形成环。
 *
 * ⇒ 把「我需要什么」定义在执行层（本文件），把「具体怎么算」放在挂载层实现。
 *   宿主在装配时把实现注入进来。执行层因此**完全不知道** `@name` 的存在。
 *
 * ============================================================================
 * 两层解析的边界（重要）
 * ============================================================================
 * ```
 * @name/...      ← 逻辑命名空间（模型只写这个）
 *    ↓ MountResolver（在 sandbox-file）
 * 物理路径        ← 宿主视角绝对路径
 *    ↓ PathSemantics（在 sandbox-file）
 * HOST / SANDBOX ← 两套物理语义
 * ```
 * 执行层只看到**已经解析完的物理路径**。它不解析 `@name`，也不该解析。
 */
interface MountBindSource {

    /**
     * 当前需要 bind 进 rootfs 的条目。
     *
     * 每次组装 proot 命令行时调用（挂载点可能在两次执行之间变化，
     * 所以**不要缓存**返回结果）。
     *
     * ⚠️ 返回的 [BindMount] 仍然要过 [ProotEngine.validateBind] 的白名单校验 ——
     * 这里不做安全放松。
     */
    fun bindMounts(): List<BindMount>
}

/**
 * 命令字符串改写器：把模型给的 `@name/...` 换成物理路径。
 *
 * ============================================================================
 * 为什么必须在**组装 proot 命令行之前**做
 * ============================================================================
 * 顺序是硬约束：
 *
 * ```
 * ExecutionRequest(commandLine = "cat @workspace/a.txt")
 *   ↓ CommandRewriter.rewrite(...)          ← 在这里变成 "cat /…/a.txt"
 *   ↓ ProotExecSpec(commandLine = 已改写, extraBinds = …)
 *   ↓ ProotEngine.buildCommandLine()
 *   ↓ proot … /bin/sh -lc "cat /…/a.txt"
 * ```
 *
 * 如果放到别处就会出问题：
 * - 放到 `PathSemantics` 里 → 那一层只该管「宿主/沙箱两套物理语义」，
 *   让它认识 `@name` 会让三级结构糊成两级
 * - 放到 proot 组装之后 → `@name` 会原样进 shell，被当成变量/通配符
 */
interface CommandRewriter {

    /**
     * 改写命令串。
     *
     * @param commandLine 原始命令串
     * @return 改写后的命令串
     * @throws com.heracles.sandbox.api.SandboxException
     *         引用了未注册的 `@name` 时必须抛（**不要原样返回**，
     *         否则 `@nope/x` 会被 shell 解释成别的东西，错误更难查）
     */
    fun rewriteCommand(commandLine: String): String
}

/**
 * 挂载点的**管理面**（注册 / 列表）。
 *
 * 与 [MountBindSource] 分开是因为用途不同：
 * - [MountBindSource]：执行引擎每次组装 proot 时要用
 * - [MountAdmin]：AIDL 的 `registerMount` / `listMounts` 要用（宿主配置）
 *
 * 实现放在 `sandbox-file` 的 `MountRegistry`；执行层只依赖这两个接口，
 * 因此仍然**不依赖** `sandbox-file` 模块。
 */
interface MountAdmin {

    /**
     * 注册或覆盖。
     *
     * @throws com.heracles.sandbox.api.SandboxException `CODE_INVALID_ARGUMENT` 结构非法
     */
    fun register(entry: com.heracles.sandbox.api.MountEntry)

    /** 按注册顺序列出。 */
    fun list(): List<com.heracles.sandbox.api.MountEntry>
}