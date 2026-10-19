package dev.heracles.toolchain

/**
 * **预设模板** —— `26-编码层工具链与逆向引擎.md` §9（对应需求模块 6）。
 *
 * ## 为什么要有模板（而不是让模型自己写）
 *
 * 需求原文：「**预设模板…让本地小模型只需填空**」。
 *
 * 依据是 `实测-08` 的结论：4B 模型在"从零写一个能编译通过的项目骨架"
 * 上失败率极高 —— 它会把 `AndroidManifest.xml` 的命名空间写错、
 * 把 `build_apk.sh` 的 `aapt2` 参数顺序写错（这些**不是表达问题，是记忆问题**）。
 *
 * ⇒ 把**容易记错的部分**变成模板（零 token、零出错），
 * 只把**真正需要创造性**的部分（包名、界面文案、业务代码）留给模型填。
 *
 * ## 与"禁止 Gradle"的关系
 *
 * 模板里的 `build_apk.sh` 是**整条流水线的唯一权威实现**：
 *
 * ```
 * aapt2 compile → aapt2 link → javac → d8 → 塞 classes.dex → [对齐] → apksigner
 * ```
 *
 * `zipalign` **已彻底出局**（ADR-027，2026-10-16 真机）：Android 上没有这个二进制
 * （ADR-026 实测），所以对齐改成三种模式（见脚本 `[5/5]`）：
 * `external`（PC 上手工跑时用外部 `zipalign`）/ `inprocess`（**引擎默认** ——
 * 脚本 `exit 11` 把控制权交回，由 `ZipAligner` 在进程内对齐）/ 未设置（跳过，但**必须明说**）。
 *
 * 没有任何一步经过 Gradle（需求硬约束）。
 */
object BuildTemplates {

    /** 默认包名（脚手架会替换成模型/用户指定的包名）。 */
    const val DEFAULT_PACKAGE = "com.theohowie.heracles.hello"

    /** Java 只允许字母/数字/下划线/点，包名要能当目录名用。 */
    const val MANIFEST: String = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="__PACKAGE__">

