# 从源码构建

## 环境要求

| 组件 | 版本 |
|---|---|
| Flutter | **3.44.2**（Dart SDK `^3.12.2`） |
| JDK | **17** |
| Android SDK | `compileSdk 37`（`minSdk 31`，即 Android 12+） |
| adb | 任意近期版本 |

`backend/` 是**纯 Dart 包**：不需要 Flutter，也不需要 Android SDK。

## 1. 跑内核测试（最快、最稳）

```bash
cd backend
dart test          # 269 项：编排 / 工具 / 契约 / 上下文 / 能力探测
```

## 2. 检查并测试前端

```bash
cd app
flutter pub get
flutter analyze                    # 期望：No issues found!
flutter test test/widget_test.dart # 建议逐文件跑（见下）
```

::: warning 别一次性跑全部测试
个别文件在部分 Windows 机器上会**卡死**（本地回环被拒 `errno 10013`，或缺插件通道 mock）。
**改成单文件跑**即可，例如：

```bash
flutter test test/session_guard_test.dart
flutter test test/reasoning_switch_test.dart
```
:::

## 3. 打包与装机

```bash
flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

产物：`app/build/app/outputs/flutter-apk/app-release.apk`（约 20.6 MB）。

::: tip release 签名
仓库里 release 变体目前**沿用 debug keystore** 签名（`app/android/app/build.gradle.kts` 里留着 TODO）。
想发正式包就自己加一个 `signingConfigs.release`，**keystore 与口令务必自己保管**。
:::

## 4. 本地预览项目主页

这个站点（VitePress）的源码在 `site/`：

```bash
cd site
pnpm install
pnpm dev           # 本地预览
pnpm build         # 构建到 site/.vitepress/dist
```

## 常见坑

- **同一条命令链里不要连着跑多个 Gradle 任务**：daemon 抢端口会假失败 —— 逐条跑，
  并且**看退出码 + 产物 mtime/sha256**，别只看输出文字；
- **改了 Kotlin 必须真编一次**（`flutter analyze` 只看 Dart，不看 Kotlin）；
- **`flutter build` 偶发失败**（本机回环被拒 `errno 10013`）⇒ 重试即可，注意确认产物哈希真的变了。