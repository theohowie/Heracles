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

/*
 * 一次执行请求。实现在
 * sandbox-api/src/main/kotlin/com/heracles/sandbox/api/ExecutionRequest.kt
 *
 * 字段语义（详见 docs/api-reference.md）：
 *   command          String  要执行的命令行，由 guest /bin/sh -c 解释
 *   workingDirectory String  沙箱视角路径，如 "/workspace"；空串 = rootfs 根
 *   environment      List<String> 形如 "K=V" 的追加环境变量
 *   timeoutMillis    long    超时（毫秒）；<= 0 表示不限时
 *   usePty           boolean 是否分配伪终端（交互式/带颜色的构建输出需要）
 *   ptyColumns/ptyRows int   PTY 窗口尺寸；usePty=false 时忽略
 *   channelType      int     指定通道（ChannelType ordinal）；-1 = 自动选路
 *   inputData        String  写入 PTY 的标准输入（一次性喂入后关闭）；空串 = 不喂
 *
 * ★ 路径是「沙箱视角」：PRoot 根文件系统内部的路径，不是宿主 App data 目录。
 */
parcelable ExecutionRequest;