    <application
        android:label="@string/app_name"
        android:theme="@android:style/Theme.Material.Light"
        android:allowBackup="true">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
"""

    /**
     * 最小 Activity。
     *
     * ⚠️ 只用**平台 API**，不依赖 AndroidX —— 这是能用 `javac` 编译的前提
     * （AndroidX 要 AAR 解包 + 额外 classpath，那就等于把 Gradle 的工作
     * 手工做一遍）。
     */
    const val MAIN_ACTIVITY: String = """package __PACKAGE__;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/**
 * 最小可用界面 —— 由 Heracles 模板生成。
 * 改文案：res/values/strings.xml；改布局：res/layout/activity_main.xml。
 */
public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        TextView hello = findViewById(R.id.hello);
        hello.setText("Hello from Heracles");
    }
}
"""

    const val STRINGS_XML: String = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">__APP_NAME__</string>
    <string name="hello_default">Hello World</string>
</resources>
"""

    const val LAYOUT_XML: String = """<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:gravity="center">

    <TextView
        android:id="@+id/hello"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:textSize="20sp"
        android:text="@string/hello_default" />
</LinearLayout>
"""

    /**
     * 构建脚本 —— **整条流水线的唯一权威实现**。
     *
     * ## 为什么脚本可能有 `exit 10` 这条奇怪路径
     *
     * 「把 `classes.dex` 塞进 `aapt2 link` 产出的 APK」这一步，
     * 常规做法是 shell 里 `zip -j base.apk classes.dex`。
     * 而 **Android 的 `/system/bin` 里没有 `zip`**（也没有 `jar`）——
     * 这是设备精简的结果，不是配置问题。
     *
     * 所以脚本的行为是：
     *
     * | 环境 | 行为 |
     * |---|---|
     * | 有 `zip`（如 Termux 的 `zip`） | 脚本自己完成，一路到签名 |
     * | 没有 `zip` | 打印 `NEED_DEX_INSERT` 并 `exit 10`；由 Heracles 在**进程内**用 `ZipFs` 插入，然后重跑 `package` |
     *
     * 这样"脚本可独立运行"与"App 在裸设备上也能用"两个目标都成立。
     *
     * ## ⚠️ 实测：`set -u` 下裸 `$1` 会直接崩（2026-10-16 真机首次执行）
     *
     * 首次真机执行 `sh build_apk.sh all`（**只给 1 个参数**）直接失败：
     *
     * ```
     * build_apk.sh[16]: 2: parameter not set
     * ```
     *
     * `set -u` 把"引用未定义的位置参数"当**硬错误**（与 `set -e` 无关），
     * 所以 `MODE="$1"` 这种写法在参数少于 3 个时必炸 —— 而下面那行
     * `[ -z "$MODE" ] && MODE=all` 的兜底**永远执行不到**。
     *
     * ⇒ 所有位置参数一律写 `"${N:-}"`。
     *
     * 这类问题**单元测试抓不到**：既有测试只比对脚本*文本*（顺序、参数名），
     * 从不真正执行它。必须有一个**真跑一遍脚本**的测试
     * （见 `ToolchainTest.kt` 的 `BuildScriptExecutionTest`）。
     *
     * ## 为什么不用 `set -e`
     *
     * 每一步都用 `|| exit 1` 显式判定，比全局 `set -e` 更可控：
     * `set -e` 在管道/子 shell/条件里有一堆例外，出问题时报的行号会误导排查方向。
     *
     * ## ⚠️ 实测：`javac` **不能**用 `-bootclasspath`（2026-10-16 本机验证）
     *
     * 直觉做法是 `javac -bootclasspath android.jar`（让 `java.lang.*` 也来自
     * android.jar，避免误用 JDK 专有 API）。**这条在 JDK 17+ 上直接报错**：
     *
     * ```
     * 错误: 目标 17 不支持选项 --boot-class-path
     * ```
     *
     * ⇒ 只能用 `-classpath android.jar`。副作用是 `java.*` 会解析到 JDK 自己的
     * 实现，理论上可能编译通过却在设备上崩（用了 android.jar 里没有的 JDK API）。
     *
     * 对本项目**风险很低**且理由可查：`minSdk = 31`（Android 12）已包含
     * `java.nio.file`、`java.time`、Stream 等绝大多数 JDK 11 API；
     * 而模板代码只用 `android.app.Activity` / `android.widget.TextView` /
     * `android.os.Bundle` —— 三者都在 android.jar 里。
     *
     * 若将来要严格化，正确做法是接 R8/D8 的 `--lib` 校验（它在 **dex 阶段**
     * 会对着 android.jar 检查引用），而不是指望 javac。
     *
     * ## 退出码约定
     *
     * | 码 | 含义 |
     * |---|---|
     * | 0 | 成功 |
     * | 1 | 某一步执行失败（细节在 stderr） |
     * | 2 | 环境不完整（缺工具 / 缺源文件），**还没开始编译** |
     * | 10 | 需要外部插入 `classes.dex`（见上表） |
     *
     * ## 关于 `__DOLLAR__` 占位符
     *
     * 脚本正文里所有 `$` 都写成 `__DOLLAR__`，由 [script] 在生成时替换回 `$`。
     *
     * 原因：Kotlin 的字符串模板用 `$` 起头，直接写 `$VAR` 会被当成插值，
     * 只能到处写 `${'$'}` —— 那样**模板正文会变得没法读**（一屏几十个转义），
     * 而这个脚本是要给人看、给人改的。占位符方案让模板与产物两边都干净。
     *
     * 替换是**一次性**的，且 [script] 有测试保证不留残余（`BuildTemplatesTest`）。
     */
    val BUILD_SCRIPT: String = """#!/system/bin/sh
# ============================================================
# build_apk.sh —— 从零构建可安装的 APK。**不使用 Gradle**。
# 由 Heracles 生成（模板见 toolchain/BuildTemplates.kt），可自由修改。
#
#   sh build_apk.sh prepare [项目目录] [输出apk]
#   sh build_apk.sh package [项目目录] [输出apk]
#   sh build_apk.sh all     [项目目录] [输出apk]
#
# 工具路径从环境变量读（Heracles 自动注入，也可手动 export）：
#   AAPT2  D8_JAR  ANDROID_JAR  APKSIGNER  KEYSTORE  [ALIGN_MODE  ZIPALIGN]
#
# 退出码：0 成功 / 1 某步失败 / 2 环境不完整 / 10 需外部插入 classes.dex
#         / 11 需外部对齐（ALIGN_MODE=inprocess，对齐必须发生在签名之前）
# ============================================================
set -u

MODE="__DOLLAR__{1:-}"
PROJ="__DOLLAR__{2:-}"
OUT="__DOLLAR__{3:-}"
[ -z "__DOLLAR__MODE" ] && MODE=all
[ -z "__DOLLAR__PROJ" ] && PROJ=.
[ -z "__DOLLAR__OUT" ] && OUT=__DEFAULT_OUT__

AAPT2="__DOLLAR__{AAPT2:-aapt2}"
# ★ 对齐模式（ADR-027）：
#   external  用外部 ZIPALIGN 指向的 zipalign（必须有）
#   inprocess 调用方在进程内对齐（Android：没有 zipalign 这个二进制）⇒ exit 11 交回
#   空        跳过对齐并**明说**（手工跑脚本、又没装 zipalign）
ALIGN_MODE="__DOLLAR__{ALIGN_MODE:-}"
# ⚠️ 保留 ZIPALIGN 变量是有意的：ALIGN_MODE=external 时才用它。
#   引擎侧已改为进程内对齐（不再依赖这个二进制），但手工跑脚本时它仍然好用。
ZIPALIGN="__DOLLAR__{ZIPALIGN:-}"
APKSIGNER="__DOLLAR__{APKSIGNER:-apksigner}"
D8_JAR="__DOLLAR__{D8_JAR:-}"
ANDROID_JAR="__DOLLAR__{ANDROID_JAR:-}"
KEYSTORE="__DOLLAR__{KEYSTORE:-}"
KS_PASS="__DOLLAR__{KS_PASS:-android}"
KEY_ALIAS="__DOLLAR__{KEY_ALIAS:-heracles}"
MIN_SDK="__DOLLAR__{MIN_SDK:-31}"
TARGET_SDK="__DOLLAR__{TARGET_SDK:-34}"

BUILD="__DOLLAR__PROJ/.heracles/build"
DEX="__DOLLAR__BUILD/dex/classes.dex"
STAMP="__DOLLAR__BUILD/dex-inserted"
ALIGN_STAMP="__DOLLAR__BUILD/aligned"

need() {          # need <名字> <值>
  n="__DOLLAR__1"
  v="__DOLLAR__2"
  if [ -z "__DOLLAR__v" ]; then
    echo "✗ 缺工具：__DOLLAR__n（环境变量未设置）" >&2
    exit 2
  fi
  case "__DOLLAR__v" in
    */*) [ -f "__DOLLAR__v" ] || { echo "✗ 缺工具：__DOLLAR__n = __DOLLAR__v（文件不存在）" >&2; exit 2; } ;;
    *)   command -v "__DOLLAR__v" >/dev/null 2>&1 || { echo "✗ 缺工具：__DOLLAR__n = __DOLLAR__v（不在 PATH 里）" >&2; exit 2; } ;;
  esac
  echo "  · __DOLLAR__n = __DOLLAR__v"
}

# APKSIGNER 有两种合法形态：**可执行包装**（Termux / SDK 的 `apksigner`）
# 和**只有 jar**（工具链里平铺的 `apksigner.jar`；SDK 的 build-tools 也带它）。
#
# ★ 2026-10-16 真机抓到：定位到 jar 时 `"__DOLLAR__APKSIGNER" sign …` 报
#   `can't execute: Permission denied`（jar 没有执行位，也不该有）。
#   两种形态在这里归一。
#
# 用**函数**而不是往字符串里拼 `java -jar …`：路径含空格时拼串会被拆成多个词。
apksigner_cmd() {
  case "__DOLLAR__APKSIGNER" in
    *.jar) java -jar "__DOLLAR__APKSIGNER" "__DOLLAR__@" ;;
    *)     "__DOLLAR__APKSIGNER" "__DOLLAR__@" ;;
  esac
}

prepare() {
  echo "== 检查工具 =="
  need aapt2 "__DOLLAR__AAPT2"
  need d8.jar "__DOLLAR__D8_JAR"
  need android.jar "__DOLLAR__ANDROID_JAR"
  command -v javac >/dev/null 2>&1 || { echo "✗ 找不到 javac（设备上需要一套 JDK，例如 Termux 的 openjdk-17）" >&2; exit 2; }

  # ★ 清中间产物时**必须保留 build/ 与 build/dex/ 这两个目录本身**（2026-10-17 真机实测）。
  #
  #   外置存储（FUSE/MediaProvider）上，App 只能"看进"**自己拥有**的目录：
  #   shell 建的目录，App 连 `stat` 都是 `AccessDeniedException`。
  #   而这两个目录是**调用方（App）预建**的 ⇒ 一旦 `rm -rf` 掉整个 BUILD，
  #   重建出来的就归 shell 所有，下游"插入 classes.dex"会报"压缩包不存在"
  #   （base.apk 明明在那儿，0666，App 读得到 —— 是**目录**把它挡在外面）。
  #
  #   ⇒ 除 dex/ 外一律清掉，dex/ 只清**里面的文件**。
  #   `2>/dev/null || true`：目录本来就空时 glob 不匹配，不能让这几行带崩脚本。
  for p in "__DOLLAR__BUILD"/*; do
    [ "__DOLLAR__p" = "__DOLLAR__BUILD/dex" ] && continue
    rm -rf "__DOLLAR__p" 2>/dev/null || true
  done
  rm -rf "__DOLLAR__BUILD/dex"/* 2>/dev/null || true
  mkdir -p "__DOLLAR__BUILD/classes" "__DOLLAR__BUILD/gen" "__DOLLAR__BUILD/dex"

  echo "[1/5] aapt2 compile（编译资源）"
  "__DOLLAR__AAPT2" compile --dir "__DOLLAR__PROJ/res" -o "__DOLLAR__BUILD/res.zip" || exit 1

  echo "[2/5] aapt2 link（链接资源 + 二进制清单）"
  "__DOLLAR__AAPT2" link -o "__DOLLAR__BUILD/base.apk" -I "__DOLLAR__ANDROID_JAR" \
    --manifest "__DOLLAR__PROJ/AndroidManifest.xml" -R "__DOLLAR__BUILD/res.zip" \
    --java "__DOLLAR__BUILD/gen" --auto-add-overlay \
    --min-sdk-version "__DOLLAR__MIN_SDK" --target-sdk-version "__DOLLAR__TARGET_SDK" || exit 1

  echo "[3/5] javac（编译 Java 源码）"
  : > "__DOLLAR__BUILD/sources.txt"
  find "__DOLLAR__PROJ/src" -name '*.java' >> "__DOLLAR__BUILD/sources.txt" 2>/dev/null
  find "__DOLLAR__BUILD/gen" -name '*.java' >> "__DOLLAR__BUILD/sources.txt" 2>/dev/null
  if [ ! -s "__DOLLAR__BUILD/sources.txt" ]; then
    echo "✗ 没有找到任何 .java 源文件（__DOLLAR__PROJ/src 是空的？）" >&2
    exit 2
  fi
  javac -J-Xmx512m -encoding UTF-8 -source 17 -target 17 -Xlint:-options \
    -classpath "__DOLLAR__ANDROID_JAR" \
    -d "__DOLLAR__BUILD/classes" "@__DOLLAR__BUILD/sources.txt" || exit 1

  echo "[4/5] d8（class → dex）"
  CLASSES=$(find "__DOLLAR__BUILD/classes" -name '*.class')
  if [ -z "__DOLLAR__CLASSES" ]; then
    echo "✗ 没有编译出 class 文件" >&2
    exit 2
  fi
  java -Xmx512m -cp "__DOLLAR__D8_JAR" com.android.tools.r8.D8 \
    --lib "__DOLLAR__ANDROID_JAR" --min-api "__DOLLAR__MIN_SDK" \
    --output "__DOLLAR__BUILD/dex" __DOLLAR__CLASSES || exit 1
  [ -f "__DOLLAR__DEX" ] || { echo "✗ d8 没有产出 classes.dex" >&2; exit 1; }

  rm -f "__DOLLAR__STAMP"
  echo "✓ prepare 完成：__DOLLAR__BUILD/base.apk + __DOLLAR__DEX"
}

package_apk() {
  echo "== 检查工具 =="
  need apksigner "__DOLLAR__APKSIGNER"
  need keystore "__DOLLAR__KEYSTORE"
  [ -f "__DOLLAR__BUILD/base.apk" ] || { echo "✗ 缺 base.apk，请先执行 prepare" >&2; exit 2; }
  [ -f "__DOLLAR__DEX" ] || { echo "✗ 缺 classes.dex，请先执行 prepare" >&2; exit 2; }

  if [ ! -f "__DOLLAR__STAMP" ]; then
    if command -v zip >/dev/null 2>&1; then
      echo "[5/5] 用设备的 zip 塞入 classes.dex"
      cp "__DOLLAR__DEX" "__DOLLAR__BUILD/classes.dex"
      ( cd "__DOLLAR__BUILD" && zip -q -X base.apk classes.dex ) || exit 1
      touch "__DOLLAR__STAMP"
    else
      echo "NEED_DEX_INSERT" >&2
      echo "STAMP=__DOLLAR__STAMP" >&2
      echo "DEX=__DOLLAR__DEX" >&2
      echo "BASE=__DOLLAR__BUILD/base.apk" >&2
      echo "（设备上没有 zip 命令 —— 插入方完成 dex 插入后创建 STAMP，再重跑 package）" >&2
      exit 10
    fi
  fi

  # ---------- [5/5] 对齐（**必须在 apksigner 之前**） ----------
  #
  # 三种模式（ADR-027，2026-10-16 真机）：
  #   external    有外部 zipalign（PC 上手工跑脚本时可用）
  #   inprocess   让**调用方**在进程内对齐 —— Android 上根本没有 zipalign
  #               这个二进制（ADR-026），引擎会用 :workspace 的 ZipAligner 做
  #   ""（默认）  既没工具、调用方也没说要代劳 ⇒ 跳过并**明说**（未对齐照样能装）
  if [ -f "__DOLLAR__ALIGN_STAMP" ]; then
    echo "[5/5] 对齐：已由调用方完成（__DOLLAR__ALIGN_STAMP）"
  else
    case "__DOLLAR__ALIGN_MODE" in
      external)
        need zipalign "__DOLLAR__ZIPALIGN"
        echo "[5/5] zipalign（外部工具）"
        "__DOLLAR__ZIPALIGN" -f -p 4 "__DOLLAR__BUILD/base.apk" "__DOLLAR__BUILD/aligned.apk" || exit 1
        ;;
      inprocess)
        # 与 exit 10 同一套契约：把**需要的路径**打在 stderr 上，让调用方去猜不着
        echo "NEED_ALIGN" >&2
        echo "IN=__DOLLAR__BUILD/base.apk" >&2
        echo "OUT=__DOLLAR__BUILD/aligned.apk" >&2
        echo "ASTAMP=__DOLLAR__ALIGN_STAMP" >&2
        echo "（调用方在进程内对齐 IN → OUT 后创建 ASTAMP，再重跑 package）" >&2
        exit 11
        ;;
      *)
        # ⚠️ 跳过对齐必须**明说**（H-1 教训：假信息比失败更糟）。
        #    未对齐的 APK 照样能装（2026-10-16 真机 pm install -r → Success），
        #    只是失去 4 字节对齐带来的 mmap 直读优化 —— 属于发布质量，不是安装前提。
        echo "⚠ 既没有 zipalign、也没有调用方代劳对齐（ALIGN_MODE 未设置），跳过对齐（APK 可安装，但未对齐）" >&2
        cp "__DOLLAR__BUILD/base.apk" "__DOLLAR__BUILD/aligned.apk" || exit 1
        ;;
    esac
  fi

  echo "[5/5] apksigner（签名并自校验）"
  apksigner_cmd sign --ks "__DOLLAR__KEYSTORE" --ks-pass "pass:__DOLLAR__KS_PASS" \
    --ks-key-alias "__DOLLAR__KEY_ALIAS" --key-pass "pass:__DOLLAR__KS_PASS" \
    --min-sdk-version "__DOLLAR__MIN_SDK" \
    --out "__DOLLAR__PROJ/__DOLLAR__OUT" "__DOLLAR__BUILD/aligned.apk" || exit 1

  apksigner_cmd verify --min-sdk-version "__DOLLAR__MIN_SDK" "__DOLLAR__PROJ/__DOLLAR__OUT" || exit 1
  echo "✓ 已产出可安装的 APK：__DOLLAR__PROJ/__DOLLAR__OUT"
}

case "__DOLLAR__MODE" in
  prepare) prepare ;;
  package) package_apk ;;
  all)     prepare && package_apk ;;
  *) echo "未知模式：__DOLLAR__MODE（可用：prepare / package / all）" >&2; exit 2 ;;
esac
"""

    /** 模板里代表字面 `$` 的占位符。见 [BUILD_SCRIPT] 的说明。 */
    const val DOLLAR = "__DOLLAR__"

    /**
     * 模板里代表**默认产物名**的占位符（P2-2 / F9a 收尾，2026-10-18）。
     *
     * 为什么要占位符而不是直接写 `app-debug.apk`：
     * 这个默认名是**产品事实**，唯一来源是 [BuildProfiles.ANDROID.artifact.defaultName]。
     * 脚本里的那一行是"**手工直跑脚本时**"的兜底（引擎总会显式传名字）——
     * 它也必须跟着同一份数据走，否则将来改默认名时脚本会悄悄留在旧值上。
     */
    const val DEFAULT_OUT_PLACEHOLDER = "__DEFAULT_OUT__"

    /** 生成可执行的脚本正文（把占位符换成真实值）。 */
    fun script(): String = BUILD_SCRIPT
        .replace(DOLLAR, "$")
        .replace(DEFAULT_OUT_PLACEHOLDER, BuildProfiles.ANDROID.artifact.defaultName)
}

