package vip.mystery0.xhu.timetable.laundry

import org.json.JSONArray
import org.json.JSONObject
import vip.mystery0.xhu.timetable.model.laundry.*
import vip.mystery0.xhu.timetable.repository.LaundryGateway
import vip.mystery0.xhu.timetable.repository.LaundryOrderSnapshot

/** Android 校园客户端的类型化边界，JSON 与金额协议仍留在原客户端。 */
internal class CampusTypedLaundryGateway(private val client: CampusLaundryGateway) : LaundryGateway {
    override suspend fun initialize() = client.initialize()
    override suspend fun hasSession() = client.hasSession()
    override suspend fun verify() = client.verify()
    override suspend fun lookupDevice(resNo: String) = device(client.lookupDevice(resNo))
    override suspend fun previewOrder(resNo: String, key: String): LaundryQuote = client.previewOrder(resNo, key).let {
        LaundryQuote(it.getString("total"), it.getString("discount"), it.getString("pay"))
    }
    override suspend fun pendingPayment(): LaundryPayment? = client.pendingPayment().takeIf { it.length() > 0 }?.let {
        LaundryPayment(it.optString("device"), it.optString("location"), it.optString("program"),
            LaundryAmounts.yuan(it.getLong("amount")), reference = it.optString("isvOrderId"))
    }
    override suspend fun createConfirmedPayment(amount: String) = client.createConfirmedPayment(amount)
    override suspend fun paymentCheckout() = LaundryUiPolicy.paymentStatus(client.paymentCheckout().getString("status"))
    override suspend fun wechatPaymentUri() = client.wechatPaymentUri()
    override suspend fun acknowledgeTerminalPayment() = client.acknowledgeTerminalPayment()
    override suspend fun runningOrders(useVerified: Boolean): LaundryOrderSnapshot = client.runningOrders(useVerified).let {
        LaundryOrderSnapshot(orders(it.orders), it.observedAt)
    }
    override suspend fun recentOrders() = orders(client.recentOrders())

    private fun device(value: JSONObject): LaundryDevice {
        val programs = value.getJSONArray("programs")
        return LaundryDevice(value.getString("resNo"), value.optString("name", "洗衣机"),
            listOf(value.optString("building"), value.optString("floor")).filter { it.isNotBlank() }.joinToString(" · "),
            value.optString("status"), value.optBoolean("canUse"), (0 until programs.length()).map {
                programs.getJSONObject(it).let { program -> LaundryProgram(program.getString("key"),
                    program.optString("name"), program.optString("details"), program.optString("priceYuan")) }
            })
    }

    private fun orders(value: JSONArray): List<LaundryOrder> = (0 until value.length()).map {
        value.getJSONObject(it).let { row -> LaundryOrder(row.optString("name", "洗衣机"),
            row.optString("program"), row.optString("location").trim(), row.optString("status"),
            row.optBoolean("running"), row.optLong("seconds", -1).takeIf { seconds -> seconds >= 0 },
            row.optString("reference"), row.optBoolean("completed"), row.optBoolean("waitingForDevice")) }
    }
}
