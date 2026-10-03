package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import vip.mystery0.xhu.timetable.model.laundry.*
import vip.mystery0.xhu.timetable.repository.LaundryGateway


/** 两端共用串行业务状态；平台客户端负责持久化和至多一次创建规则。 */
open class LaundryViewModel(
    private val client: LaundryGateway,
    autoScan: Boolean,
    externalInFlight: Boolean = false,
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    ioDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val elapsedRealtime: () -> Long,
    private val quotePause: suspend () -> Unit = { delay(150) },
) : ViewModel(scope) {
    private val requestDispatcher = ioDispatcher
    private val mutex = Mutex()
    private val _state = MutableStateFlow(LaundryUiState(paymentAvailable = client.supportsPayment))
    val state: StateFlow<LaundryUiState> = _state
    private val _command = MutableStateFlow<LaundryCommand?>(null)
    val command: StateFlow<LaundryCommand?> = _command
    private val guard = LaundryInteractionGuard(autoScan)
    private var initialized = false
    private var authenticated = false
    private var initialEntry = true
    private var sampledOrders = emptyList<LaundryOrder>()
    private var sampledAt = 0L
    private var ordersFailed = false
    private var pollJob: Job? = null
    private var foreground = false
    private var externalActive = externalInFlight
    private var paymentCheckBusy = false
    private var lastResNo: String? = null
    private var quoteJob: Job? = null
    private var refreshJob: Job? = null
    private var refreshAgain = false
    val autoScanPending: Boolean get() = initialEntry && _command.value?.type != LaundryCommandType.Scan

    init { if (!externalInFlight) enter() }

    fun consumeCommand() { _command.value = null; externalActive = true }

    private suspend fun <T> request(block: suspend () -> T): T = mutex.withLock {
        withContext(requestDispatcher) { block() }
    }

    private fun enter() {
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                request {
                    // 共用客户端仍重读会话；只消费当前账号的一次性登录核验。
                    client.initialize()
                    initialized = true
                    if (!client.hasSession()) throw IllegalStateException("SESSION_EXPIRED")
                    client.verify()
                }
                authenticated = true
                _state.update { it.copy(page = LaundryPage.Home) }
                checkPayment()
                if (initialEntry && authenticated) {
                    initialEntry = false
                    val shouldScan = guard.takeAutoScan(_state.value.payment != null)
                    if (shouldScan) _command.value = LaundryCommand(LaundryCommandType.Scan)
                }
                if (authenticated) refreshOrders(useVerified = true)
            } catch (error: Exception) {
                handle(error)
            } finally {
                _state.update { it.copy(busy = false) }
            }
        }
    }

    fun loginReturned(success: Boolean) {
        externalActive = false
        if (success) enter()
    }

    fun scan() {
        if (_state.value.busy || externalActive) return
        if (!authenticated) { _command.value = LaundryCommand(LaundryCommandType.Login); return }
        if (_state.value.payment != null) { showPayment(); return }
        _command.value = LaundryCommand(LaundryCommandType.Scan)
    }

    fun scanReturned(resNo: String?, failure: String?) {
        externalActive = false
        if (!initialized) {
            initialEntry = false
            enterAfterExternal { scanReturned(resNo, failure) }
            return
        }
        if (resNo == null) {
            _state.update { it.copy(page = LaundryPage.Home, error = failure) }
            return
        }
        lastResNo = resNo
        _state.update { it.copy(page = LaundryPage.Programs, busy = true, device = null, quote = null, error = null) }
        viewModelScope.launch {
            try {
                val device = request { client.lookupDevice(resNo) }
                _state.update { it.copy(device = device) }
                quote(LaundryUiPolicy.defaultProgram(device.programs), debounce = false)
            } catch (error: Exception) { handle(error) }
            finally { _state.update { it.copy(busy = false) } }
        }
    }

    fun selectProgram(key: String) {
        quote(key, debounce = true)
    }

    private fun quote(key: String, debounce: Boolean) {
        val device = _state.value.device ?: return
        if (key.isBlank() || !device.canUse) return
        if (!client.supportsPayment) {
            _state.update { it.copy(selectedProgram = key, quote = null, quoteLoading = false) }
            return
        }
        val version = guard.nextQuote()
        quoteJob?.cancel()
        _state.update { it.copy(selectedProgram = key, quote = null, quoteLoading = true, error = null) }
        quoteJob = viewModelScope.launch {
            try {
                if (debounce) quotePause()
                val quote = request {
                    if (!guard.isCurrentQuote(version)) null
                    else client.previewOrder(device.resNo, key)
                }
                if (guard.isCurrentQuote(version)) _state.update { it.copy(quote = quote) }
            } catch (error: Exception) {
                if (guard.isCurrentQuote(version)) handle(error)
            } finally {
                if (guard.isCurrentQuote(version)) _state.update { it.copy(quoteLoading = false) }
            }
        }
    }

    fun createPayment(confirmedAmount: String) {
        if (!client.supportsPayment) return
        val state = _state.value
        if (state.page != LaundryPage.Programs || state.payment != null || state.busy || state.quoteLoading ||
            state.quote?.pay != confirmedAmount || !guard.beginSubmission()) return
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                request { client.createConfirmedPayment(confirmedAmount) }
                _state.update { it.copy(page = LaundryPage.Payment) }
                checkPayment()
                if (_state.value.payment?.status == LaundryPaymentStatus.Unpaid) openWechat()
            } catch (error: Exception) {
                // 创建结果不明确也读取加密意图，确保页面提供恢复而不是再次创建。
                try { loadPending() } catch (_: Exception) { }
                if (_state.value.payment != null) _state.update { it.copy(page = LaundryPage.Payment) }
                handle(error)
            } finally {
                guard.endSubmission()
                _state.update { it.copy(busy = false) }
            }
        }
    }

    private suspend fun loadPending() {
        try {
            val pending = request { client.pendingPayment() }
            _state.update { current -> current.copy(payment = pending?.copy(
                status = current.payment?.takeIf { it.reference == pending.reference }?.status
                    ?: pending.status,
            )) }
        } catch (error: Exception) {
            if (error.message == "PAYMENT_ACCOUNT_MISMATCH") {
                // 不展示其他账号的订单，但仍阻止创建新的付款意图。
                _state.update { it.copy(payment = LaundryPayment("其他账号的未完成订单", "", "", "—", accountMismatch = true)) }
            } else if (error !is CancellationException) {
                _state.update { it.copy(payment = it.payment ?: LaundryPayment("未完成订单待核验", "", "", "—")) }
            }
            throw error
        }
    }

    private suspend fun checkPayment() {
        if (paymentCheckBusy) return
        paymentCheckBusy = true
        try {
            loadPending()
            if (_state.value.payment == null) return
            try {
                val checkout = request { client.paymentCheckout() }
                val status = checkout
                _state.update { it.copy(payment = it.payment?.copy(status = status),
                    page = if (status == LaundryPaymentStatus.Success && it.page == LaundryPage.Payment)
                        LaundryPage.Home else it.page) }
            } catch (error: Exception) { handle(error) }
        } finally { paymentCheckBusy = false }
    }

    fun showPayment() {
        _state.update { it.copy(page = LaundryPage.Payment, error = null) }
        refresh()
    }

    fun relogin() {
        if (_state.value.busy || externalActive) return
        authenticated = false
        _command.value = LaundryCommand(LaundryCommandType.Login, "force_login")
    }

    fun resumePayment() {
        if (_state.value.busy || externalActive) return
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try { openWechat() }
            catch (error: Exception) { handle(error) }
            finally { _state.update { it.copy(busy = false) } }
        }
    }

    private suspend fun openWechat() {
        val uri = request { client.wechatPaymentUri() }
        _command.value = LaundryCommand(LaundryCommandType.Wechat, uri)
    }

    fun wechatReturned(failure: String? = null) {
        externalActive = false
        if (!initialized) {
            initialEntry = false
            enter()
            return
        }
        _state.update { it.copy(error = failure) }
        if (failure == null) refresh()
    }

    private fun enterAfterExternal(action: () -> Unit) {
        viewModelScope.launch {
            try {
                request {
                    client.initialize()
                    initialized = true
                    if (!client.hasSession()) throw IllegalStateException("SESSION_EXPIRED")
                    client.verify()
                }
                authenticated = true
                checkPayment()
                if (_state.value.payment != null) {
                    _state.update { it.copy(page = LaundryPage.Home) }
                    refreshOrders(useVerified = true)
                } else if (authenticated) action()
            } catch (error: Exception) { handle(error) }
        }
    }

    fun acknowledgePayment() {
        if (_state.value.busy) return
        _state.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                val paidOrder = _state.value.payment?.takeIf { it.status == LaundryPaymentStatus.Success }
                request { client.acknowledgeTerminalPayment() }
                _state.update { it.copy(payment = null, page = LaundryPage.Home,
                    acknowledgedPaidOrder = paidOrder?.takeIf { paid -> it.orders.none { row -> row.reference == paid.reference } }) }
                refreshOrders()
            } catch (error: Exception) { handle(error) }
            finally { _state.update { it.copy(busy = false) } }
        }
    }

    fun orders() {
        _state.update { it.copy(page = LaundryPage.Orders, error = null) }
        refresh()
    }

    /** 返回业务首页；下单请求一旦开始仍继续保存结果。 */
    fun back(): Boolean {
        if (_state.value.busy) return true
        if (_state.value.page == LaundryPage.Home || _state.value.page == LaundryPage.Loading) return false
        guard.nextQuote()
        quoteJob?.cancel()
        _state.update { it.copy(page = LaundryPage.Home, quoteLoading = false, error = null) }
        refresh()
        return true
    }

    fun refresh() {
        if (_state.value.busy) return
        if (!authenticated) { enter(); return }
        if (_state.value.page == LaundryPage.Programs) {
            val device = _state.value.device
            if (device == null) { scanReturned(lastResNo, null); return }
            if (!client.supportsPayment) scanReturned(device.resNo, null)
            else quote(_state.value.selectedProgram, debounce = false)
            return
        }
        if (refreshJob?.isActive == true) { refreshAgain = true; return }
        if (_state.value.ordersLoading || paymentCheckBusy) return
        refreshJob = viewModelScope.launch {
            do {
                refreshAgain = false
                _state.update { it.copy(error = null) }
                try { checkPayment(); if (authenticated) refreshOrders() }
                catch (error: Exception) { handle(error) }
            } while (refreshAgain && authenticated && !externalActive)
        }
    }

    private fun refreshAutomatic() {
        if (refreshJob?.isActive == true || _state.value.ordersLoading || paymentCheckBusy) return
        refresh()
    }

    private suspend fun refreshOrders(useVerified: Boolean = false) {
        if (_state.value.ordersLoading || !authenticated) return
        _state.update { it.copy(ordersLoading = true) }
        try {
            val snapshot = request { client.runningOrders(useVerified) }
            val orders = snapshot.orders
            sampledOrders = orders
            sampledAt = snapshot.observedAt
            ordersFailed = false
            val elapsedSeconds = (elapsedRealtime() - sampledAt) / 1000
            _state.update { it.copy(orders = orders.map { row ->
                row.copy(seconds = LaundryUiPolicy.remaining(row.seconds, elapsedSeconds))
            }, stale = false,
                acknowledgedPaidOrder = it.acknowledgedPaidOrder?.takeUnless { paid ->
                    orders.any { row -> row.reference == paid.reference }
                }) }
            if (_state.value.page == LaundryPage.Orders || _state.value.acknowledgedPaidOrder != null) {
                val history = request { client.recentOrders() }
                _state.update { it.copy(history = history,
                    acknowledgedPaidOrder = it.acknowledgedPaidOrder?.takeUnless { paid ->
                        history.any { row -> row.reference == paid.reference && row.completed }
                    }) }
            }
        } catch (error: Exception) {
            ordersFailed = true
            _state.update { it.copy(stale = true) }
            handle(error)
        } finally { _state.update { it.copy(ordersLoading = false) } }
    }

    fun foreground(active: Boolean) {
        foreground = active
        pollJob?.cancel()
        if (!active) { refreshAgain = false; return }
        pollJob = viewModelScope.launch {
            var nextRefresh = elapsedRealtime() + 15000
            while (isActive && foreground) {
                val now = elapsedRealtime()
                if (authenticated && !externalActive) {
                    val stale = ordersFailed || sampledAt == 0L || now - sampledAt > 45000
                    _state.update { state -> state.copy(stale = stale, orders = sampledOrders.map {
                        it.copy(seconds = LaundryUiPolicy.remaining(it.seconds, (now - sampledAt) / 1000))
                    }) }
                    if (now >= nextRefresh && !_state.value.busy && !_state.value.quoteLoading &&
                        _state.value.page != LaundryPage.Programs) {
                        refreshAutomatic()
                        nextRefresh = now + 15000
                    }
                }
                delay(1000)
            }
        }
        if (authenticated && !externalActive) refreshAutomatic()
    }

    private fun handle(error: Exception) {
        if (error is CancellationException) throw error
        if (error is LaundryInitializationException) {
            _state.update { it.copy(error = "校园洗衣初始化未通过，请保留以下检查结果：\n${error.report}") }
            return
        }
        if (error.message == "SESSION_EXPIRED") {
            authenticated = false
            guard.nextQuote()
            quoteJob?.cancel()
            sampledOrders = emptyList()
            _state.update { it.copy(page = LaundryPage.Loading, orders = emptyList(), history = emptyList(),
                device = null, quote = null, payment = null, acknowledgedPaidOrder = null, error = null) }
            if (!externalActive) _command.value = LaundryCommand(LaundryCommandType.Login)
            return
        }
        if (error.message == "PRICE_CHANGED" || error.message == "DEVICE_UNAVAILABLE") {
            _state.update { it.copy(quote = null) }
        }
        _state.update { it.copy(error = when (error.message) {
            "PRICE_CHANGED" -> "金额已变化，请刷新报价后重新确认。"
            "CREATE_UNCERTAIN" -> "订单结果待确认，请稍后查询，不会重复下单。"
            "PAYMENT_ACCOUNT_MISMATCH" -> "有另一账号的未完成订单，请使用原账号登录。"
            "PAYMENT_PENDING" -> "请先处理未完成的订单。"
            "PAYMENT_MISMATCH", "QUOTE_MISMATCH", "ORDER_MISMATCH" -> "订单信息不一致，请重新查询。"
            "WECHAT_CHANNEL_UNAVAILABLE" -> "暂时无法使用微信付款，请稍后重试。"
            "PAYMENT_NOT_INIT" -> "付款状态已变化，请重新查询。"
            "DEVICE_UNAVAILABLE" -> "设备暂不可用，请选择其他设备。"
            "DEVICE_NOT_FOUND" -> "未找到这台洗衣机，请检查二维码。"
            "UNSUPPORTED_DEVICE" -> "暂不支持这台设备，请扫描校园洗衣机。"
            "PROGRAM_UNAVAILABLE" -> "所选程序已变化，请重新扫码。"
            "DEVICE_MISMATCH" -> "设备信息与二维码不一致，请重新扫码。"
            else -> "暂时无法完成操作，请检查网络后重试。"
        }) }
    }

}
