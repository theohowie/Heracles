package dev.heracles.agent

import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolSpec
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * 工具分区的行为门禁 —— **ADR-035 S1b**（`docs/09`；此前是 ADR-033 / P2-3 的"按后端分级"）。
 *
 * ## 为什么这段必须可测（App 侧测不了）
 *
 * 真正的装配在 `AgentBridge`（Android 模块），那里**没有纯 JVM 单测**。
 * 而"哪个工具常驻"直接决定冻结前缀的字节（缓存命中率的前提）与门禁 G11/G13，
 * 一旦错就是"缓存命中率塌了"或"模型以为没有搜索工具"这类极难定位的问题。
 *
 * ## S1b 之后盯住五件事
 *
 * 1. **一份名单**：常驻 = [ToolZonePlan.RESIDENT] 10 个（前 7 项 = 改动前那份，**名字与顺序逐项钉住**；
 *    后 3 项是原来的"云端专有"），且 `partition` / `residentNames` **不再收 `backend`**（D2）；
 * 2. **占用 11/12**：10 个业务常驻 + `search_tools` 自己（它的 schema 也进冻结区）= **11 ≤ 12**
 *    ⇒ **只剩 1 个空位**（这条当年在"本地 8 格"上是个真坑：越档 = 后端起不了会话）；
 * 3. **完整二分**：`resident + longTail == candidates`，互不重叠、保持候选顺序
 *    —— S1b 删掉了 `CLOUD_ONLY_LONG_TAIL`，"本地缺三个破坏性工具"那种**刻意的不完整**不存在了；
 * 4. **越档当场失败**：超上限 `require` 抛错，**不静默截断**（截断 = 模型以为工具没了）；
 * 5. **数值唯一**：`Contract.Zone` 与全部 `For(backend)` 已删，只剩 `Contract.Tools` 一套
 *    （12 / 24 / 6）。
 */
class ToolZonePlanTest {

    /** 只要名字的假工具 —— 分区决策不关心工具怎么构造（fs / shell / Android 一概不碰）。 */
    private fun tool(name: String): AgentTool = object : AgentTool {
        override val spec = ToolSpec(name, "工具 $name 的描述")
        override suspend fun execute(args: Map<String, String>): ToolOutcome =
            ToolOutcome.Success("ok")
    }

    /**
     * 与 `AgentBridge` 的候选同构：7 个常驻候选 + 2 个搜索工具 + 9 个长尾候选（共 18）。
     *
     * 注意 `apply_patch` 在**候选**里排在长尾段（与 `AgentBridge` 的装配顺序一致），
     * 但 S1b 之后它在**所有人**那里都被分区到常驻 —— 候选顺序 ≠ 分区结果，
     * 这正是本测试要盯的东西（常驻结果保持的是**候选**顺序）。
     */
    private fun candidates(includeAskUser: Boolean = true): List<AgentTool> = buildList {
        add(tool("list_files"))
        add(tool("read_file"))
        add(tool("write_file"))
        add(tool("update_plan"))
        add(tool("mkdir"))
        add(tool("save_memory"))
        if (includeAskUser) add(tool("ask_user"))
        add(tool("run_shell_command"))
        add(tool("find_files"))
        add(tool("grep_files"))
        listOf(
            "scaffold_android", "build_apk", "apk_decompile", "apk_recompile",
            "apk_sign", "d8_convert", "unzip_file", "zip_file", "apply_patch",
        ).forEach { add(tool(it)) }
    }

    private fun names(tools: List<AgentTool>): List<String> = tools.map { it.spec.name }

    // ------------------------------------------------------------- 名单本身

    @Test
    @DisplayName("★ 常驻名单 = 11 个：前 10 项与改动前逐项相同，第 11 个是 update_plan（2026-10-19）")
    fun residentIsThePinnedEleven() {
        // 常量本身钉住：改名/换序/多一个都会红（这是冻结前缀的锚点）
        assertEquals(
            listOf(
                // —— 以下 7 项与改动前 `AgentBridge` 的装配名单**一位不变**
                "list_files",
                "read_file",
                "write_file",
                "mkdir",
                "save_memory",
                "ask_user",
                "run_shell_command",
                // —— 以下 3 项原为 `CLOUD_ONLY_RESIDENT`（S1b 起全员常驻）
                "find_files",
                "grep_files",
                "apply_patch",
                // —— 2026-10-19：计划工具化（模型可反复改计划）
                "update_plan",
            ),
            ToolZonePlan.RESIDENT,
        )
        assertEquals(11, ToolZonePlan.RESIDENT.size)
        assertEquals(ToolZonePlan.RESIDENT, ToolZonePlan.residentNames())
    }

