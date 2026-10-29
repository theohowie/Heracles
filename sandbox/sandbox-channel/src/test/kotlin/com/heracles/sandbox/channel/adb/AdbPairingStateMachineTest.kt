/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 *
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：tianxuan (xiaozhe7772222/tianxuan) @ caad40090a4f2c2edbe54e6eaae60a3dd1de7d21
 *   原文件：runtime/src/main/java/top/wkbin/tianxuan/runtime/bridge/adb/EmbeddedAdbManager.kt
 *           （被验证的行为：配对码 6 位数字、端口 1024..65535、
 *             配对端口 ≠ 连接端口、连不上时回环重试）
 *
 * 本测试是**纯 JVM** 的：状态机不依赖 android.*，时间由假时钟驱动，
 * 因此不需要 Robolectric、不需要真机、不需要 sleep。
 */

package com.heracles.sandbox.channel.adb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [AdbPairingStateMachine] 的状态迁移测试。
 *
 * <p>覆盖：
 * 1. 完整成功路径 DISCONNECTED → PAIRING_PORT_PROBE → AUTH_HANDSHAKE → CONNECTING → CONNECTED
 * 2. 每条失败路径都停在 FAILED 且带正确的 [AdbFailure]
 * 3. 非法输入（配对码 / 端口）在**进入状态机时就**被拒，不会走到网络层
 * 4. 超时判定（用假时钟，不 sleep）
 * 5. 非法迁移被忽略而不是抛异常
 * 6. Retry 只能从 FAILED 出发
 */
class AdbPairingStateMachineTest {

    /** 假时钟：步长可控，避免测试依赖真实时间。 */
    private class FakeClock(var millis: Long = 1_000L) : () -> Long {
        override fun invoke(): Long = millis
        fun advance(by: Long): Long {
            millis += by
            return millis
        }
    }

    private fun machineWith(clock: FakeClock = FakeClock()): AdbPairingStateMachine =
        AdbPairingStateMachine(now = clock, timeoutMillis = AdbPairingStateMachine.DEFAULT_TIMEOUTS)

    // ── 1. 成功路径 ─────────────────────────────────────────────────────