/**
 * 把一条 shell 命令包成「跑完让 **App 进程**读得到产出」的形式。
 *
 * ## 为什么必须有它（2026-10-17 **App 进程内**自检抓到，见 `实测-12` §13）
 *
 * 设备上的外置存储走 FUSE（MediaProvider），它的权限判定**只看 mode、不看附加组**：
 *
 * | 事实 | 实测结果 |
 * |---|---|
 * | 同一份 `0660` 文件，App 在 `ext_data_rw` 组里 | **读不了**（EACCES） |
 * | 同一份文件 `chmod 666` 之后 | 能读 ✔ |
 * | `chown` 给 App 的 uid | `Operation not permitted`（uid 2000 没有 CAP_CHOWN） |
 * | `umask 000` 再创建 | **没用** —— mode 由 FUSE 在创建时强制成 `0660` |
 *
 * 而流水线里 shell 产出的东西（`base.apk`、`dex/classes.dex`、签名后的包）
 * **必须由 App 亲手读**：[ZipFs.putFile] 插 dex、[ZipAligner] 对齐、产物核对。
 * 不放开的话，症状是引擎在**下一步**报「压缩包不存在」——
 * 文件明明就躺在它要找的那个路径上（这个错法极难猜，值得一条函数）。
 *
 * ## 形态
 *
 * 每条命令末尾追加一次 `chmod -R a+rwX <工作区>`：
 *
 * - `X`（大写）而**不是** `x`：只给"本来就是目录"（或已带执行位）的条目补上执行位。
 *   缺了这个，`a+rw` 只会把 shell 建的目录变成 `0776` —— **可读写、不可"进入"**，
 *   而外置存储的 FUSE 只按 mode 判、不看附加组 ⇒ App 依旧 `AccessDenied`
 *   （2026-10-17 真机踩到：`drwxrwsrw-` 的目录，App 连里面的 `base.apk` 都 stat 不到）。
 * - 失败不致命（`2>/dev/null`）—— PC 上 `chmod` 也可能不存在；
 * - **退出码原样保留**（`exit $rc`）—— 脚本靠 `exit 10/11` 把"要我插 dex / 要我
 *   对齐"交回引擎，退出码被改掉整条契约就哑了。
 *
 * 在 PC / 设备 CLI 上同样无害：两端行为一致（ADR-025 / ADR-026 的"同一份逻辑"原则）。
 */
