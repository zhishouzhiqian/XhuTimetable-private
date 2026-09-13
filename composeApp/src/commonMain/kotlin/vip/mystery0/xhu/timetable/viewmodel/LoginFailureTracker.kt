package vip.mystery0.xhu.timetable.viewmodel

/**
 * 登录失败与求助状态跟踪器
 * 负责维护单次登录流程的连续失败计数、求助弹窗触发及防重复提醒逻辑
 */
class LoginFailureTracker(
    private val failureThreshold: Int = 3,
) {
    /** 连续失败计数 */
    var failureCount: Int = 0
        private set

    /** 本次登录流程是否已展示/触发过求助提醒 */
    var hasAlertedHelp: Boolean = false
        private set

    /**
     * 记录一次有效失败（认证失败、网络异常等）
     * @return 是否需要触发求助弹窗
     */
    fun recordFailure(): Boolean {
        failureCount++
        if (failureCount >= failureThreshold && !hasAlertedHelp) {
            hasAlertedHelp = true
            return true
        }
        return false
    }

    /**
     * 登录成功后重置计数与提醒状态
     */
    fun recordSuccess() {
        failureCount = 0
        hasAlertedHelp = false
    }

    /**
     * 重置跟踪器状态
     */
    fun reset() {
        failureCount = 0
        hasAlertedHelp = false
    }
}
