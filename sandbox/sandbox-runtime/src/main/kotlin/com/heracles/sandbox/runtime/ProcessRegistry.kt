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
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f
 *           runtime/src/main/java/top/wkbin/taixu/runtime/shell/ProcessRegistry.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/shell/ForegroundCommandAdmission.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/shell/CommandResourcePolicy.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/shell/ProcessTreeReaper.kt
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * 沙箱的「进程账本」。把执行分成两类，各自一套并发策略：
 *
 *   - **前台有界命令**（[ExecutionKind.FOREGROUND]）
 *     一次性的 `ls` / `cat` / `git` / `gradle` …。有并发上限（[maxForeground]），
 *     超限**立即拒绝**（CODE_BUSY）而不是排队 —— AIDL 契约明确要求这样，
 *     因为排队会让宿主侧的「点一下没反应」变成「点了等十秒」。
 *     必须有超时、必须可取消、退出后记账回收。
 *
 *   - **持久进程**（[ExecutionKind.PERSISTENT]）
 *     dev server / 长跑 watcher / 交互式 shell。**不受**前台并发上限约束，
 *     但总数也有上限（[maxPersistent]），且必须能被显式列出与逐个停掉。
 *
 * 另外承担**进程树回收**：Java 的 `Process.destroyForcibly()` 只作用于直接子进程；
 * PRoot 卡在 tracee 等待上时，SIGKILL 之后它的 tracee（`bash -l` 的子进程、
 * gradle 后代）会被 reparent 到 init 永久存活，App 侧再无手段回收。
 * ⇒ [ProcessTreeReaper] 走 /proc 枚举后代 + 同 uid SIGKILL。
 *
 * ============================================================================
 * 与上游 taixu 的差异（逐条）
 * ============================================================================
 * 1. **不移植 `ProcessLogStore`**（上游按 id/toolId 存行日志 + Flow 观察）。
 *    沙箱的流式输出直接走 `IExecutionCallback.onOutput`（AIDL 契约），
 *    不需要在内存里再攒一份日志。省掉的还有 `observeLogs/getLogs/clearLogs`。
 * 2. **不移植 `CommandResourcePolicy` 的「重型命令」推断**（上游那 100 行
 *    正则/分词器把 gradle/mvn/flutter/cargo… 归类）。
 *    沙箱的并发上限按**通道**而非按命令内容划分 —— 因为沙箱不知道也管不着
 *    宿主的工作负载语义；调用方要限流应该自己在宿主侧做。保留的唯一策略是
 *    「前台总数上限」+「持久进程上限」，两者都可配置。
 * 3. **不移植 `ForegroundCommandAdmission` 的 Semaphore(1) 内存闸门**。
 *    那台的动机是「已知重型命令共用一个名额」（taixu 要跑 gradle 构建）。
 *    沙箱是通用执行面，改成 [maxForeground] 个并发（默认 4），更符合
 *    AIDL 契约里「同一条前台通道有并发上限」的描述。
 * 4. **不移植 `ShellProcessOwner` / `ExecutionEnvironmentContext` /
 *    `closeRuntimeResources`**（taixu 的运行时资源账本 + 失败重试机制）。
 *    这里换成一个显式的 [ManagedProcess] + [stopAll] 幂等清理，语义更直白。
 * 5. **不移植 `ProcessLogStore` 的 60s 定期 prune 协程**（见 1）。
 * 6. **新增 `ProcessRegistry` 的「代际」校验**（上游用 `processes[id] !== target`
 *    做同款检查）。这里显式保留该写法并注释原因：同一个 id 可能被复用，
 *    旧代际的清理绝不能把新代际的进程一起收掉。
 * 7. **`forkTid` / `childOfThread` 逻辑保留**（上游用来精确定位本次 fork 的
 *    子进程）；但沙箱的 PTY 路径能直接拿到 pid，所以它只用于管道路径。
 *
 * ============================================================================
 * 并发纪律
 * ============================================================================
 * - 所有对 [processes] 的增删都在 [mutex] 下，**但** `release()` 在锁内执行
 *   时会调用 `close()`（可能耗时 500ms+）。这是刻意的：期间不允许新的 start
 *   插进来，否则「同名 id 的旧代际还在清理，新代际已经开始」会互相破坏。
 * - `stopAll()` 用 NonCancellable：清理不能被取消信号打断，否则会漏进程。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** 执行类别 —— 决定并发策略。 */
