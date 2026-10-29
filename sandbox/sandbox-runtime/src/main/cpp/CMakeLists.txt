# Copyright (C) 2026 Heracles-taixu-sandbox contributors
#
# SPDX-License-Identifier: GPL-3.0
#
# This file is part of Heracles-taixu-sandbox.
#
# Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Heracles-taixu-sandbox is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
#
# 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f app/src/main/cpp/CMakeLists.txt
#          + taixu dc7fcddb88e565929379597bbd811b440d00e34f app/src/main/cpp/pty_native.c
#
# 与上游 CMakeLists 的差异（逐条）：
#   1. 库名 pty_native -> pty_bridge（沙箱模块自己的命名，避免与宿主 App 里
#      可能同时存在的 taixu pty_native 冲突：同名 .so 在同一个 APK 里会打架）。
#   2. 源文件后缀 .c -> .cpp（本任务书要求 pty_bridge.cpp）。为了能在
#      -DANDROID_STL=none 下链接，cpp 里**不使用任何 C++ 运行库设施**
#      （无 std::、无异常、无 RTTI、无全局构造），全部符号走 extern "C"，
#      因此不会拉入 libc++。
#   3. 显式链接 liblog：上游没有日志，这里 JNI_OnLoad 注册失败必须留下可诊断
#      的 logcat 记录，否则 Native 側失败在 Kotlin 侧只表现为
#      UnsatisfiedLinkError，无从定位。
#   4. 增加 -fno-exceptions / -fno-rtti / -fvisibility=hidden：保证不生成
#      __cxa_* 符号（ANDROID_STL=none 时这些符号没有提供者，一旦生成就是
#      运行时 dlopen 失败）。

cmake_minimum_required(VERSION 3.22.1)

project(heracles_pty_bridge CXX)

add_library(pty_bridge SHARED pty_bridge.cpp)

target_compile_options(
        pty_bridge
        PRIVATE
        -Wall
        -Wextra
        -Wno-unused-parameter
        -Werror=implicit-function-declaration
        -O2
        -fno-exceptions
        -fno-rtti
        -fvisibility=hidden
)

# liblog 是 Android NDK 的稳定系统库，任何 API level 都有。
target_link_libraries(pty_bridge PRIVATE log)