    @Test
    @DisplayName("★ 冻结区占用 12/12（= 11 个业务常驻 + search_tools 自己），**已顶满**")
    fun frozenOccupancyIsTwelveOfTwelve() {
        // `search_tools` 的 schema 也进冻结区（AgentBridge 把它追加在常驻之后 → AgentLoop
        // 把整份 tools 喂给 PrefixBuilder），所以"常驻名单长度"不等于"冻结区占用"。
        // 这条钉子拦住"顺手往 RESIDENT 里再加一个"：加第 12 个就在 `PrefixBuilder.buildFrozen`
        // 当场抛（症状是**会话起不来**，不是"多一个工具"）。
        val occupied = ToolZonePlan.residentNames().size + 1
        assertEquals(12, occupied, "常驻名单 11 + search_tools 自己 = 12")
        assertTrue(
            occupied <= Contract.Tools.FROZEN_LIMIT,
            "冻结区占用 $occupied 必须 ≤ Contract.Tools.FROZEN_LIMIT=${Contract.Tools.FROZEN_LIMIT}",
        )
        assertEquals(
            0, Contract.Tools.FROZEN_LIMIT - occupied,
            "**已无空位**；若这里红了：要么往 RESIDENT 加了一个（要先挪走一个），" +
                "要么上限被改过（那是改冻结前缀字节）。当前名单：${ToolZonePlan.residentNames()}",
        )
    }

    @Test
    @DisplayName("★ S1b 的 D2：partition / residentNames 的形参里**不许**再出现 backend")
    fun planHasNoBackendParameter() {
        // 编译期已能查（调用处不再传），但"以后有人把后端分级加回来"是这类回归的典型形态，
        // 所以用反射把**元数**也钉住 —— 不是洁癖：多一个 Boolean/String 形参就意味着
        // 又出现了"同一个 backend 被两处各判一次"（`docs/27` §3 根因 C）。
        val partition = ToolZonePlan::class.java.methods.first { it.name == "partition" }
        assertEquals(1, partition.parameterCount, "partition 只该收 candidates 一个参数")
        val residentNames = ToolZonePlan::class.java.methods.first { it.name == "residentNames" }
        assertEquals(0, residentNames.parameterCount, "residentNames 不该收 backend")
    }

    // ------------------------------------------------------------- 分区结果

    @Test
    @DisplayName("★ 11 个进常驻（顺序 = 候选顺序），其余 8 个进长尾")
    fun partitionSplitsTheElevenResident() {
        val all = candidates()
        val p = ToolZonePlan.partition(all)

        assertEquals(
            listOf(
                "list_files",
                "read_file",
                "write_file",
                "update_plan",
                "mkdir",
                "save_memory",
                "ask_user",
                "run_shell_command",
                // 顺序 = **候选**顺序（apply_patch 在候选里排在长尾段末尾，所以它在最后）
                "find_files",
                "grep_files",
                "apply_patch",
            ),
            names(p.resident),
            "常驻必须按候选顺序取那 11 个",
        )
        assertEquals(11, p.resident.size)
        assertTrue(
            p.resident.size <= Contract.Tools.FROZEN_LIMIT,
            "常驻 ${p.resident.size} 个超过 FROZEN_LIMIT=${Contract.Tools.FROZEN_LIMIT}",
        )
        // F3b 的要点：模型**手头就有**局部替换，不必先 search_tools 才知道它存在
        assertTrue("apply_patch" in names(p.resident), "apply_patch 必须常驻（F3b / P1-2）")
        assertFalse("apply_patch" in names(p.longTail), "已常驻就不该还在长尾")
        assertFalse("find_files" in names(p.longTail), "已常驻就不该还在长尾")
        assertEquals(8, p.longTail.size)
    }

    @Test
    @DisplayName("没有 ask_user 的调用方（CLI/测试）：10 个常驻，不报错")
    fun askUserIsOptional() {
        val all = candidates(includeAskUser = false)
        val p = ToolZonePlan.partition(all)
        assertEquals(10, p.resident.size)
        assertFalse("ask_user" in names(p.resident))
        assertFalse("ask_user" in names(p.longTail), "候选里没有就是没有 —— 不许凭空造一个")
    }