enum class ExecutionKind {
    /** 一次性有界命令：受 [ProcessRegistry.maxForeground] 约束，超限立即拒绝。 */
    FOREGROUND,

    /** 持久进程：不受前台上限约束，但受 [ProcessRegistry.maxPersistent] 约束。 */
    PERSISTENT,
}

/**
 * 一条在册进程。
 *
 * 注意 [id] 是可复用的（调用方指定），所以任何「按 id 找回并操作」的地方
 * 都必须做**代际校验**（见 [ProcessRegistry.stop] 的注释）。
 */
data class ManagedProcess(
    val id: String,
    val kind: ExecutionKind,
    val startedAtMillis: Long,
    /** 子进程 pid；-1 表示拿不到（管道路径在低版本 Android 上可能取不到）。 */
    val pid: Int,
    /** 关闭动作（幂等）。由创建方提供 —— 关 PTY 会话或 destroy Process。 */
    internal val closer: suspend () -> Unit,
    /** 进程是否还活着。 */
    internal val aliveProbe: () -> Boolean,
) {
    /** 是否还活着（非阻塞）。 */
    val isAlive: Boolean get() = aliveProbe()
}

/** 清理失败时抛的异常（聚合多个失败）。 */
class ProcessCleanupException(val failures: List<Throwable>) :
    IllegalStateException("${failures.size} 项进程资源清理失败", failures.firstOrNull()) {
    init {
        failures.drop(1).forEach(::addSuppressed)
    }
}

/**
 * 进程注册表。
 *
 * @param maxForeground 前台有界命令并发上限；超限立即以 CODE_BUSY 拒绝
 * @param maxPersistent 持久进程数量上限
 */
