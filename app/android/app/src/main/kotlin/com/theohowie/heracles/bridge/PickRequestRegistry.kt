package com.theohowie.heracles.bridge

/**
 * **「选目录请求」的进程级登记表**（2026-11-02 · T0 SAF 黑屏修复）。
 *
 * ## 为什么必须活在进程级，而不是 Activity 实例上
 *
 * 用户报的现象：侧边栏点「选择文件夹」→ 系统 SAF 选择器 → 选好返回 ⇒ **黑屏**。
 *
 * `ACTION_OPEN_DOCUMENT_TREE` 把本 App 推到后台期间，Activity 可能被系统回收重建
 * （低内存、开发者选项「不保留活动」、部分 ROM 的激进回收）。旧实现把"结果回调"
 * 存成 `FolderPickerBridge` 的**实例字段**：
 *
 * ```
 * 选目录前：  activityA.folderPicker.pendingResult = { … }   // A 实例
 * 重建后：    activityB.folderPicker.pendingResult = null     // B 实例，全新
 * 结果回来：  onActivityResult 落在 B ⇒ 没有收件人 ⇒ 结果被静默丢弃
 * ```
 *
 * 于是 Dart 侧那个 `await` 永远等不到回包 —— 用户看到的就是黑屏/无响应。
 * `CameraBridge`（2026-10-29 拍照结果丢失）踩过一模一样的坑。
 *
 * ⇒ 状态挪到**进程级单例**（[instance]），Activity 重建前后共享同一份。
 *
 * ## 为什么要两份状态（pending / completed）
 *
 * | 状态 | 含义 | 谁用 |
 * |---|---|---|
 * | [Pending] | 这次请求**还没出结果**，`sink` 是把结果交回 Dart 的出口 | `onActivityResult` |
 * | [Completed] | 结果**已产出**（含工作区登记），但可能没送达 Dart | Dart 超时后的 `consumeCompleted` |
 *
 * 第二份不是冗余：Activity 重建后旧引擎已销毁，`sink` 里捕获的
 * `MethodChannel.Result` 打到的是一个**已经死掉的通道**。只留 pending 的话，
 * "其实选成功了"会被报成失败，用户白选一次。
 *
 * ## 线程
 *
 * 全部走 **[synchronized]**：`onActivityResult` / 通道回调都在主线程，但
 * "取消"来自 `MainActivity` 的另一个分支、`consumeCompleted` 来自通道线程池，
 * 不加锁会出现"取走两次"或"刚存就被覆盖"的竞态。
 *
 * ## 纯 Kotlin（无 Android 依赖）
 *
 * 刻意不碰 `Activity` / `Intent`：这样它能被 **JVM 单测**直接构造
 * （`app/src/test/.../PickRequestRegistryTest.kt`），签名里也不出现 Android 类型。
 */
class PickRequestRegistry(
    /** 时钟注入 —— 单测里把 TTL 测到"刚好过期"而不用真等 5 分钟。 */
    private val clock: () -> Long = System::currentTimeMillis,
) {

    /** 一次**未完成**的请求：[requestId] 用于配对，[sink] 是交回 Dart 的出口。 */
    class Pending(
        val requestId: String,
        val sink: (Map<String, Any?>?) -> Unit,
    )

    /** 一次**已产出**的结果（可能没送达）。 */
    class Completed(
        val requestId: String,
        val payload: Map<String, Any?>?,
        val at: Long,
    )

    private var pending: Pending? = null
    private var completed: Completed? = null

    /**
     * 登记一次新请求。
     *
     * ★ 同时**作废**上一次没被取走的结果 —— 否则本次超时回收会拿到
     * 上一次选的目录（比"没有结果"更糟：用户会看到工作区莫名其妙被换掉）。
     */
    @Synchronized
    fun begin(requestId: String, sink: (Map<String, Any?>?) -> Unit) {
        pending = Pending(requestId, sink)
        completed = null
    }

    /** 当前未完成请求的 requestId（诊断用；无 pending = null）。 */
    @Synchronized
    fun pendingRequestId(): String? = pending?.requestId

    /** 是否有请求在飞 —— 「首帧看门狗」靠它避免在结果交付途中重建 Activity。 */
    @Synchronized
    fun hasPending(): Boolean = pending != null

    /**
     * 取走交付出口（取走即清空 ⇒ 同一次请求绝不会被交付两遍）。
     *
     * @return `null` = 没有收件人（Activity 重建后 Dart 已放弃 / 进程重启过）
     */
    @Synchronized
    fun takeSink(): ((Map<String, Any?>?) -> Unit)? {
        val p = pending ?: return null
        pending = null
        return p.sink
    }

    /** 放弃当前请求（例如 `startActivityForResult` 直接抛了）。 */
    @Synchronized
    fun clearPending() {
        pending = null
    }

    /** 记录"这次请求已经有结果了"，供 Dart 超时后取回。 */
    @Synchronized
    fun recordCompleted(requestId: String, payload: Map<String, Any?>?) {
        completed = Completed(requestId, payload, clock())
    }

    /**
     * 取回并作废某个 requestId 的结果。
     *
     * @return 该请求已产出的结果；无 / 过期 / requestId 不匹配 ⇒ `null`
     */
    @Synchronized
    fun consumeCompleted(requestId: String): Map<String, Any?>? {
        val c = completed ?: return null
        // ★ 先校验、**后**清空（2026-11-02 单测抓到的真缺陷）：
        //   原来的写法是 `completed = null` 打头，于是"requestId 不匹配"的那次
        //   调用会先把**有效结果吃掉**再返回 null —— 用户明明选成功了，Dart 超时
        //   来取时却什么都没有，只好报"选择结果已丢失"。
        //   不匹配就是"不是给我的"，那就别动它。
        if (requestId.isNotBlank() && c.requestId != requestId) return null
        completed = null
        if (clock() - c.at > COMPLETED_TTL_MS) return null
        return c.payload
    }

    /** 清空全部状态（仅测试与"用户主动放弃"用）。 */
    @Synchronized
    fun reset() {
        pending = null
        completed = null
    }

    companion object {
        /** 已完成结果最多保留多久 —— 过期即作废，防陈旧结果串到下一次选择。 */
        const val COMPLETED_TTL_MS = 5 * 60 * 1000L

        /**
         * 进程级唯一实例。
         *
         * `@Volatile` 是因为 `MainActivity` 每次重建都会重新 `FolderPickerBridge(this)`，
         * 但**绝不能**重新 `new PickRequestRegistry()`（那等于回到实例字段的老坑）。
         */
        @Volatile
        var instance: PickRequestRegistry = PickRequestRegistry()
    }
}
