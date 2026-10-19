package dev.heracles.core.progress

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `TaskProgress` 的门禁 —— 只钉**一条规则**：进度是旁路，它出错不许影响任务。
 *
 * 这条规则在真机上有具体含义：`实测-12` §13 的自检里，前台服务因为权限/厂商 ROM
 * 起不来时，**构建本身仍必须能跑完**（通知栏是"看得见进度"，不是"能不能构建"）。
 * 所以 `*Quietly` 吞异常是刻意的取舍，不是偷懒 —— 这里把它钉死，
 * 免得后来者"顺手"改成抛异常。
 */
class TaskProgressTest {

    @Test
    @DisplayName("NONE：调它永远安全，什么都不做")
    fun noneIsNoop() {
        TaskProgress.NONE.startQuietly("任务")
        TaskProgress.NONE.stepQuietly("一步")
        TaskProgress.NONE.finishQuietly(true, "完成")
    }

    @Test
    @DisplayName("★ 实现抛异常时 *Quietly 不抛（否则通知栏出错会拖垮构建）")
    fun quietVariantsSwallowExceptions() {
        val boom = object : TaskProgress {
            override fun start(task: String): Unit = throw IllegalStateException("start 炸了")
            override fun step(text: String): Unit = throw IllegalStateException("step 炸了")
            override fun finish(ok: Boolean, summary: String): Unit = throw IllegalStateException("finish 炸了")
        }

        // 三条都不该抛 —— 抛了就是本用例失败
        boom.startQuietly("任务")
        boom.stepQuietly("一步")
        boom.finishQuietly(false, "失败")
    }

    @Test
    @DisplayName("参数原样透传（截断/换行处理是上层的事，这里不许偷偷改写）")
    fun passesValuesThrough() {
        val seen = mutableListOf<String>()
        val p = object : TaskProgress {
            override fun start(task: String) {
                seen.add("start:$task")
            }

            override fun step(text: String) {
                seen.add("step:$text")
            }

            override fun finish(ok: Boolean, summary: String) {
                seen.add("finish:$ok:$summary")
            }
        }

        p.startQuietly("正在构建 APK")
        p.stepQuietly("✓ prepare")
        p.finishQuietly(true, "ok")

        assertEquals(listOf("start:正在构建 APK", "step:✓ prepare", "finish:true:ok"), seen)
        assertTrue(seen.size == 3)
    }
}
