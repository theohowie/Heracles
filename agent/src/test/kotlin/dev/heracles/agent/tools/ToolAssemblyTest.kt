package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.agent.ToolZonePlan
import dev.heracles.core.tool.ToolRegistry
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files

/**
 * **工具装配的真机等价复现**（2026-10-19）。
 *
 * ## 为什么要有这个文件
 *
 * 同一天在真机上踩了两次坑，**单测都是绿的**：
 *
 * 1. `edit` 登记在 `PatchTools.GROUPS`，但校验只认 `AndroidTools.GROUPS` ⇒ 启动期抛异常；
 * 2. 修完 ① 后模型在真机上仍然说"我没有看图的工具" —— 说明 `view_image` 没进可用集。
 *
 * 两次的共同点：**没有任何一个测试把"装配之后工具到底能不能被模型拿到"这件事跑一遍**。
 * 各模块只管自己造实例、自己写 GROUPS，谁也没验证"合起来之后 `search_tools` 搜得到吗"。
 *
 * ⇒ 本文件按 `AgentBridge` 的真实装配顺序重建一遍（造实例 → `partition` → `ToolRegistry`
 * → `SearchToolsTool`），然后**像模型一样去搜**。它不碰 Android、不碰网络。
 */
class ToolAssemblyTest {

    private fun fs(): RealWorkspaceFs =
        RealWorkspaceFs.open(Files.createTempDirectory("heracles-asm-test"))

    /**
     * 复刻 `AgentBridge` 的装配：长尾工具 + 分区 + 注册表 + 披露入口。
     *
     * ⚠️ 与 `AgentBridge` 的**唯一差异**是省掉了需要 Android 的东西（构建工具、shell 运行器）。
     * 工具名单、分区规则、分组表都走真实实现。
     */
    private class Assembly(val resident: List<AgentTool>, val longTail: List<AgentTool>) {
        val disclosed = mutableSetOf<String>()
        val registry = ToolRegistry(
            resident = resident.map { it.spec },
            longTail = longTail.map { it.spec },
            groups = AndroidTools.allGroups,
        )
        val all: List<AgentTool> = resident + longTail

        fun search(query: String): ToolOutcome = runBlocking {
            SearchToolsTool(registry, disclosed).execute(mapOf("query" to query))
        }
    }

    private fun assemble(): Assembly {
        val fs = fs()
        // ★ 必须按 **AgentBridge 的真实顺序**装配：先造全部候选（含常驻那 11 个的名字来源），
        //   再 `partition` 按名字分。只喂长尾候选会让 partition 把 apply_patch 当成"长尾里多出来的"，
        //   与真机装配不一致（本文件第一版就踩了这个）。
        val candidates: List<AgentTool> = buildList {
            // 常驻那 11 个（这里只造不依赖 Android 的；名字对齐 ToolZonePlan.RESIDENT）
            add(ApplyPatchTool(fs))
            // 长尾
            addAll(ImageTools.create(fs))
            addAll(WebTools.create())
            add(EditFileTool(fs))
            add(UnzipFileTool(fs))
            add(ZipFileTool(fs))
        }
        val zone = ToolZonePlan.partition(candidates)
        return Assembly(zone.resident, zone.longTail)
    }

    @Test
    @DisplayName("★★ 装配后：分组校验不抛（真机事故 1：edit 被判没登记分组）")
    fun assemblyPassesGroupConsistency() {
        val a = assemble()
        // 这就是 AgentBridge 启动期调的那个校验 —— 过去它会在 edit 上抛
        AndroidTools.assertConsistent(a.all)
        assertTrue(true)
    }

    @Test
    @DisplayName("★★ 装配后：search_tools 能搜到 view_image（真机事故 2：模型说没有看图工具）")
    fun searchFindsViewImage() {
        val a = assemble()
        for (query in listOf("查看图片", "读取图片", "image", "图", "截图")) {
            val out = a.search(query)
            assertTrue(out is ToolOutcome.Success, "搜「$query」应当命中：$out")
            assertTrue(
                (out as ToolOutcome.Success).detail.contains("view_image"),
                "搜「$query」必须能披露 view_image：${out.detail}",
            )
            assertTrue("view_image" in a.disclosed, "披露集里必须有 view_image")
        }
    }

    @Test
    @DisplayName("★ 装配后：search_tools 能搜到 edit / apply_patch（改码两条路）")
    fun searchFindsEditingTools() {
        val a = assemble()
        val out = a.search("编辑 修改 替换 文本")
        assertTrue(out is ToolOutcome.Success, "应当命中：$out")
        val text = (out as ToolOutcome.Success).detail
        assertTrue(text.contains("edit") || text.contains("apply_patch"), "改码工具必须能被搜到：$text")
    }

    @Test
    @DisplayName("★ 装配后：search_tools 能搜到 web_fetch")
    fun searchFindsWebFetch() {
        val a = assemble()
        val out = a.search("网页 抓取 文档")
        assertTrue(out is ToolOutcome.Success, "应当命中：$out")
        assertTrue((out as ToolOutcome.Success).detail.contains("web_fetch"))
    }

    @Test
    @DisplayName("★★ 每个长尾工具都至少能被一条常见说法搜到（漏一个 = 模型的盲区）")
    fun everyLongTailToolIsDiscoverable() {
        val a = assemble()
        // 这是"模型的自然语言 → 工具"的探针表：新增长尾工具**必须**在这里加一行，
        // 否则它会成为模型永远拿不到的死工具。
        val probes = mapOf(
            "edit" to "替换 编辑",
            "view_image" to "查看图片",
            "web_fetch" to "网页 抓取",
            "unzip_file" to "解压",
            "zip_file" to "打包 zip",
        )
        for ((tool, query) in probes) {
            val out = a.search(query)
            val text = if (out is ToolOutcome.Success) out.detail else ""
            assertTrue(
                text.contains(tool),
                "工具 `$tool` 用「$query」搜不到 —— 模型将永远拿不到它。实际返回：$out",
            )
        }
    }

    @Test
    @DisplayName("反证：不在注册表里的工具搜不到（搜索不是「永远返回点什么」）")
    fun unknownToolIsNotDiscoverable() {
        val a = assemble()
        val out = a.search("量子传送 时间旅行")
        assertTrue(out is ToolOutcome.Failure, "无关查询必须如实说没找到：$out")
        assertFalse((out as ToolOutcome.Failure).reason.contains("view_image"))
    }
}