class ProcessRegistry(
    private val maxForeground: Int = DEFAULT_MAX_FOREGROUND,
    private val maxPersistent: Int = DEFAULT_MAX_PERSISTENT,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val eventSink: EventSink = NoOpEventSink,
) {

    private val mutex = Mutex()
    private val processes = ConcurrentHashMap<String, ManagedProcess>()

    /** 单调递增的启动序号（诊断用；也方便判断「谁先起」）。 */
    private val sequence = AtomicLong(0)

    /** 当前前台命令数（给拒绝路径的日志与测试用）。 */
    val foregroundCount: Int
        get() = processes.values.count { it.kind == ExecutionKind.FOREGROUND }

    /** 当前持久进程数。 */
    val persistentCount: Int
        get() = processes.values.count { it.kind == ExecutionKind.PERSISTENT }

    /**
     * 在当前执行上下文里登记一条进程。
     *
     * 用法（由 [SandboxServiceCore] 调用）：
     * ```
     *   registry.runRegistered(id, kind, closer, probe) { ... 真正执行 ... }
     * ```
     *
     * @param id      调用方给的幂等 id；**同名会先停掉旧的**
     * @param kind    [ExecutionKind.FOREGROUND] / [ExecutionKind.PERSISTENT]
     * @param pid     子进程 pid（拿不到就传 -1）
     * @param closer  幂等关闭动作
     * @param probe   非阻塞存活探测
     * @throws SandboxException CODE_BUSY 超过该类别的并发上限
     */
    suspend fun runRegistered(
        id: String,
        kind: ExecutionKind,
        pid: Int,
        closer: suspend () -> Unit,
        probe: () -> Boolean,
        block: suspend (ManagedProcess) -> Unit,
    ) {
        val managed = register(id, kind, pid, closer, probe)
        try {
            block(managed)
        } finally {
            unregister(managed)
        }
    }

    /**
     * 登记一条进程（不含执行块）。调用方负责最终 [unregister]。
     *
     * @throws SandboxException CODE_BUSY 超过上限
     */
    suspend fun register(
        id: String,
        kind: ExecutionKind,
        pid: Int,
        closer: suspend () -> Unit,
        probe: () -> Boolean,
    ): ManagedProcess = mutex.withLock {
        // ★ 代际纪律：同名 id 先停掉旧那条（上游 processRegistry.start 同款行为）。
        processes[id]?.let { existing ->
            releaseLocked(existing)
        }

        currentCoroutineContext().ensureActive()

        // ★ 并发上限：前台/持久分别计数。
        when (kind) {
            ExecutionKind.FOREGROUND -> {
                val active = processes.values.count { it.kind == ExecutionKind.FOREGROUND }
                if (active >= maxForeground) {
                    eventSink.onEvent(
                        EventSink.CATEGORY_EXEC,
                        "前台命令并发超限，拒绝执行",
                        mapOf("id" to id, "active" to active.toString(), "limit" to maxForeground.toString()),
                    )
                    throw SandboxException(
                        SandboxException.CODE_BUSY,
                        "前台命令并发已达上限（$active/$maxForeground）；请等待正在执行的命令结束。",
                    )
                }
            }
            ExecutionKind.PERSISTENT -> {
                val active = processes.values.count { it.kind == ExecutionKind.PERSISTENT }
                if (active >= maxPersistent) {
                    eventSink.onEvent(
                        EventSink.CATEGORY_EXEC,
                        "持久进程数量超限，拒绝启动",
                        mapOf("id" to id, "active" to active.toString(), "limit" to maxPersistent.toString()),
                    )
                    throw SandboxException(
                        SandboxException.CODE_BUSY,
                        "持久进程已达上限（$active/$maxPersistent）；请先停止不需要的进程。",
                    )
                }
            }
        }

        val managed = ManagedProcess(
            id = id,
            kind = kind,
            startedAtMillis = System.currentTimeMillis(),
            pid = pid,
            closer = closer,
            aliveProbe = probe,
        )
        processes[id] = managed
        sequence.incrementAndGet()
        eventSink.onEvent(
            EventSink.CATEGORY_EXEC,
            "进程已登记",
            mapOf("id" to id, "kind" to kind.name, "pid" to pid.toString()),
        )
        managed
    }

    /**
     * 注销并清理一条进程。幂等。
     *
     * 关键点：只有**当前代际**的那条会被清理。若同 id 已被新代际替换，
     * 本方法不会碰新代际（否则「停旧进程」会把刚起的新进程杀掉）。
     */
    suspend fun unregister(managed: ManagedProcess) = withContext(NonCancellable) {
        mutex.withLock {
            val current = processes[managed.id]
            if (current !== managed) {
                // 已被替换或已清理：只关掉自己这份资源，不动注册表。
                runCatching { managed.closer() }
                return@withLock
            }
            releaseLocked(managed)
        }
    }

    /** 按 id 停止。返回是否真的停了一条（没有在册则 false）。 */
    suspend fun stop(id: String): Boolean = withContext(NonCancellable) {
        mutex.withLock {
            val target = processes[id] ?: return@withLock false
            releaseLocked(target)
            true
        }
    }

    /**
     * 停掉所有进程并清空注册表。
     *
     * `NonCancellable`：清理过程绝不能被取消信号打断，否则会漏进程。
     * 有失败时汇总抛 [ProcessCleanupException]，但**仍然继续**清理其余的 ——
     * 一条清理失败不能让其它进程变成孤儿。
     */
    suspend fun stopAll() = withContext(NonCancellable) {
        mutex.withLock {
            val failures = mutableListOf<Throwable>()
            processes.values.toList().forEach { managed ->
                try {
                    releaseLocked(managed)
                } catch (failure: Throwable) {
                    failures += failure
                }
            }
            processes.clear()
            if (failures.isNotEmpty()) throw ProcessCleanupException(failures)
        }
    }

    /** 回收已经死掉但还在册的进程（定期调用或关闭时调用）。返回回收条数。 */
    suspend fun cleanupDead(): Int = withContext(NonCancellable) {
        mutex.withLock {
            val dead = processes.values.filterNot { it.aliveProbe() }
            var count = 0
            dead.forEach { managed ->
                runCatching { releaseLocked(managed) }
                count++
            }
            count
        }
    }

    /** 当前在册进程快照（按启动时间升序）。 */
    fun list(): List<ManagedProcess> = processes.values.sortedBy { it.startedAtMillis }

    /**
     * 释放一条进程 —— **调用方必须持有 [mutex]**。
     *
     * 清理失败时不从注册表删除：保留记录让调用方可以重试，否则就真的丢了句柄。
     */
    private suspend fun releaseLocked(managed: ManagedProcess) {
        var failure: Throwable? = null
        try {
            managed.closer()
        } catch (thrown: Throwable) {
            failure = thrown
        }
        if (failure == null) {
            processes.remove(managed.id, managed)
            eventSink.onEvent(
                EventSink.CATEGORY_EXEC,
                "进程已注销",
                mapOf("id" to managed.id, "kind" to managed.kind.name),
            )
        } else {
            eventSink.onEvent(
                EventSink.CATEGORY_EXEC,
                "进程清理失败（保留登记以便重试）",
                mapOf("id" to managed.id, "error" to (failure.message ?: "unknown")),
            )
            throw failure
        }
    }

    companion object {
        /** 前台并发默认上限。4 是因为主流手机 4 个 gradle/node 进程就开始抖。 */
        const val DEFAULT_MAX_FOREGROUND = 4

        /** 持久进程默认上限。 */
        const val DEFAULT_MAX_PERSISTENT = 8
    }
}

