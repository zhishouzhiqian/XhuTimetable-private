package vip.mystery0.xhu.timetable.model

import androidx.compose.runtime.Immutable
import kotlinx.datetime.LocalDate
import kotlinx.serialization.Serializable
import vip.mystery0.xhu.timetable.config.datetime.XhuLocalDate
import kotlin.math.abs

@Serializable
@Immutable
data class TermStartChangeAlert(
    val oldServerDate: XhuLocalDate,
    val newServerDate: XhuLocalDate,
    val customDate: XhuLocalDate,
) {
    /** 云端新旧日期相差天数（正数表示推迟，负数表示提前） */
    val serverDiffDays: Long
        get() = newServerDate.toEpochDays() - oldServerDate.toEpochDays()

    /** 当前自定义日期相比新云端日期的偏差天数（正数表示比云端推迟，负数表示比云端提前） */
    val customDiffDays: Long
        get() = customDate.toEpochDays() - newServerDate.toEpochDays()

    /** 描述云端日期的变动幅度，如：推迟 7 天（1 周）、提前 3 天 等 */
    val serverChangeDescription: String
        get() = formatDaysDiff(serverDiffDays)

    /** 描述自定义日期与新云端日期的偏差，如：比新云端推迟 7 天（1 周）、与新云端一致 等 */
    val customDiffDescription: String
        get() = when {
            customDiffDays == 0L -> "与新云端日期一致"
            customDiffDays > 0L -> "比新云端推迟 ${formatDaysDiff(customDiffDays, withDirection = false)}"
            else -> "比新云端提前 ${formatDaysDiff(-customDiffDays, withDirection = false)}"
        }

    companion object {
        fun formatDaysDiff(days: Long, withDirection: Boolean = true): String {
            if (days == 0L) return "无变化"
            val absDays = abs(days)
            val weeks = absDays / 7
            val remDays = absDays % 7
            val durationDesc = buildString {
                if (weeks > 0L && remDays > 0L) {
                    append("${absDays}天（${weeks}周${remDays}天）")
                } else if (weeks > 0L) {
                    append("${absDays}天（${weeks}周）")
                } else {
                    append("${absDays}天")
                }
            }
            return if (withDirection) {
                if (days > 0L) "推迟 $durationDesc" else "提前 $durationDesc"
            } else {
                durationDesc
            }
        }
    }
}

object TermStartChangeDetector {
    /**
     * 检测云端开学日期是否发生变更，且需要向用户提示。
     *
     * 规则：
     * 1. 没有旧的持久化云端值（oldServerDate == null）时不判为变更。
     * 2. 云端值未变（oldServerDate == newServerDate）不做额外逻辑。
     * 3. 只有云端值发生变更（oldServerDate != null && oldServerDate != newServerDate），
     *    且当前存在自定义开学日期（customStartDate != null）时才触发提醒。
     * 4. 自定义日期恰好等于新的云端日期也遵循上述触发条件，不额外豁免。
     * 5. 如果已经存在尚未被用户决策的 pendingAlert：
     *    - 若最新云端日期撤回恢复为原始旧云端日期（newServerDate == pendingAlert.oldServerDate），变更消除，返回 null；
     *    - 若服务端再次返回新日期，更新 newServerDate 为最新云端日期，保留该提醒；
     *    - 若服务端返回相同日期或未变，仍保留 pendingAlert，避免因提前保存而丢失提醒。
     */
    fun detect(
        oldServerDate: LocalDate?,
        newServerDate: LocalDate,
        customStartDate: LocalDate?,
        pendingAlert: TermStartChangeAlert? = null,
    ): TermStartChangeAlert? {
        if (customStartDate == null) {
            return null
        }
        if (pendingAlert != null) {
            if (newServerDate == pendingAlert.oldServerDate) {
                // 云端变更撤回回到旧值，无需再提醒
                return null
            }
            return pendingAlert.copy(
                newServerDate = newServerDate,
                customDate = customStartDate,
            )
        }
        if (oldServerDate == null || oldServerDate == newServerDate) {
            return null
        }
        return TermStartChangeAlert(
            oldServerDate = oldServerDate,
            newServerDate = newServerDate,
            customDate = customStartDate,
        )
    }
}
