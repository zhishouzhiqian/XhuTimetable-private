package vip.mystery0.xhu.timetable.model

import androidx.compose.runtime.Immutable
import kotlinx.datetime.LocalDate

@Immutable
data class TermStartChangeAlert(
    val oldServerDate: LocalDate,
    val newServerDate: LocalDate,
    val customDate: LocalDate,
)

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
     *    若服务端再次返回新日期，更新 newServerDate 为最新云端日期，保留该提醒；
     *    若服务端返回相同日期或未变，仍保留 pendingAlert，避免因提前保存而丢失提醒。
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
