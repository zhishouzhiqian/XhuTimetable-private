package vip.mystery0.xhu.timetable.laundry

import com.russhwolf.settings.ExperimentalSettingsImplementation
import com.russhwolf.settings.KeychainSettings
import vip.mystery0.xhu.timetable.model.laundry.LaundryPaymentStatus

/** iOS 客户端存储边界：会话和付款意图隔离于用水、课表配置，不写入偏好设置。 */
@OptIn(ExperimentalSettingsImplementation::class)
class IosLaundrySecureStore {
    private val sessions = KeychainSettings("vip.mystery0.xhu.timetable.laundry.session")
    private val payments = KeychainSettings("vip.mystery0.xhu.timetable.laundry.payment")

    fun session(): String? = sessions.getStringOrNull("state")
    fun saveSession(value: String) { require(value.isNotBlank()); sessions.putString("state", value) }
    fun clearSession() { sessions.remove("state") }
    fun paymentIntent(): String? = payments.getStringOrNull("intent")
    fun savePaymentIntent(value: String) { require(value.isNotBlank()); payments.putString("intent", value) }
    // 由客户端重新查询 SUCCESS/CLOSE 且用户确认后调用，不能根据微信回调清除。
    fun clearTerminalPaymentIntent(status: LaundryPaymentStatus, userConfirmed: Boolean) {
        require(userConfirmed && status in listOf(LaundryPaymentStatus.Success, LaundryPaymentStatus.Closed))
        payments.remove("intent")
    }
}