// ============================================================================
// 进程树回收
// ============================================================================

/**
 * 进程树回收器。
 *
 * 场景：PRoot 卡在 tracee 等待上，SIGKILL 之后它的 tracee（`bash -l` 的子进程、
 * gradle 后代）会被 reparent 到 init 永久存活；`Process.destroyForcibly()`
 * 只作用于直接子进程，App 侧再无手段回收，孤儿进程会累积。
 *
 * 做法：读 /proc 建 pid→ppid 映射，从根 pid 递归收集后代，逐个 SIGKILL。
 * 全部走 `/proc` 与同 uid 的 `Process.killProcess`，不依赖 native。
 */
object ProcessTreeReaper {

    /**
     * 记录当前线程 tid —— 必须在 fork 子进程**之前**取样。
     *
     * 为什么：`/proc` 以**线程**粒度记录 children（`/proc/self/task/<tid>/children`），
     * 只有拿到 fork 那一刻的 tid 才能精确定位本次 fork 的子进程。
     * 取样与 fork 之间不得有挂起点，否则线程被调度走之后解析出的 pid 就错了。
     *
     * @return tid；非 Linux / 权限受限时返回 null
     */
    fun forkTid(): Int? = runCatching {
        android.os.Process.myTid()
    }.getOrNull()?.takeIf { it > 0 }

    /** 定位 [tid] 线程 fork 出的**直接子进程** pid；取不到返回 null。 */
    fun childOfThread(tid: Int): Int? = runCatching {
        // children 按创建顺序排列，取最后一个即本次 fork 的子进程。
        File("/proc/self/task/$tid/children").readText()
            .trim()
            .split(' ')
            .lastOrNull { it.isNotBlank() }
            ?.toInt()
    }.getOrNull()

    /**
     * 递归收掉 [rootPid] 的全部后代，最后 SIGKILL 根本身。
     *
     * @return 成功杀掉的进程数（拿不到权限的会被跳过，天然保证只收自家进程）
     */
    fun reap(rootPid: Int): Int {
        if (rootPid <= 0) return 0
        return runCatching {
            // 1) 建 pid -> 子进程列表
            val childrenOf = HashMap<Int, MutableList<Int>>()
            readableParentPairs().forEach { (pid, ppid) ->
                childrenOf.getOrPut(ppid) { mutableListOf() } += pid
            }

            // 2) BFS 收集后代
            val doomed = mutableListOf<Int>()
            val pending = ArrayDeque<Int>()
            childrenOf[rootPid]?.let { pending.addAll(it) }
            while (pending.isNotEmpty()) {
                val pid = pending.removeFirst()
                if (pid == rootPid || pid in doomed) continue
                doomed += pid
                childrenOf[pid]?.let { pending.addAll(it) }
            }

            // 3) 先杀后代再杀根（反过来的话后代会被 reparent，ppid 变成 1 就找不到了）
            doomed += rootPid
            doomed.count { killQuietly(it) }
        }.getOrDefault(0)
    }

    /**
     * 可读的 (pid, ppid) 列表。
     *
     * 只取同 uid 能读到的条目；读不到的（别的 uid / 已退出 / 无权限）直接跳过 ——
     * 这既是性能考虑，也是**权限边界**：我们永远看不到也不该看到别人的进程。
     */
    private fun readableParentPairs(): List<Pair<Int, Int>> =
        File("/proc").listFiles().orEmpty().mapNotNull { entry ->
            val pid = entry.name.toIntOrNull() ?: return@mapNotNull null
            val ppid = runCatching {
                File(entry, "status").readLines()
                    .firstOrNull { it.startsWith("PPid:") }
                    ?.substringAfter(':')
                    ?.trim()
                    ?.toIntOrNull()
            }.getOrNull() ?: return@mapNotNull null
            pid to ppid
        }

    /** SIGKILL 一个 pid；非本 uid / 已退出会抛异常被吞掉。 */
    private fun killQuietly(pid: Int): Boolean = runCatching {
        android.os.Process.killProcess(pid)
        true
    }.getOrDefault(false)
}
