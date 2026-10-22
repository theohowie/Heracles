/// **APK 构建与逆向工具**。
///
/// ## 当前状态：**未接线（能力层为 null）**
///
/// 这 5 个工具只在 `caps.apk != null` 时可用。迁移期 `ApkCapability` 还没有
/// Dart 实现（构建引擎原在 Kotlin `:toolchain`，已随重构删除），所以**真机上
/// 调用会明确返回「当前环境不支持 …」**，而不是假装跑过。
///
/// ## 移植时两条硬约束（不许违反）
///
/// 1. **对齐必须进程内做**（ADR-026 / ADR-027）：Android 上没有 `zipalign`
///    这个二进制（它是 SDK 的 glibc 产物，bionic 上跑不起来），而且
///    `ALIGN_MODE=inprocess` + `exit 11` 是对外契约。**不得**"先试 zipalign，
///    不行就说未对齐" —— 那是制造"已对齐"的假象。
///    对齐后**必须自校验**：重读偏移 + 全量 CRC。
/// 2. **工具链必须是 Termux 的 bionic 包**（ADR-025）：`openjdk-17` / `aapt2` /
///    `zip`，跑 JDK 工具时要给 `-Djava.io.tmpdir`（Android 没有 `/tmp`）。
///
/// ## 用成熟 CLI 而不是自己解析格式
///
/// 这也是业界标准做法（不需要自己解析 APK/DEX 格式）：
///
/// | 环节 | 成熟工具 | 说明 |
/// |---|---|---|
/// | 反编译 DEX → smali | **baksmali** | 业界标准，apktool 内部就用它 |
/// | smali → DEX | **smali** | 与 baksmali 配套 |
/// | 完整解包/重打包 | **apktool** | 一步搞定资源 + smali，最省事 |
/// | DEX 处理 | **d8** / **dx** | Android 官方 |
/// | 签名 | **apksigner** | Android 官方 |
/// | 解压/打包 | **zip** / **aapt2** | 系统自带 |
///
/// ### 为什么用 apktool 而不是自己拼
///
/// 自己拼 baksmali + aapt2 需要处理：
/// - `resources.arsc` 的二进制格式（改资源）
/// - smali 目录结构与多 dex
/// - 资源 id 重新映射
///
/// **这些都是 apktool 已经解决的。** 自己写等于重新实现一遍，而且很难对齐它的
/// 边界情况处理。
///
/// ### 唯一的例外：对齐
///
/// `zipalign` 这个二进制**在 Android 上不存在**（它是 Android SDK 的 glibc 产物，
/// 在手机上跑不起来）。旧实现因此写了进程内 `ZipAligner`（491 行 ZIP 格式操作）。
///
/// ⇒ 移植时**必须把这套进程内对齐 + 自校验一起搬过来**（见上方硬约束 1）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 构建 APK 工具。
List<Tool> buildApkTools(ToolFactory f, Capabilities caps) {
  final apk = caps.apk;
  return [
    // ---------------------------------------------------------------- 构建
    f.build(
      name: 'build_apk',
      description: '从零构建一个 Android APK 并签名。'
          '会在指定的项目目录里跑完整流程：aapt2 编译资源 → javac 编译 → d8 转 dex → '
          '打包 → 对齐 → 签名。产物路径会在结果里给出。'
          '⚠️ 这是长时间操作（通常 30 秒到数分钟），且会占用设备 CPU；'
          '电量低或设备烫时会被自动暂停。',
      parameters: {
        'type': 'object',
        'properties': {
          'project_dir': {
            'type': 'string',
            'description': '项目目录（相对工作区），需含 AndroidManifest.xml。',
          },
        },
        'required': ['project_dir'],
      },
      isAvailable: () => apk != null,
      unavailableReason: '当前环境不支持 APK 构建',
      run: (args) async {
        final dir = requireString(args, 'project_dir');
        return apk!.build(projectDir: dir);
      },
    ),

    // -------------------------------------------------------------- 反编译
    f.build(
      name: 'apk_decompile',
      description: '反编译 APK，产出可编辑的 smali 代码与资源文件。'
          '用于分析或修改别人的 APK。产物目录可直接用 edit/write_file 修改，'
          '之后用 apk_recompile 重新打包。',
      parameters: {
        'type': 'object',
        'properties': {
          'apk_path': {
            'type': 'string',
            'description': '要反编译的 APK 路径（相对工作区）。',
          },
          'out_dir': {
            'type': 'string',
            'description': '产物输出目录。已存在会被覆盖。',
          },
        },
        'required': ['apk_path', 'out_dir'],
      },
      isAvailable: () => apk != null,
      unavailableReason: '当前环境不支持 APK 逆向',
      run: (args) async {
        final apkPath = requireString(args, 'apk_path');
        final outDir = requireString(args, 'out_dir');
        return apk!.decompile(apkPath, outDir);
      },
    ),

    // -------------------------------------------------------------- 重打包
    f.build(
      name: 'apk_recompile',
      description: '把反编译产物（smali + 资源目录）重新打包成 APK，并对齐、签名。'
          '必须先用 apk_decompile 产出目录，或手动准备同结构的目录。',
      parameters: {
        'type': 'object',
        'properties': {
          'src_dir': {
            'type': 'string',
            'description': '反编译产物目录（含 AndroidManifest.xml 与 smali/）。',
          },
          'out_apk': {
            'type': 'string',
            'description': '输出 APK 路径。已存在会被覆盖。',
          },
        },
        'required': ['src_dir', 'out_apk'],
      },
      isAvailable: () => apk != null,
      unavailableReason: '当前环境不支持 APK 重打包',
      run: (args) async {
        final srcDir = requireString(args, 'src_dir');
        final outApk = requireString(args, 'out_apk');
        return apk!.recompile(smaliDir: srcDir, outApkPath: outApk);
      },
    ),

    // ---------------------------------------------------------------- 签名
    f.build(
      name: 'apk_sign',
      description: '给 APK 签名（用调试密钥）。已签名或需要重新签名时使用。'
          '未签名的 APK 无法安装到设备。',
      parameters: {
        'type': 'object',
        'properties': {
          'apk_path': {
            'type': 'string',
            'description': '要签名的 APK 路径。',
          },
        },
        'required': ['apk_path'],
      },
      isAvailable: () => apk != null,
      unavailableReason: '当前环境不支持 APK 签名',
      run: (args) async => apk!.sign(requireString(args, 'apk_path')),
    ),

    // ---------------------------------------------------------------- 安装
    f.build(
      name: 'install_apk',
      description: '把 APK 安装到当前设备（会走 pm install）。'
          '⚠️ 安装会覆盖同包名的已安装应用。'
          '安装前请确认这是用户想要的 —— 不要未经要求就安装。',
      parameters: {
        'type': 'object',
        'properties': {
          'apk_path': {
            'type': 'string',
            'description': '要安装的 APK 路径（相对工作区）。',
          },
        },
        'required': ['apk_path'],
      },
      isAvailable: () => apk != null,
      unavailableReason: '当前环境不支持安装 APK',
      run: (args) async => apk!.install(requireString(args, 'apk_path')),
    ),
  ];
}
