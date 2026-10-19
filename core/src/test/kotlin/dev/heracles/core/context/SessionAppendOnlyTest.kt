package dev.heracles.core.context

import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **铁律 1 的回归测试** —— `01-架构总览.md` §3、`07-开发文档.md` §6.2。
 *
 * 防的是什么：有人为了修 bug 顺手改写了历史（"把上一条 prompt 改一下重试"）。
 * 实测代价：命中率 96.8% → 24.3%，每轮从 2.1 s 变成 17–19 s，**且永久卡死**。
 */
class SessionAppendOnlyTest {

    private val frozen = PrefixBuilder.buildFrozen(
        "你是 Heracles，运行在手机上的本地 Agent。",
        listOf(
            ToolSpec(
                "send_message", "给联系人发送消息",
                listOf(ToolParam("contact", "string", "联系人"), ToolParam("text", "string", "正文")),
            )
        ),
    )

    @Test
    @DisplayName("Session 不暴露任何改写历史的方法（类型级保障）")
    fun noMutators() {
        val banned = setOf(
            "update", "replace", "clear", "remove", "removeat", "removeif",
            "insert", "edit", "delete", "set", "put", "modify", "rewrite",
        )
        val methods = Session::class.java.declaredMethods.map { it.name.lowercase() }
        val offenders = methods.filter { m -> m in banned || m.startsWith("set") }
        assertTrue(
            offenders.isEmpty(),
            "Session 出现了疑似改写历史的方法：$offenders。" +
                "完整的公开 API 应该只有 append() / render() 与只读访问器。",
        )
    }

    @Test
    @DisplayName("★ 渲染单调性：上一轮的 prompt 必须是下一轮 prompt 的前缀")
    fun renderIsMonotonic() {
        var s = Session.start(frozen)
        val renders = mutableListOf<String>()
        val steps = listOf(
            Turn.User("给张伟发消息说我晚十分钟到"),
            Turn.Assistant("好的，我来处理。"),
            Turn.ToolResult("send_message", """{"ok":true}"""),
            Turn.User("再给李娜发一条"),
            Turn.Assistant("已发送。"),
        )
        for (t in steps) {
            s = s.append(t)
            renders += s.render()
        }
        for (i in 1 until renders.size) {
            assertTrue(
                renders[i].startsWith(renders[i - 1]),
                "第 $i 轮渲染不是上一轮的前缀 —— 这会让缓存命中率从 96.8% 塌到 24.3%（实测-01 §4）",
            )
        }
    }

    @Test
    @DisplayName("append 返回新实例，不改动原实例（不可变）")
    fun appendIsPersistent() {
        val s0 = Session.start(frozen)
        val s1 = s0.append(Turn.User("a"))
        val s2 = s1.append(Turn.Assistant("b"))
        assertEquals(0, s0.turnCount)
        assertEquals(1, s1.turnCount)
        assertEquals(2, s2.turnCount)
    }

    @Test
    @DisplayName("失败重试通过 append 实现，不改写历史")
    fun retryViaAppend() {
        var s = Session.start(frozen)
        s = s.append(Turn.User("打开某应用"))
        s = s.append(Turn.ToolResult("open_app", "失败：应用不存在"))
        val afterFailure = s.render()

        // 正确做法：追加一条说明
        s = s.append(Turn.User("上一步失败了，因为应用不存在，请换一种方式"))
        assertTrue(
            s.render().startsWith(afterFailure),
            "重试路径改写了历史 —— 违反 02-契约规范.md §2.2",
        )
    }

    @Test
    @DisplayName("冻结区在会话内保持不变，且始终位于最前")
    fun frozenStableAndFirst() {
        var s = Session.start(frozen)
        repeat(20) { s = s.append(Turn.System("噪声 $it")) }
        assertEquals(frozen.hash, s.frozen.hash)
        assertTrue(s.render().startsWith(frozen.text))
    }

    @Test
    @DisplayName("prompt 随轮次单调增长（不因压缩之外的原因缩短）")
    fun promptGrowsMonotonically() {
        var s = Session.start(frozen)
        var prev = s.estimatedPromptTokens
        repeat(10) { i ->
            s = s.append(Turn.User("第 $i 步操作，打开应用并点击按钮"))
            val now = s.estimatedPromptTokens
            assertTrue(now >= prev, "第 $i 轮 prompt 缩短了：$prev → $now")
            prev = now
        }
    }

    /**
     * ★★ F7c：原生轨字段**对 [Session.render] 不可见**。
     *
     * 这是"本地文本轨零回退"的机制性保证：`nativeCalls` / `callId` / `isError`
     * 只被云端消息装配（`AgentLoop.renderAsMessages`）读取，
     * 一个字符都不许进本地/CLI 的 prompt —— 否则冻结前缀与整条 append-only
     * 前缀缓存会跟着抖（铁律 1 / F3c 的 hash 证据）。
     */
    @Test
    @DisplayName("★★ F7c：原生字段对 render 不可见 —— 带与不带渲染逐字节相同")
    fun nativeFieldsAreInvisibleToRender() {
        val plain = Session.start(frozen)
            .append(Turn.User("跑一次构建"))
            .append(Turn.Assistant("我来调用构建工具"))
            .append(Turn.ToolResult("build_apk", "ok=true"))
        val native = Session.start(frozen)
            .append(Turn.User("跑一次构建"))
            .append(
                Turn.Assistant(
                    "我来调用构建工具",
                    listOf(NativeToolCall("call_1", "build_apk", """{"variant":"debug"}""")),
                ),
            )
            .append(Turn.ToolResult("build_apk", "ok=true", callId = "call_1", isError = true))

        assertEquals(
            plain.render(), native.render(),
            "原生字段泄漏进了 render() —— 本地 prompt 就不再逐字节稳定，前缀缓存会跟着抖",
        )
        assertEquals(plain.estimatedPromptTokens, native.estimatedPromptTokens)
        assertEquals(plain.frozen.hash, native.frozen.hash)
    }
}