internal fun appReadable(command: String, workspaceRoot: java.nio.file.Path): String {
    val q = "'" + workspaceRoot.toString().replace("'", "'\\''") + "'"
    return "$command; rc=\$?; chmod -R a+rwX $q 2>/dev/null; exit \$rc"
}

/** [awaitRegularFile] 的上限与步长（见该函数说明）。 */
const val FILE_READY_TIMEOUT_MS = 3_000L
const val FILE_READY_STEP_MS = 50L

/**
 * 等一个「shell 刚写完、App 马上要读」的路径真的可读，返回尝试次数（含第一次）。
 *
 * ## 这个保险防的是"跨身份可见性"，不是"文件没写出来"
 *
 * App 自己**没有** shell 身份，shell 的产出（`base.apk` / `classes.dex` / 签名后的包）
 * 却要由 App **亲手**读（[ZipFs] 插 dex、[ZipAligner] 对齐、产物核对）。
 * 两个身份之间的可见性由外置存储的 FUSE 判定，而它**只按 mode 判、不看附加组**
 * （见 [appReadable] 的实测表）—— [appReadable] 因此把产出 `chmod` 放开。
 *
 * ⚠️ **诚实标注**：2026-10-17 真机上那一串"压缩包不存在"的根因**不是**这里的时序，
 * 而是 `WorkspaceFs.info.rootPath` 返回了**进程 CWD**（App 里是 `/`，
 * 于是引擎去 stat `/selfcheck/…`）。修好之后真机**一次通过**，本保险**一次都没触发**
 * （步骤名里没有"等可见 ×N"）。
 *
 * 那为什么还留？因为"`chmod` 是命令的最后一句、App 的 `waitFor()` 一返回就 stat"
 * 这个窗口**理论上存在**（Shizuku 的 `waitFor` 语义不保证），一旦真的发生，
 * 症状恰好是本条 KDoc 描述的"文件明明在那儿却读不到"，极难定位。代价有上限
 * （默认 3 秒 / 每 50 ms），并且：
 *
 * - **不改退出码、不吞异常**：超时后照样把同一个路径交给下游报错
 *   （那时 [ZipFs] 的报错已带解析后的绝对路径）；
 * - 真等过就会在步骤名里留痕（"等可见 ×N"）—— 那本身就是窗口存在的证据。
 */
internal suspend fun awaitRegularFile(
    workspaceRoot: java.nio.file.Path,
    rel: String,
    timeoutMs: Long = FILE_READY_TIMEOUT_MS,
    stepMs: Long = FILE_READY_STEP_MS,
): Int {
    val abs = workspaceRoot.resolve(rel)
    val deadline = System.currentTimeMillis() + timeoutMs
    var tries = 1
    while (!java.nio.file.Files.isRegularFile(abs)) {
        if (System.currentTimeMillis() >= deadline) break
        kotlinx.coroutines.delay(stepMs)
        tries++
    }
    return tries
}