    @Test
    @DisplayName("★ S1b：三个破坏性文件工具**所有人**都能在长尾拿到（原「本地彻底没有」已取消）")
    fun pathToolsAreReachableForEveryone() {
        val pathNames = listOf("delete_path", "move_path", "copy_path")
        val all = candidates() + pathNames.map { tool(it) }
        val p = ToolZonePlan.partition(all)

        assertTrue(
            pathNames.all { it in names(p.longTail) },
            "★ 原 `CLOUD_ONLY_LONG_TAIL` 的三件套必须都进长尾：${names(p.longTail)}",
        )
        // 长尾仍是 11（= 22 个候选 − 11 个常驻），上限 24 有余量
        assertEquals(11, p.longTail.size)
        assertTrue(
            p.longTail.size <= Contract.Tools.LONG_TAIL_LIMIT,
            "长尾 ${p.longTail.size} 必须 ≤ ${Contract.Tools.LONG_TAIL_LIMIT}",
        )
    }

    // ------------------------------------------------------------- 二分完整性

    @Test
    @DisplayName("分区是完整二分：并集 = 候选、互不重叠、各自保持候选相对顺序")
    fun partitionIsATotalOrderPreservingSplit() {
        val all = candidates()
        val p = ToolZonePlan.partition(all)
        val residentNames = ToolZonePlan.residentNames()

        assertEquals(all.size, p.resident.size + p.longTail.size, "分区必须覆盖全部候选")
        assertEquals(
            names(all).filter { it in residentNames },
            names(p.resident),
            "常驻必须保持候选相对顺序",
        )
        assertEquals(
            names(all).filter { it !in residentNames },
            names(p.longTail),
            "长尾必须保持候选相对顺序",
        )
        assertEquals(
            names(all).sorted(),
            (names(p.resident) + names(p.longTail)).sorted(),
            "分区并集必须 = 候选集合（不许丢工具、不许重复）",
        )
        assertTrue(
            names(p.resident).intersect(names(p.longTail).toSet()).isEmpty(),
            "常驻与长尾不得重叠",
        )
    }

    // ------------------------------------------------------------- 越档语义

    @Test
    @DisplayName("★ 越档当场失败（不静默截断），且错误信息带上被违反的上限值")
    fun overCapFailsLoudly() {
        // 候选：18 个正常 + 17 个额外长尾 = 35 ⇒ 长尾 = 35 - 10（常驻）= 25 > LONG_TAIL_LIMIT(24)
        val tooManyLongTail = candidates() + (1..17).map { tool("extra_$it") }

        val e = assertThrows(IllegalArgumentException::class.java) {
            ToolZonePlan.partition(tooManyLongTail)
        }
        val message = e.message.orEmpty()
        assertTrue(message.contains("长尾"), "错误信息要点明是哪一区越档：$message")
        assertTrue(
            message.contains(Contract.Tools.LONG_TAIL_LIMIT.toString()),
            "错误信息要带上被违反的上限值：$message",
        )

        // 刚好到上限（长尾 24）合法 —— 边界必须是闭区间，否则"能用 23 个"这种隐性损失没人发现
        val exactlyAtCap = candidates() + (1..16).map { tool("extra_$it") }
        assertEquals(Contract.Tools.LONG_TAIL_LIMIT, ToolZonePlan.partition(exactlyAtCap).longTail.size)
    }

    // ------------------------------------------------------------- 数值唯一

    @Test
    @DisplayName("★ 只有一套上限（12 / 24 / 6）；`Contract.Zone` 已删，不存在按后端取值")
    fun limitsAreSingleTierAndPinned() {
        // 具体数值钉住（改动 = 改缓存的输入，必须是有意为之）
        assertEquals(12, Contract.Tools.FROZEN_LIMIT)
        assertEquals(24, Contract.Tools.LONG_TAIL_LIMIT)
        assertEquals(6, Contract.Tools.DISCLOSE_LIMIT)

        // 今天真实占用必须装得下（否则上面那条"只剩 1 个空位"是空话）
        val resident = ToolZonePlan.residentNames().size
        assertTrue(resident + 1 <= Contract.Tools.FROZEN_LIMIT)
        assertTrue(resident < Contract.Tools.FROZEN_LIMIT, "常驻名单本身也不该顶满上限")
    }
}
