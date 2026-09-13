package vip.mystery0.xhu.timetable.widget

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WidgetSnapshotTest {
    @Test
    fun invalidationSurvivesCoalescingAndInactiveSubscribers() {
        val before = WidgetRefreshSignal.changes.value.revision
        // 没有观察者时的账号变更也必须保留，后续普通刷新不能覆盖其失效标记。
        WidgetRefreshSignal.request(invalidate = true)
        val invalidation = WidgetRefreshSignal.changes.value
        WidgetRefreshSignal.request()
        val merged = WidgetRefreshSignal.changes.value
        assertTrue(invalidation.invalidatedAt > before)
        assertEquals(invalidation.invalidatedAt, merged.invalidatedAt)
        assertTrue(merged.revision > invalidation.revision)
    }

    @Test
    fun snapshotBoundaryChecksAndSwiftFixture() {
        val json = WidgetSnapshotChecks.runChecks()
        // CI 用同一份 Kotlin 输出检查 Swift 解码，避免两端各自构造数据掩盖协议差异。
        val fixture = File("build/widget-tests/snapshot.json")
        requireNotNull(fixture.parentFile).mkdirs()
        fixture.writeText(json)
    }
}
