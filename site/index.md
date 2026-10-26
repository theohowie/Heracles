---
layout: home

hero:
  name: Heracles
  text: 手机上的开发智能体
  tagline: 在 Android 手机上的真实工作区里读代码、改文件、跑命令；接上设备侧工具链后，还能直接在这台手机上把工程构建成可安装的 APK。模型走你自己的 API Key，云端推理，手机上不加载模型。
  image:
    src: /logo.png
    alt: Heracles
  actions:
    - theme: brand
      text: 下载 APK（20.6 MB）
      link: https://github.com/theohowie/Heracles/releases/download/v0.2.0/Heracles-v0.2.0.apk
    - theme: alt
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: 从源码构建
      link: /guide/build

features:
  - title: 手机上的真实工作区
    details: 用系统文件选择器（SAF）授权任意目录，包括 /sdcard 上你自己的项目；列目录、读文件、写文件、局部补丁、按名查找、按内容搜索。
  - title: 直接在这台手机上构建 APK
    details: 设备侧工具链就绪后，走 aapt2 → javac → d8 → 进程内对齐 → 签名，产出可安装的 APK —— 不需要 Gradle，也不需要电脑。
  - title: 抗幻觉靠架构，不靠提示词
    details: 工具白名单 + 参数门禁三态（允许 / 需要确认 / 拒绝）+ 解析失败绝不猜（不执行、如实回告）。
  - title: 会话严格 append-only
    details: 从不改写历史消息，只往后追加；长会话的代价随轮次几乎不变，云端前缀缓存也更稳。
  - title: BYOK，Key 不出手机
    details: 你的 API Key 只存在手机本地安全存储、只出现在请求头里，不进日志。任务随时可以中断。
  - title: GPL-3.0 开源
    details: 内核是纯 Dart 包（backend/），前端是 Flutter（app/），设备能力由 Kotlin 桥提供；可自由修改与再发布。
---

## 它是什么

Heracles 是一个**跑在 Android 手机上的 AI 编程 App**。

你说清楚要干什么，它自己决定调哪些工具：读文件、改代码、跑命令、搜索；
每一次调用在界面上是一张可展开的卡片，越界的动作按权限档位处理。
如果你把**设备侧工具链**装上，它还能在这台手机上完成 `aapt2 → javac → d8 → 对齐 → 签名` 这一整条链，
直接产出可安装的 APK —— 全过程不依赖电脑，也不依赖 Gradle。

| 场景 | 它怎么帮你 |
|---|---|
| 手边没有电脑，想改几行代码 | 加一个工作区，说清楚改什么；它读文件、局部替换，改完把 diff 给你看 |
| 想让 AI 带着上下文看代码 | 工作区的文件能列、能读、能按文件名与内容搜索，长文件自动分段 |
| 想在这台手机上构建 APK | 工具链就绪后直接出产物；构建期间前台服务保活、通知栏显示步骤 |
| 想改一个现成的 APK | 解包（资源或 smali）→ 改 → 重打包 → 签名 → 装回去 |
| 只是想有个手机上的编程助手 | 不带工作区也能聊；多轮工具调用、任务计划、随时中断 |

## 三步用起来

1. **装 APK** —— [**直接下载 `Heracles-v0.2.0.apk`**](https://github.com/theohowie/Heracles/releases/download/v0.2.0/Heracles-v0.2.0.apk)（20.6 MB，点击即开始下载；其它版本在 [Releases](https://github.com/theohowie/Heracles/releases)）。要求：arm64 手机、Android 12+。
2. **配模型** —— `设置 → 模型 → 添加`：选协议、填 Base URL 与 API Key、选模型名（建议用支持 function calling 的模型）。
3. **加工作区开聊** —— 侧边栏 `⊕` 里「选择文件夹」（SAF 授权）或「默认工作区」（免授权）。

细节见 [快速开始](/guide/getting-started)。

## 架构一眼看

```
Heracles/
├── backend/          纯 Dart 包：编排(agent) / 工具 / 契约(contract) / 上下文 / 能力探测 / RAG
├── app/              Flutter 前端：UI(screens/widgets/theme) + 服务层(services) + Kotlin 设备桥(android)
├── site/             项目主页源码（VitePress）
├── INTERFACE.md      前后端接口与事件流契约
└── LICENSE           GPL-3.0
```

- **内核与协议**在 `backend/`：不依赖 Flutter、不依赖 Android，可以直接 `dart test`。
- **界面**在 `app/lib/screens|widgets|theme`；**设备能力**（文件、shell、Shizuku、构建服务）由 `app/android` 的 Kotlin 桥提供。
- 事件流走进程内通道：`AgentBridge.events`（不再有跨进程的 EventChannel）。
- 安装包见 [Releases](https://github.com/theohowie/Heracles/releases)（不进仓库）。

## 当前状态

**已经可用**：会话与守卫、审批门禁、取消与排队发送、设备权限总览、内核 269 项单测 —— 都在真机上跑通过。

**尚未验证**：线上字段的真 Key 验证、Anthropic / Responses 两条协议轨、图片多模态、SAF 工作区内构建等。
完整清单见 [功能与限制](/status)。