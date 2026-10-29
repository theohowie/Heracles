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
 * 通道的风险等级。
 *
 * <p><b>这是「信息」而不是「决策」。</b>沙箱报告某个通道是 HIGH，
 * 不代表沙箱拒绝使用它；是否放行、是否每次确认、是否只读，
 * 全部由宿主的信任策略决定。沙箱刻意不内置任何策略，
 * 否则它就只能被 Heracles 用，不能被别的项目复用。
 *
 * <p>等级来源：baicodex 三档权限模型（移植时为一次性快照，
 * 见 UPSTREAM.md 的 baicodex commit）。
 */
enum class RiskLevel {
    /** 影响范围限于本 App 自己的沙箱。误操作最多毁掉沙箱内数据。 */
    LOW,

    /** 影响范围超出本 App，但限于用户级数据或需要用户可感知的授权。 */
    MEDIUM,

    /** 影响整机：root 身份、系统设置、其它 App 的私有数据。宿主应默认要求确认。 */
    HIGH,
}
