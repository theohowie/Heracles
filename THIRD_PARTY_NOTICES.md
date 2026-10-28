# 第三方代码声明

本仓库包含以下第三方代码。原始许可证要求保留版权与许可声明，**请不要删除本文件**。

---

## core/ — dart_agent_core

- 来源：https://github.com/memex-lab/dart_agent_core（commit `09c88ef`，版本 2.1.8）
- 位置：`core/`
- 说明：上游框架源码的裁剪副本，详见 `core/VENDOR.md`

```
MIT License

Copyright (c) 2025 Memex Lab

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## sandbox/ — Heracles-taixu-sandbox

- 来源：taixu / baicodex / tianxuan（三者均为 GPL-3.0，见下方"上游来源"）
- 位置：`sandbox/`
- 说明：独立的端侧执行沙箱（fork 自 taixu，融合 baicodex 的三档执行权限门控与零宽文件通道、tianxuan 的无线 ADB 通道）。可单独编译、单独发布，详见 `sandbox/README.md`
- 协议：**GPL-3.0**
- 协议全文位置：`sandbox/LICENSE`（35149 字节，与 FSF 官方 `https://www.gnu.org/licenses/gpl-3.0.txt` 逐字节一致，SHA-256 `3972DC9744F6499F0F9B2DBF76696F2AE7AD8AF9B23DDE66D6AF86C9DFB36986`）
- 版权声明与移植来源：`sandbox/NOTICE`
- 上游来源：
  - taixu —— https://github.com/wkbin/taixu（基线 commit `dc7fcddb88e565929379597bbd811b440d00e34f`，**持续跟踪**）
  - baicodex —— https://github.com/mubai0122/baicodex（移植 commit `fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95`，一次性移植源）
  - tianxuan —— https://github.com/xiaozhe7772222/tianxuan（移植 commit `caad40090a4f2c2edbe54e6eaae60a3dd1de7d21`，一次性移植源）
- 上游 commit 对照与 rebase 流程：`sandbox/UPSTREAM.md`

### 关于 `sandbox/` 的特殊说明

`sandbox/` 是 GPL-3.0（强 copyleft），与本仓库其余以 MIT 发布的组件（如 `core/`
的 `dart_agent_core`）**协议不同、互不影响**：GPL-3.0 的义务仅覆盖 `sandbox/`
目录下的代码。

分发 `sandbox/` 时**必须**同时保留 `sandbox/LICENSE`（GPL-3.0 全文）与
`sandbox/NOTICE`（上游版权声明）—— 这是 GPL-3.0 的硬性要求，本文件仅作索引，
**不能替代**它们。