    @Test
    fun `happy path reaches CONNECTED through every state in order`() {
        val clock = FakeClock()
        val machine = machineWith(clock)

        assertEquals(AdbPairingState.DISCONNECTED, machine.state)

        // 发现配对端点
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))
        assertEquals(AdbPairingState.PAIRING_PORT_PROBE, machine.state)
        assertEquals("127.0.0.1:37123", machine.snapshot.pairingEndpoint)

        // 端口探测通过
        machine.handle(AdbPairingEvent.PairingPortAccepted)
        assertEquals(AdbPairingState.AUTH_HANDSHAKE, machine.state)

        // SPAKE2 交换成功
        machine.handle(AdbPairingEvent.AuthSucceeded)
        assertEquals(AdbPairingState.CONNECTING, machine.state)

        // 连接端点出现
        machine.handle(AdbPairingEvent.ConnectEndpointAvailable("127.0.0.1", 42111))
        assertEquals(AdbPairingState.CONNECTING, machine.state)
        assertEquals("127.0.0.1:42111", machine.snapshot.connectEndpoint)

        // 链路探活成功
        machine.handle(AdbPairingEvent.LinkEstablished)
        assertEquals(AdbPairingState.CONNECTED, machine.state)
        assertTrue(machine.snapshot.isConnected)
        assertNull(machine.snapshot.failure)
    }

    @Test
    fun `StartPairing with discovered endpoint goes to PAIRING_PORT_PROBE`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("192.168.1.7", 40001))
        val snapshot = machine.handle(AdbPairingEvent.StartPairing("123456"))

        assertEquals(AdbPairingState.PAIRING_PORT_PROBE, snapshot.state)
        // port=0 表示「用已发现的端点」，端点不应被覆盖成 127.0.0.1:0
        assertEquals("192.168.1.7:40001", snapshot.pairingEndpoint)
    }

    @Test
    fun `StartPairing with explicit port overrides discovered endpoint`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("10.0.0.2", 40001))
        val snapshot = machine.handle(AdbPairingEvent.StartPairing("123456", "192.168.1.9", 40123))

        assertEquals(AdbPairingState.PAIRING_PORT_PROBE, snapshot.state)
        assertEquals("192.168.1.9:40123", snapshot.pairingEndpoint)
    }

    // ── 2. 失败路径 ─────────────────────────────────────────────────────

    @Test
    fun `invalid pairing code fails immediately without touching the network`() {
        val machine = machineWith()
        // 五位 / 七位 / 含字母 / 空串，全部应当在状态机入口被拒
        listOf("12345", "1234567", "12345a", "", " 123456").forEach { bad ->
            val snapshot = machine.handle(AdbPairingEvent.StartPairing(bad))
            assertEquals("配对码 \"$bad\" 应被拒", AdbPairingState.FAILED, snapshot.state)
            assertEquals(AdbFailure.INVALID_PAIRING_CODE, snapshot.failure)
            // 不可重试：要先改输入
            assertFalse(snapshot.failure!!.retryable)
            machine.handle(AdbPairingEvent.Disconnect)
        }
    }

    @Test
    fun `start pairing without discovered endpoint fails with NO_PAIRING_ENDPOINT`() {
        val machine = machineWith()
        val snapshot = machine.handle(AdbPairingEvent.StartPairing("123456"))

        assertEquals(AdbPairingState.FAILED, snapshot.state)
        assertEquals(AdbFailure.NO_PAIRING_ENDPOINT, snapshot.failure)
        assertTrue(snapshot.failure!!.retryable)
    }

    @Test
    fun `port out of range is rejected in both directions`() {
        val machine = machineWith()

        // 配对端点端口越界（1023 是特权端口下界之外，0 是未指定）
        listOf(0, 80, 1023, 65536, -1).forEach { bad ->
            val discovered = machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", bad))
            assertEquals("端口 $bad 应被拒", AdbPairingState.FAILED, discovered.state)
            assertEquals(AdbFailure.INVALID_PORT, discovered.failure)
            machine.handle(AdbPairingEvent.Disconnect)
        }

        // 连接端点端口越界
        val connect = machine.handle(AdbPairingEvent.StartConnect(port = 65536))
        assertEquals(AdbPairingState.FAILED, connect.state)
        assertEquals(AdbFailure.INVALID_PORT, connect.failure)
    }

    @Test
    fun `pairing port rejection surfaces the given failure verbatim`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))
        val snapshot = machine.handle(
            AdbPairingEvent.PairingPortRejected(
                AdbFailure.PAIRING_PORT_UNREACHABLE,
                "配对端口 127.0.0.1:37123 不可达",
            ),
        )
        assertEquals(AdbPairingState.FAILED, snapshot.state)
        assertEquals(AdbFailure.PAIRING_PORT_UNREACHABLE, snapshot.failure)
        assertTrue(snapshot.failureMessage.contains("不可达"))
    }

    @Test
    fun `auth failure keeps TLS distinct from wrong pairing code`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))
        machine.handle(AdbPairingEvent.PairingPortAccepted)

        // 上游的经验：TLS 握手失败多半是「拿连接端口当配对端口」，与配对码错是两回事
        val tls = machine.handle(AdbPairingEvent.AuthFailed(AdbFailure.TLS_HANDSHAKE_FAILED, "SSL"))
        assertEquals(AdbFailure.TLS_HANDSHAKE_FAILED, tls.failure)
        assertTrue("TLS 失败应可重试（可能只是端口变了）", tls.failure!!.retryable)

        machine.handle(AdbPairingEvent.Disconnect)
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))
        machine.handle(AdbPairingEvent.PairingPortAccepted)
        val wrongCode = machine.handle(AdbPairingEvent.AuthFailed(AdbFailure.AUTH_FAILED, "bad code"))
        assertEquals(AdbFailure.AUTH_FAILED, wrongCode.failure)
        assertTrue(wrongCode.failure!!.retryable)
    }

    @Test
    fun `link failure from CONNECTING lands in FAILED`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))
        assertEquals(AdbPairingState.CONNECTING, machine.state)

        val snapshot = machine.handle(AdbPairingEvent.LinkFailed(AdbFailure.CONNECT_PORT_UNREACHABLE, "refused"))
        assertEquals(AdbPairingState.FAILED, snapshot.state)
        assertEquals(AdbFailure.CONNECT_PORT_UNREACHABLE, snapshot.failure)
    }

    // ── 3. 超时（假时钟，不 sleep）───────────────────────────────────────

    @Test
    fun `tick under budget keeps the state`() {
        val clock = FakeClock()
        val machine = machineWith(clock)
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))

        val budget = AdbPairingStateMachine.DEFAULT_TIMEOUTS.getValue(AdbPairingState.PAIRING_PORT_PROBE)
        val snapshot = machine.handle(AdbPairingEvent.Tick(elapsedMillis = budget - 1))

        assertEquals(AdbPairingState.PAIRING_PORT_PROBE, snapshot.state)
        assertNull(snapshot.failure)
    }

    @Test
    fun `tick at budget fails with TIMEOUT`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))

        val budget = AdbPairingStateMachine.DEFAULT_TIMEOUTS.getValue(AdbPairingState.CONNECTING)
        val snapshot = machine.handle(AdbPairingEvent.Tick(elapsedMillis = budget))

        assertEquals(AdbPairingState.FAILED, snapshot.state)
        assertEquals(AdbFailure.TIMEOUT, snapshot.failure)
        assertTrue(snapshot.failureMessage.contains("未完成"))
    }

    @Test
    fun `tick on a terminal state is a no-op`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))
        machine.handle(AdbPairingEvent.LinkEstablished)
        assertEquals(AdbPairingState.CONNECTED, machine.state)

        val snapshot = machine.handle(AdbPairingEvent.Tick(elapsedMillis = 999_999))
        assertEquals(AdbPairingState.CONNECTED, snapshot.state)
        assertNull(snapshot.failure)
    }

    // ── 4. 非法迁移被忽略（不抛异常）─────────────────────────────────────

    @Test
    fun `events arriving in the wrong state are ignored rather than throwing`() {
        val machine = machineWith()

        // 还没配对就报「认证成功」——忽略
        assertEquals(AdbPairingState.DISCONNECTED, machine.handle(AdbPairingEvent.AuthSucceeded).state)
        // 还没探测端口就报「端口接受」——忽略
        assertEquals(AdbPairingState.DISCONNECTED, machine.handle(AdbPairingEvent.PairingPortAccepted).state)
        // 还没连接就报「链路建立」——忽略
        assertEquals(AdbPairingState.DISCONNECTED, machine.handle(AdbPairingEvent.LinkEstablished).state)

        // 连上之后再来配对端点发现 —— 忽略（不能让流程中途被换端点）
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))
        machine.handle(AdbPairingEvent.LinkEstablished)
        val after = machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))
        assertEquals(AdbPairingState.CONNECTED, after.state)
        assertEquals("", after.pairingEndpoint)
    }

    @Test
    fun `LinkEstablished is idempotent on an already connected link`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))
        machine.handle(AdbPairingEvent.LinkEstablished)
        val once = machine.snapshot

        val twice = machine.handle(AdbPairingEvent.LinkEstablished)
        assertEquals(AdbPairingState.CONNECTED, twice.state)
        // 重复的「已连上」不应该重置进入时刻（否则宿主的「已连 N 秒」会跳）
        assertEquals(once.stateEnteredAtMillis, twice.stateEnteredAtMillis)
    }

    // ── 5. Retry 只能从 FAILED 出发 ──────────────────────────────────────

    @Test
    fun `retry from FAILED returns to DISCONNECTED and counts the attempt`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.StartConnect(port = 65536))
        assertEquals(AdbPairingState.FAILED, machine.state)

        val snapshot = machine.handle(AdbPairingEvent.Retry)
        assertEquals(AdbPairingState.DISCONNECTED, snapshot.state)
        assertEquals(1, snapshot.attempt)
        assertNull(snapshot.failure)
    }

    @Test
    fun `retry outside FAILED is ignored`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))
        val snapshot = machine.handle(AdbPairingEvent.Retry)

        assertEquals(AdbPairingState.CONNECTING, snapshot.state)
        assertEquals(0, snapshot.attempt)
    }

    @Test
    fun `repeated failures accumulate attempts across retries`() {
        val machine = machineWith()
        repeat(3) {
            machine.handle(AdbPairingEvent.StartConnect(port = 80))
            assertEquals(AdbPairingState.FAILED, machine.state)
            machine.handle(AdbPairingEvent.Retry)
        }
        assertEquals(3, machine.snapshot.attempt)
    }

    // ── 6. Disconnect / reset ───────────────────────────────────────────

    @Test
    fun `disconnect clears endpoints and failure from any state`() {
        val machine = machineWith()
        machine.handle(AdbPairingEvent.PairingEndpointDiscovered("127.0.0.1", 37123))
        machine.handle(AdbPairingEvent.PairingPortAccepted)
        machine.handle(AdbPairingEvent.AuthSucceeded)
        machine.handle(AdbPairingEvent.ConnectEndpointAvailable("127.0.0.1", 42111))
        machine.handle(AdbPairingEvent.LinkEstablished)
        assertEquals(AdbPairingState.CONNECTED, machine.state)

        val snapshot = machine.handle(AdbPairingEvent.Disconnect)
        assertEquals(AdbPairingState.DISCONNECTED, snapshot.state)
        assertEquals("", snapshot.pairingEndpoint)
        assertEquals("", snapshot.connectEndpoint)
        assertNull(snapshot.failure)
    }

    // ── 7. 纯函数工具 ───────────────────────────────────────────────────

    @Test
    fun `pairing code validation matches the 6 digit rule`() {
        assertTrue(AdbPairingStateMachine.isValidPairingCode("000000"))
        assertTrue(AdbPairingStateMachine.isValidPairingCode("987654"))
        assertFalse(AdbPairingStateMachine.isValidPairingCode("12345"))
        assertFalse(AdbPairingStateMachine.isValidPairingCode("1234567"))
        assertFalse(AdbPairingStateMachine.isValidPairingCode("12 456"))
        assertFalse(AdbPairingStateMachine.isValidPairingCode("abcdef"))
    }

    @Test
    fun `port validation uses 1024 to 65535`() {
        assertFalse(AdbPairingStateMachine.isValidPort(0))
        assertFalse(AdbPairingStateMachine.isValidPort(1023))
        assertTrue(AdbPairingStateMachine.isValidPort(1024))
        assertTrue(AdbPairingStateMachine.isValidPort(65535))
        assertFalse(AdbPairingStateMachine.isValidPort(65536))
    }

    @Test
    fun `endpoint formatting brackets IPv6 hosts`() {
        assertEquals("127.0.0.1:42111", AdbPairingStateMachine.formatEndpoint("127.0.0.1", 42111))
        assertEquals("[::1]:42111", AdbPairingStateMachine.formatEndpoint("::1", 42111))
    }

    @Test
    fun `snapshot is a stable value object`() {
        val machine = machineWith()
        val first = machine.snapshot
        machine.handle(AdbPairingEvent.StartConnect(port = 42111))
        // 旧快照不应被后续迁移改写（不可变性）
        assertEquals(AdbPairingState.DISCONNECTED, first.state)
        assertNotNull(machine.snapshot.connectEndpoint)
    }
}
