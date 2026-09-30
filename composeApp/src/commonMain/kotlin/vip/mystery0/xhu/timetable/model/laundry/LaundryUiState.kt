package vip.mystery0.xhu.timetable.model.laundry

enum class LaundryPage { Loading, Home, Programs, Payment, Orders }
enum class LaundryPaymentStatus { Unknown, Unpaid, Paying, Success, Closed }

enum class LaundryCommandType { Login, Scan, Wechat }
data class LaundryCommand(val type: LaundryCommandType, val uri: String = "")

data class LaundryProgram(val key: String, val name: String, val details: String, val price: String)
data class LaundryDevice(
    val resNo: String,
    val name: String,
    val location: String,
    val status: String,
    val canUse: Boolean,
    val programs: List<LaundryProgram>,
)
data class LaundryQuote(val total: String, val discount: String, val pay: String)
data class LaundryOrder(
    val name: String,
    val program: String,
    val location: String = "",
    val status: String,
    val running: Boolean = false,
    val seconds: Long? = null,
    val reference: String = "",
    val completed: Boolean = false,
    val waitingForDevice: Boolean = false,
)
data class LaundryPayment(
    val device: String,
    val location: String,
    val program: String,
    val amount: String,
    val status: LaundryPaymentStatus = LaundryPaymentStatus.Unknown,
    val reference: String = "",
    val accountMismatch: Boolean = false,
)
data class LaundryUiState(
    val page: LaundryPage = LaundryPage.Loading,
    val busy: Boolean = false,
    val ordersLoading: Boolean = false,
    val quoteLoading: Boolean = false,
    val device: LaundryDevice? = null,
    val selectedProgram: String = "",
    val quote: LaundryQuote? = null,
    val orders: List<LaundryOrder> = emptyList(),
    val history: List<LaundryOrder> = emptyList(),
    val payment: LaundryPayment? = null,
    val acknowledgedPaidOrder: LaundryPayment? = null,
    val stale: Boolean = false,
    val error: String? = null,
)

/** 页面判断只依赖已核验的数据，不根据本地计时或微信返回推断付款。 */
object LaundryUiPolicy {
    fun paymentStatus(status: String): LaundryPaymentStatus = when (status) {
        "SUCCESS" -> LaundryPaymentStatus.Success
        "CLOSE" -> LaundryPaymentStatus.Closed
        "INIT" -> LaundryPaymentStatus.Unpaid
        "PAYING" -> LaundryPaymentStatus.Paying
        else -> LaundryPaymentStatus.Unknown
    }

    fun remaining(seconds: Long?, elapsedSeconds: Long): Long? =
        seconds?.let { (it - elapsedSeconds.coerceAtLeast(0)).coerceAtLeast(0) }

    fun defaultProgram(programs: List<LaundryProgram>): String =
        (programs.firstOrNull { it.name == "标准洗" } ?: programs.firstOrNull())?.key.orEmpty()
}

/** 一次性扫码意图和报价版本独立于界面重组，避免重复启动与旧报价覆盖。 */
class LaundryInteractionGuard(autoScan: Boolean) {
    private var autoScanPending = autoScan
    @kotlin.concurrent.Volatile private var quoteVersion = 0L
    private var submitting = false

    fun takeAutoScan(hasPendingPayment: Boolean): Boolean {
        val scan = autoScanPending && !hasPendingPayment
        autoScanPending = false
        return scan
    }
    fun nextQuote(): Long = ++quoteVersion
    fun isCurrentQuote(version: Long): Boolean = quoteVersion == version
    fun beginSubmission(): Boolean {
        if (submitting) return false
        submitting = true
        return true
    }
    fun endSubmission() { submitting = false }
}
