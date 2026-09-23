package vip.mystery0.xhu.timetable.model.laundry

import kotlinx.serialization.Serializable

enum class LaundryPhase {
    CheckingSession,
    NeedsLogin,
    LoggingIn,
    CheckingOrders,
    Idle,
    Scanning,
    Running,
    Expired,
    Error,
}

@Serializable
data class LaundryOrderSummary(
    val orderId: String,
    val isvOrderId: String = "",
    val deviceId: String = "",
    val deviceName: String = "洗衣机",
    val deviceType: String = "",
    val status: String = "FULFILLING",
    val expectedEndAtEpochMillis: Long? = null,
)

data class LaundryUiState(
    val phase: LaundryPhase = LaundryPhase.CheckingSession,
    val orders: List<LaundryOrderSummary> = emptyList(),
    val refreshing: Boolean = false,
    val stale: Boolean = false,
    val message: String = "",
)

sealed interface LaundryWebCommand {
    val id: Long

    data class CheckSession(override val id: Long) : LaundryWebCommand
    data class QueryOrders(override val id: Long) : LaundryWebCommand
}

const val laundryTransactionsEnabled: Boolean = false

internal fun requireLaundryTransactionsEnabled() {
    check(laundryTransactionsEnabled) { "洗衣交易功能在首轮版本中已禁用" }
}

internal fun selectHomepageLaundryOrder(
    orders: List<LaundryOrderSummary>,
): LaundryOrderSummary? = orders.minWithOrNull(
    compareBy<LaundryOrderSummary> { it.expectedEndAtEpochMillis == null }
        .thenBy { it.expectedEndAtEpochMillis ?: Long.MAX_VALUE }
        .thenBy { it.orderId }
)
