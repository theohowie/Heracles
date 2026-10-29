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

/*
 * 一次执行的最终结果。实现在
 * sandbox-api/src/main/kotlin/com/heracles/sandbox/api/ExecutionResult.kt
 *
 * 字段语义（详见 docs/api-reference.md）：
 *   exitCode        int     进程退出码；超时/取消时为对应码（见下）
 *   stdout          String  聚合 stdout（已按 MAX_CAPTURE_BYTES 截断）
 *   stderr          String  聚合 stderr（已截断）
 *   durationMillis  long    墙钟耗时
 *   timedOut        boolean 是否因超时被杀
 *   cancelled       boolean 是否因宿主取消被杀
 *   truncated       boolean 聚合文本是否发生过截断
 *   channelType     int     实际使用的通道（ChannelType ordinal）
 *
 * ★ 流式增量以 IExecutionCallback.onOutput 为准。本结构的 stdout/stderr
 *   只是为了「单次执行结束后一次性取回」的便利，宿主不应依赖它拿到全量日志。
 */
parcelable ExecutionResult;
