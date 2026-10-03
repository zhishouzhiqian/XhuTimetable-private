package vip.mystery0.xhu.timetable.laundry

import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import kotlinx.serialization.decodeFromString
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSProcessInfo
import vip.mystery0.xhu.timetable.model.laundry.*
import vip.mystery0.xhu.timetable.repository.LaundryOrderSnapshot
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** 只传递固定操作与类型化结果；签名、设备标识和校园会话留在原生客户端。 */
interface IosCampusBackend {
    fun perform(action: String, payload: String, requestId: Long)
}

/** 主线程维护回调归属，取消后丢弃晚到结果，不让旧页面覆盖新查询。 */
object IosCampusClientBridge {
    private var backend: IosCampusBackend? = null
    private var sequence = 0L
    private val pending = mutableMapOf<Long, CancellableContinuation<String>>()
    private val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutex = Mutex()

    fun install(backend: IosCampusBackend) {
        check(this.backend == null) { "校园原生客户端只能安装一次" }
        this.backend = backend
        IosLaundryRuntime.installClient(IosCampusLaundryClient())
    }

    fun complete(requestId: Long, result: String?, error: String?) {
        val continuation = pending.remove(requestId) ?: return
        if (!continuation.isActive) return
        when {
            error != null -> continuation.resumeWithException(
                if (error.startsWith("CAMPUS_INIT_FAILED\n") && error.length <= 16384)
                    LaundryInitializationException(error.substringAfter('\n').trim())
                else if (error.startsWith("CAMPUS_PAYMENT_FAILED\n") && error.length <= 16384)
                    LaundryPaymentException(error.substringAfter('\n').trim())
                else IllegalStateException(error)
            )
            result != null && result.length <= 262144 -> continuation.resume(result)
            else -> continuation.resumeWithException(IllegalStateException("洗衣响应未通过校验。"))
        }
    }

    internal suspend fun request(action: String, payload: String = "{}"): String = mutex.withLock {
        withContext(Dispatchers.Main.immediate) {
            val native = checkNotNull(backend) { "校园客户端未安装" }
            suspendCancellableCoroutine { continuation ->
                val id = ++sequence
                pending[id] = continuation
                continuation.invokeOnCancellation { cleanup.launch { pending.remove(id) } }
                try { native.perform(action, payload, id) }
                catch (_: Exception) { complete(id, null, "暂时无法执行洗衣查询。") }
            }
        }
    }
}

@Serializable private data class QuoteResult(val total: String, val discount: String, val pay: String,
    val program: String, val device: String, val location: String)
@Serializable private data class PaymentResult(val device: String, val location: String, val program: String,
    val amount: String, val reference: String)
@Serializable private data class CheckoutResult(val status: String)
@Serializable private data class WechatResult(val uri: String)
@Serializable private data class SessionResult(val present: Boolean)
@Serializable private data class AuthorizationResult(val url: String)
@Serializable private data class DeviceResult(val resNo: String, val name: String, val location: String,
    val status: String, val canUse: Boolean, val programs: List<ProgramResult>)
@Serializable private data class ProgramResult(val key: String, val name: String, val details: String, val price: String)
@Serializable private data class SnapshotResult(val orders: List<OrderResult>, val observedAt: Long)
@Serializable private data class OrderResult(val name: String, val program: String, val location: String,
    val status: String, val running: Boolean, val seconds: Long? = null, val reference: String,
    val completed: Boolean, val waitingForDevice: Boolean) {
    fun model() = LaundryOrder(name, program, location, status, running, seconds, reference, completed, waitingForDevice)
}

/** 原配载体客户端：与安卓共用报价、付款、微信返回核验和订单页面。 */
private class IosCampusLaundryClient : IosLaundryLoginGateway {
    private val json = Json
    override val supportsPayment = true
    private fun payload(key: String, value: String) = buildJsonObject { put(key, value) }.toString()
    override suspend fun initialize() { IosCampusClientBridge.request("initialize") }
    override suspend fun hasSession() = json.decodeFromString<SessionResult>(IosCampusClientBridge.request("hasSession")).present
    override suspend fun verify() { IosCampusClientBridge.request("verify") }
    override suspend fun authorizationUrl(forceLogin: Boolean): String {
        if (forceLogin) IosCampusClientBridge.request("logout")
        return json.decodeFromString<AuthorizationResult>(IosCampusClientBridge.request("authorizationUrl")).url
    }
    override suspend fun exchangeAuthorization(code: String) { IosCampusClientBridge.request("exchange", payload("code", code)) }
    override suspend fun lookupDevice(resNo: String): LaundryDevice {
        require(resNo.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "机器编号无效。" }
        val device = json.decodeFromString<DeviceResult>(IosCampusClientBridge.request("device", payload("resNo", resNo)))
        check(device.resNo == resNo && device.programs.size <= 100) { "设备返回值不一致。" }
        return LaundryDevice(device.resNo, device.name, device.location, device.status, device.canUse,
            device.programs.map { LaundryProgram(it.key, it.name, it.details, it.price) })
    }
    @OptIn(ExperimentalForeignApi::class)
    override suspend fun runningOrders(useVerified: Boolean): LaundryOrderSnapshot {
        val snapshot = json.decodeFromString<SnapshotResult>(IosCampusClientBridge.request("running"))
        val now = (NSProcessInfo.processInfo.systemUptime * 1000).toLong()
        check(snapshot.orders.size <= 20 && snapshot.observedAt in 1..now) { "订单采样时间无效。" }
        return LaundryOrderSnapshot(snapshot.orders.map { it.model() }, snapshot.observedAt)
    }
    override suspend fun recentOrders(): List<LaundryOrder> {
        val rows = json.decodeFromString<List<OrderResult>>(IosCampusClientBridge.request("history"))
        check(rows.size <= 10)
        return rows.map { it.model() }
    }
    override suspend fun pendingPayment(): LaundryPayment? {
        val raw = IosCampusClientBridge.request("pendingPayment")
        if (json.parseToJsonElement(raw).jsonObject.isEmpty()) return null
        val pending = json.decodeFromString<PaymentResult>(raw)
        return LaundryPayment(pending.device, pending.location, pending.program, pending.amount, reference = pending.reference)
    }
    override suspend fun previewOrder(resNo: String, key: String): LaundryQuote {
        val input = buildJsonObject { put("resNo", resNo); put("key", key) }.toString()
        val quote = json.decodeFromString<QuoteResult>(IosCampusClientBridge.request("preview", input))
        return LaundryQuote(quote.total, quote.discount, quote.pay)
    }
    override suspend fun createConfirmedPayment(amount: String) {
        IosCampusClientBridge.request("createPayment", payload("amount", amount))
    }
    override suspend fun paymentCheckout(): LaundryPaymentStatus =
        LaundryUiPolicy.paymentStatus(json.decodeFromString<CheckoutResult>(IosCampusClientBridge.request("paymentCheckout")).status)
    override suspend fun wechatPaymentUri(): String {
        val uri = json.decodeFromString<WechatResult>(IosCampusClientBridge.request("wechatPayment")).uri
        check(LaundryAuthorizationPolicy.acceptsWechat(uri)) { "WECHAT_CHANNEL_UNAVAILABLE" }
        return uri
    }
    override suspend fun acknowledgeTerminalPayment() { IosCampusClientBridge.request("acknowledgePayment") }
}
