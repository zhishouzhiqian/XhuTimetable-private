package vip.mystery0.xhu.timetable.laundry

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import vip.mystery0.xhu.timetable.model.laundry.LaundryOrderSummary
import vip.mystery0.xhu.timetable.model.laundry.LaundryPhase
import vip.mystery0.xhu.timetable.model.laundry.LaundryUiState
import vip.mystery0.xhu.timetable.model.laundry.LaundryWebCommand

class LaundryServiceController {
    val webSessionGateway = LaundryWebSessionGateway()
    private val json = Json { ignoreUnknownKeys = true }
    private val _uiState = MutableStateFlow(LaundryUiState())
    val uiState: StateFlow<LaundryUiState> = _uiState.asStateFlow()

    private val _webCommand = MutableStateFlow<LaundryWebCommand?>(null)
    val webCommand: StateFlow<LaundryWebCommand?> = _webCommand.asStateFlow()

    private var commandId = 0L
    private var initialized = false
    private val endRefreshes = mutableSetOf<Pair<String, Long>>()

    fun initialize() {
        if (initialized) return
        initialized = true
        checkSession()
    }

    fun checkSession(afterLogin: Boolean = false) {
        _uiState.value = _uiState.value.copy(
            phase = LaundryPhase.CheckingSession,
            message = "",
        )
        _webCommand.value = LaundryWebCommand.CheckSession(++commandId, afterLogin)
    }

    fun showLogin() {
        _uiState.value = _uiState.value.copy(
            phase = LaundryPhase.LoggingIn,
            message = "请在官方页面完成登录",
        )
        _webCommand.value = null
    }

    fun refreshOrders() {
        if (_uiState.value.phase == LaundryPhase.NeedsLogin ||
            _uiState.value.phase == LaundryPhase.Expired
        ) return
        if (_webCommand.value is LaundryWebCommand.QueryOrders) return
        val hasOrders = _uiState.value.orders.isNotEmpty()
        _uiState.value = _uiState.value.copy(
            phase = if (hasOrders) LaundryPhase.Running else LaundryPhase.CheckingOrders,
            refreshing = hasOrders,
            message = "",
        )
        _webCommand.value = LaundryWebCommand.QueryOrders(++commandId)
    }

    fun beginScan() {
        if (_uiState.value.phase == LaundryPhase.NeedsLogin) return
        _uiState.value = _uiState.value.copy(phase = LaundryPhase.Scanning, message = "")
    }

    fun cancelScan() {
        restoreOrderPhase()
    }

    fun onQrScanned() {
        // 首轮不持久化、不记录、也不向任何交易接口发送二维码内容。
        _uiState.value = _uiState.value.copy(
            phase = if (_uiState.value.orders.isEmpty()) LaundryPhase.Idle else LaundryPhase.Running,
            message = "二维码已识别，支付启动功能待接入",
        )
    }

    fun refreshAtExpectedEnd(order: LaundryOrderSummary) {
        val end = order.expectedEndAtEpochMillis ?: return
        if (endRefreshes.add(order.orderId to end)) refreshOrders()
    }

    fun onSessionResult(id: Long, loggedIn: Boolean) {
        val afterLogin = (_webCommand.value as? LaundryWebCommand.CheckSession)
            ?.takeIf { it.id == id }?.afterLogin ?: false
        if (!consume(id)) return
        if (loggedIn) {
            refreshOrders()
        } else {
            _uiState.value = _uiState.value.copy(
                phase = LaundryPhase.NeedsLogin,
                orders = emptyList(),
                refreshing = false,
                stale = false,
                message = if (afterLogin) {
                    "登录页面已返回，但天猫校园尚未确认登录。请重新登录；若仍出现此提示，说明官方账号会话未同步到洗衣页面。"
                } else {
                    "请先登录天猫校园"
                },
            )
        }
    }

    fun onOrdersResult(id: Long, payload: String) {
        if (!consume(id)) return
        val orders = runCatching { parseOrders(payload) }.getOrElse {
            onWebErrorInternal("洗衣订单数据格式发生变化", authenticationExpired = false)
            return
        }
        endRefreshes.retainAll(orders.mapNotNull { order ->
            order.expectedEndAtEpochMillis?.let { order.orderId to it }
        }.toSet())
        _uiState.value = LaundryUiState(
            phase = if (orders.isEmpty()) LaundryPhase.Idle else LaundryPhase.Running,
            orders = orders,
        )
    }

    fun onWebError(id: Long, message: String, authenticationExpired: Boolean) {
        if (!consume(id)) return
        onWebErrorInternal(message, authenticationExpired)
    }

    fun onRuntimeUnsupported() {
        _webCommand.value = null
        onWebErrorInternal("系统 WebView 版本过旧，无法安全读取天猫校园状态", false)
    }

    private fun onWebErrorInternal(message: String, authenticationExpired: Boolean) {
        if (authenticationExpired) {
            _uiState.value = LaundryUiState(
                phase = LaundryPhase.Expired,
                message = "天猫校园登录已失效，请重新登录",
            )
            return
        }
        val existing = _uiState.value.orders
        _uiState.value = _uiState.value.copy(
            phase = if (existing.isEmpty()) LaundryPhase.Error else LaundryPhase.Running,
            refreshing = false,
            stale = existing.isNotEmpty(),
            message = message.ifBlank { "暂时无法获取洗衣状态" },
        )
    }

    private fun consume(id: Long): Boolean {
        if (_webCommand.value?.id != id) return false
        _webCommand.value = null
        return true
    }

    private fun restoreOrderPhase() {
        _uiState.value = _uiState.value.copy(
            phase = if (_uiState.value.orders.isEmpty()) LaundryPhase.Idle else LaundryPhase.Running,
        )
    }

    private fun parseOrders(payload: String): List<LaundryOrderSummary> {
        val element = json.parseToJsonElement(payload)
        val array = element as? JsonArray ?: error("洗衣订单响应不是数组")
        return array.mapNotNull { item ->
            val value = item as? JsonObject ?: return@mapNotNull null
            val orderId = value.string("orderId").ifBlank { value.string("bizOrderId") }
            if (orderId.isBlank()) return@mapNotNull null
            val status = value.string("status")
            if (status != "FULFILLING") return@mapNotNull null
            LaundryOrderSummary(
                orderId = orderId,
                isvOrderId = value.string("isvOrderId"),
                deviceId = value.string("deviceId"),
                deviceName = value.string("deviceName").ifBlank { "洗衣机" },
                deviceType = value.string("deviceType"),
                status = status,
                expectedEndAtEpochMillis = value.longOrNull("expectedEndAtEpochMillis"),
            )
        }.distinctBy { it.orderId }
    }
}

private fun JsonObject.string(name: String): String =
    this[name]?.jsonPrimitive?.contentOrNull.orEmpty()

private fun JsonObject.longOrNull(name: String): Long? =
    this[name]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()?.toLong()
