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
 * 一次文件读写的结果。实现（Kotlin，手写 Parcelable）在
 * sandbox-api/src/main/kotlin/com/heracles/sandbox/api/Models.kt
 *
 * 字段语义（详见 docs/api-reference.md）：
 *   success       boolean 是否成功；false 时只有 errorCode/errorMessage 有意义
 *   path          String  规范化后实际用到的路径（回显，便于排查视角误用）
 *   data          byte[]  读到的字节；写入时为 null
 *   size          long    读/写字节数；失败为 -1
 *   lastModified  long    文件 mtime（epoch millis）；未知 -1
 *   pathView      int     实际使用的视角（PathView.HOST=0 / SANDBOX=1）
 *   errorCode     int     SandboxException 的 CODE_*；0 表示无错误
 *   errorMessage  String
 *
 * ★ path 回显的是「按 pathView 解读之后」的真实路径。宿主排查
 *   「exec 里能读到、readFile 读不到」时，先比对这里的回显。
 */
parcelable FileResult;
