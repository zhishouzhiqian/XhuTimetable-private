package vip.mystery0.xhu.timetable.repository

import vip.mystery0.xhu.timetable.model.laundry.*

/**
 * 平台负责协议、签名与安全存储；共享业务层只接收已核验的类型化结果。
 * 创建前须持久化账号绑定的意图；已有意图时拒绝创建，结果不明时不能自动重试。
 * acknowledgeTerminalPayment 须实时核验服务端终态，微信返回和本地计时不是终态证据。
 */
interface LaundryGateway {
    suspend fun initialize()
    suspend fun hasSession(): Boolean
    suspend fun verify()
    suspend fun lookupDevice(resNo: String): LaundryDevice
    suspend fun previewOrder(resNo: String, key: String): LaundryQuote
    suspend fun pendingPayment(): LaundryPayment?
    suspend fun createConfirmedPayment(amount: String)
    suspend fun paymentCheckout(): LaundryPaymentStatus
    suspend fun wechatPaymentUri(): String
    suspend fun acknowledgeTerminalPayment()
    suspend fun runningOrders(useVerified: Boolean = false): LaundryOrderSnapshot
    suspend fun recentOrders(): List<LaundryOrder>
}

/** observedAt 必须使用宿主传给 ViewModel 的同一单调时钟。 */
data class LaundryOrderSnapshot(val orders: List<LaundryOrder>, val observedAt: Long)
