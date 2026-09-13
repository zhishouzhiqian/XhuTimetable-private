package vip.mystery0.xhu.timetable.widget

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 仅包含显示信息，不允许在共享文件中加入账号、密码或凭据。 */
@Serializable
data class WidgetSnapshot(
    val version: Int = 1,
    val generatedAtMillis: Long,
    val validUntilMillis: Long,
    val state: String,
    val days: List<WidgetSnapshotDay> = emptyList(),
) {
    fun encode(): String = json.encodeToString(this)

    companion object {
        private val json = Json { encodeDefaults = true }

        fun empty(state: String, nowMillis: Long): WidgetSnapshot =
            WidgetSnapshot(
                generatedAtMillis = nowMillis,
                validUntilMillis = nowMillis,
                state = state,
            )
    }
}

@Serializable
data class WidgetSnapshotDay(
    val date: String,
    val week: Int,
    val items: List<WidgetSnapshotItem>,
)

@Serializable
data class WidgetSnapshotItem(
    val title: String,
    val location: String,
    val startMillis: Long,
    val endMillis: Long,
    val startPeriod: Int,
    val endPeriod: Int,
    val colorArgb: Long,
    val timeText: String,
    val kind: String,
)
