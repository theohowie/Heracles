package dev.heracles.core.tool

/**
 * 工具分组 —— `26-编码层工具链与逆向引擎.md` §5。
 *
 * ## 它解决什么
 *
 * 长尾工具（`apk_decompile` / `d8_convert` / …）**不进冻结区**，
 * 只在 `search_tools` 命中后才被披露。而 `search_tools` 的检索质量取决于
 * "同义说法能不能对上"：模型可能搜「打包」「构建」「compile」「apk」——
 * 这些话都不在工具描述的原文里。
 *
 * ⇒ 分组把**同义词**集中在一处，检索时把整组的词都算作命中面。
 *
 * ## 为什么分类是**显式传入**而不是自动猜
 *
 * 自动分类（按关键词给工具归组）看着聪明，实则脆弱：`build_apk` 含 "apk"，
 * `apk_recompile` 含 "compile" —— 两者都会归错。而分组一旦归错，
 * 检索就静默变差，**没有任何症状**。
 *
 * ⇒ 由**知道工具是什么的人**（`:agent` 侧的注册代码）显式指定分组。
 * 本枚举只负责"这一组有哪些同义词"。
 */
enum class ToolGroup(val label: String, val keywords: List<String>) {

    FILE("文件", listOf("file", "read", "write", "dir", "list", "mkdir", "文件", "目录", "读", "写", "列出")),

    ARCHIVE("压缩包", listOf("zip", "unzip", "archive", "jar", "压缩", "解压", "打包成zip")),

    PATCH("补丁", listOf("patch", "diff", "hunk", "edit", "modify", "补丁", "修改", "改动", "差异")),

    APK("APK 逆向", listOf(
        "apk", "smali", "dex", "jadx", "apktool", "decompile", "recompile",
        "sign", "keystore", "逆向", "反编译", "解包", "重打包", "签名", "改包",
    )),

    BUILD("构建", listOf(
        "build", "compile", "javac", "kotlinc", "aapt2", "d8", "zipalign",
        "构建", "编译", "打包", "出新apk", "从零",
    )),

    DEVICE("设备", listOf(
        "shell", "sh", "shizuku", "stellar", "logcat", "install", "pm", "adb",
        "设备", "命令", "执行命令", "安装", "日志",
    )),

    NETWORK("网络", listOf(
        "web", "http", "https", "url", "fetch", "download", "page", "docs",
        "网页", "网站", "联网", "抓取", "下载", "文档", "链接",
    )),

    META("元工具", listOf("search", "tool", "help", "find", "工具", "搜索", "查找", "有什么")),
}
