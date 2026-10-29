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
 */

package com.heracles.sandbox.api;

/**
 * 执行通道种类。
 *
 * <p>顺序即 {@code ISandboxService.queryChannels()} 的返回顺序，
 * 也是 {@code ChannelInfo.type} 的取值 —— 宿主可以直接用 ordinal 建索引。
 *
 * <p><b>三档 + 一个额外通道</b>：前三档来自 baicodex 的权限模型，
 * WIRELESS_ADB 来自 tianxuan。之所以单列 ADB，是因为它的能力与风险
 * 都不落在「普通 / Shizuku / Root」这档序里：它不需要特权进程，
 * 但提供了一个完整的 shell 身份。
 */
enum class ChannelType {
    /** 普通 App 身份（u0_axxx）。零前置条件，永远可用。 */
    NORMAL,

    /** Shizuku 提供的 shell 身份（uid 2000）。需用户安装并授权 Shizuku。 */
    SHIZUKU,

    /** Root（su）。需设备已 root 且授予 superuser。 */
    ROOT,

    /**
     * 无线 ADB 自调试通道。
     *
     * <p>前置条件：开发者选项里的「无线调试」已开启 + 已完成 adb pair 配对。
     * 提供 shell 身份，能 {@code pm} / {@code am} / {@code screencap} 等，
     * 但**不是 root**，也不能绕过 SELinux。
     */
    WIRELESS_ADB,
}
