package vip.mystery0.xhu.timetable.laundry

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher

/** 生命周期属于独立进程；所有 SDK 调用固定在同一线程。 */
internal object CampusLaundryRuntime {
    val dispatcher by lazy { Executors.newSingleThreadExecutor { task -> Thread(task, "campus-client") }.asCoroutineDispatcher() }
    private var sharedClient: CampusClient? = null
    @Synchronized fun client(context: Context): CampusClient = sharedClient
        ?: CampusClient(context.applicationContext).also { sharedClient = it }
}

/** 用于隔离界面状态测试；真实请求全部委托给已验证的 CampusClient。 */
internal interface CampusLaundryGateway {
    fun initialize()
    fun hasSession(): Boolean
    fun verify()
    fun lookupDevice(resNo: String): JSONObject
    fun previewOrder(resNo: String, key: String): JSONObject
    fun pendingPayment(): JSONObject
    fun createConfirmedPayment(amount: String)
    fun paymentCheckout(): JSONObject
    fun wechatPaymentUri(): String
    fun acknowledgeTerminalPayment()
    fun runningOrders(useVerified: Boolean = false): CampusOrderSnapshot
    fun recentOrders(): JSONArray
}

internal class CampusLaundryClientGateway(context: Context) : CampusLaundryGateway {
    private val client = CampusLaundryRuntime.client(context)
    override fun initialize() = client.initialize()
    override fun hasSession() = client.hasSession()
    override fun verify() { client.verifyForEntry() }
    override fun lookupDevice(resNo: String) = client.lookupDevice(resNo)
    override fun previewOrder(resNo: String, key: String) = client.previewOrder(resNo, key)
    override fun pendingPayment() = client.pendingPayment()
    override fun createConfirmedPayment(amount: String) { client.createConfirmedPayment(amount) }
    override fun paymentCheckout() = client.paymentCheckout()
    override fun wechatPaymentUri() = client.wechatPaymentUri()
    override fun acknowledgeTerminalPayment() = client.acknowledgeTerminalPayment()
    override fun runningOrders(useVerified: Boolean) = client.runningOrderSnapshot(useVerified)
    override fun recentOrders() = client.recentOrders()
}
