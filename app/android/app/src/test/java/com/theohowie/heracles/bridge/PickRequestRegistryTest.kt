package com.theohowie.heracles.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * **进程级「选目录请求」登记表的单测**（2026-11-02 · T0 SAF 黑屏）。
 *
 * ## 为什么这些用例值得写
 *
 * 真机上要复现「Activity 在 SAF 期间被系统回收」得靠开发者选项
 * 「不保留活动」或运气；而真正的判定逻辑（重建后还能不能配对、结果会不会丢、
 * 陈旧结果会不会串到下一次）**全是纯内存状态机** —— 完全可以确定性地测。
 *
 * 所以被测类刻意不 import 任何 `android.*`：JVM 直接 `new` 出来就能跑。
 *
 * | 用例 | 防的是什么 |
 * |---|---|
 * | 重建后仍是同一个登记表 | 又退回到"实例字段"那个原始 bug |
 * | 结果只交付一次 | 取消 + onActivityResult 同时到达 ⇒ 用户被切两次工作区 |
 * | 新请求作废旧结果 | 超时回收拿到上一次的目录 ⇒ 工作区莫名其妙被换掉 |
 * | TTL 过期 | 5 分钟前的陈旧结果被当成这次选的 |
 * | requestId 不匹配 | 两次请求交错时把 A 的结果交给 B |
 */
class PickRequestRegistryTest {

    private lateinit var registry: PickRequestRegistry

    /** 可控时钟 —— 测 TTL 不用真等 5 分钟。 */
    private var now = 1_000_000L

    @Before
    fun setUp() {
        now = 1_000_000L
        registry = PickRequestRegistry { now }
    }

    @Test
    fun `takeSink 交回登记的收件人，且只交付一次`() {
        var received: Map<String, Any?>? = null
        var calls = 0
        registry.begin("req-1") { received = it; calls++ }

        val sink = registry.takeSink()
        assertNotNull("登记过的请求必须能取到收件人", sink)
        sink!!.invoke(mapOf("path" to "/a"))

        assertEquals(1, calls)
        assertEquals("/a", received?.get("path"))
        // ★ 二次取 = null：结果绝不能交付两遍
        assertNull("同一请求不得交付第二次", registry.takeSink())
    }

    @Test
    fun `没有登记时 takeSink 返回 null —— 不许崩`() {
        assertNull(registry.takeSink())
        assertNull(registry.pendingRequestId())
        assertFalse(registry.hasPending())
    }

    @Test
    fun `pendingRequestId 反映当前请求，取走后清空`() {
        registry.begin("req-42") { }
        assertEquals("req-42", registry.pendingRequestId())
        assertTrue(registry.hasPending())

        registry.takeSink()
        assertNull(registry.pendingRequestId())
        assertFalse(registry.hasPending())
    }

    @Test
    fun `populated completed 能被同一 requestId 取回，且取过即作废`() {
        registry.recordCompleted("req-7", mapOf("path" to "/picked"))

        val got = registry.consumeCompleted("req-7")
        assertEquals("/picked", got?.get("path"))
        // 幂等消费：第二次拿不到（防同一个结果被用两次）
        assertNull(registry.consumeCompleted("req-7"))
    }

    @Test
    fun `requestId 不匹配 ⇒ 拿不到别人的结果`() {
        registry.recordCompleted("req-A", mapOf("path" to "/a"))
        assertNull("A 的结果不能交给 B", registry.consumeCompleted("req-B"))
        // 不匹配也不该把结果吃掉
        assertEquals("/a", registry.consumeCompleted("req-A")?.get("path"))
    }

    @Test
    fun `空 requestId（老调用方）按最近一次结果交付`() {
        registry.recordCompleted("req-x", mapOf("path" to "/legacy"))
        assertEquals("/legacy", registry.consumeCompleted("")?.get("path"))
    }

    @Test
    fun `超过 TTL 的结果作废`() {
        registry.recordCompleted("req-ttl", mapOf("path" to "/old"))
        now += PickRequestRegistry.COMPLETED_TTL_MS + 1
        assertNull("过期结果绝不能当成这次选的", registry.consumeCompleted("req-ttl"))
    }

    @Test
    fun `TTL 边界内仍然有效`() {
        registry.recordCompleted("req-ttl2", mapOf("path" to "/fresh"))
        now += PickRequestRegistry.COMPLETED_TTL_MS
        assertEquals("/fresh", registry.consumeCompleted("req-ttl2")?.get("path"))
    }

    @Test
    fun `开始新请求会作废上一次没取走的结果`() {
        registry.recordCompleted("req-old", mapOf("path" to "/old"))
        registry.begin("req-new") { }
        assertNull(
            "新请求开始时旧结果必须作废，否则本次超时回收会拿到上次的目录",
            registry.consumeCompleted("req-old"),
        )
    }

    @Test
    fun `取消也能交付 —— null 是合法结果，不是没有结果`() {
        var called = false
        var payload: Map<String, Any?>? = mapOf("path" to "/stale")
        registry.begin("req-cancel") { payload = it; called = true }

        val sink = registry.takeSink()
        sink!!.invoke(null)

        assertTrue("取消路径同样要把结果交出去（Dart 据 null 判'没选'）", called)
        assertNull(payload)
    }

    @Test
    fun `clearPending 之后取不到收件人（startActivityForResult 抛异常那条路）`() {
        registry.begin("req-boom") { }
        registry.clearPending()
        assertNull(registry.takeSink())
        assertFalse(registry.hasPending())
    }

    @Test
    fun `reset 清空所有状态`() {
        registry.begin("req-1") { }
        registry.recordCompleted("req-1", mapOf("path" to "/x"))
        registry.reset()
        assertNull(registry.takeSink())
        assertNull(registry.consumeCompleted("req-1"))
    }

    @Test
    fun `单例是进程级的 —— 两次取到的是同一个对象`() {
        // ★ 这条锁的正是原始 bug：若有人把它改回"每次 new 一个"，
        //   Activity 重建后新实例就看不到旧实例的登记。
        val a = PickRequestRegistry.instance
        val b = PickRequestRegistry.instance
        assertTrue("PickRequestRegistry.instance 必须是同一个对象", a === b)
    }
}
