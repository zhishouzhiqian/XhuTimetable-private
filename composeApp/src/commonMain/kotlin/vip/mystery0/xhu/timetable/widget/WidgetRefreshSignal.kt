package vip.mystery0.xhu.timetable.widget

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** 合并连续写入，并让正在生成的旧账号快照失效；没有订阅者时无需启动工作。 */
object WidgetRefreshSignal {
    data class Request(val revision: Long = 0, val invalidatedAt: Long = 0)

    private val revision = MutableStateFlow(Request())
    val changes = revision.asStateFlow()

    fun request(invalidate: Boolean = false) {
        revision.update {
            val next = it.revision + 1
            Request(next, if (invalidate) next else it.invalidatedAt)
        }
    }
}
