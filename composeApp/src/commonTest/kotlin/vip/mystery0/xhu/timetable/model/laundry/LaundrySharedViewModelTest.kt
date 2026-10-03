package vip.mystery0.xhu.timetable.model.laundry

import kotlinx.coroutines.*
import vip.mystery0.xhu.timetable.repository.LaundryGateway
import vip.mystery0.xhu.timetable.repository.LaundryOrderSnapshot
import vip.mystery0.xhu.timetable.viewmodel.LaundryViewModel
import kotlin.test.*

/** 直接测试两端共用的业务状态，不加载 Android SDK 或 iOS 页面。 */
class LaundrySharedViewModelTest {
    private val scopes = mutableListOf<CoroutineScope>()
    private fun model(gateway: FakeGateway, scan: Boolean = false, pause: suspend () -> Unit = {}): LaundryViewModel {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined).also { scopes += it }
        return LaundryViewModel(gateway, scan, scope = scope, ioDispatcher = Dispatchers.Unconfined,
            elapsedRealtime = { 3000L }, quotePause = pause)
    }
    @AfterTest fun cleanup() { scopes.forEach { it.cancel() } }

    @Test fun loginThenScanIsConsumedOnceAndCancelReturnsHome() {
        val gateway = FakeGateway().apply { session = false }
        val model = model(gateway, scan = true)
        assertEquals(LaundryCommandType.Login, model.command.value?.type)
        model.consumeCommand()
        gateway.session = true
        model.loginReturned(true)
        assertEquals(LaundryCommandType.Scan, model.command.value?.type)
        model.consumeCommand()
        model.scanReturned(null, null)
        assertEquals(LaundryPage.Home, model.state.value.page)
        assertNull(model.command.value)
        assertFalse(model.autoScanPending)
    }

    @Test fun pendingPaymentBlocksNewScanAndSubmissionAfterRestart() {
        val gateway = FakeGateway().apply { pending = payment() }
        val model = model(gateway, scan = true)
        assertNull(model.command.value)
        model.scan()
        assertEquals(LaundryPage.Payment, model.state.value.page)
        model.createPayment("4.00")
        assertEquals(0, gateway.creates)
    }

    @Test fun debouncedProgramRequiresFreshQuoteBeforePaying() {
        val gateway = FakeGateway()
        val release = CompletableDeferred<Unit>()
        val model = model(gateway, pause = { release.await() })
        model.scanReturned("mock-device", null)
        model.selectProgram("quick")
        model.selectProgram("standard")
        assertNull(model.state.value.quote)
        model.createPayment("4.00")
        assertEquals(0, gateway.creates)
        assertEquals(listOf("standard"), gateway.quoted)
        release.complete(Unit)
        assertEquals(listOf("standard", "standard"), gateway.quoted)
        assertEquals("4.00", model.state.value.quote?.pay)
    }

    @Test fun ambiguousCreateKeepsIntentAndCannotCreateAgain() {
        val gateway = FakeGateway().apply { uncertain = true }
        val model = model(gateway)
        model.scanReturned("mock-device", null)
        model.createPayment("4.00")
        assertNotNull(model.state.value.payment)
        model.createPayment("4.00")
        model.refresh()
        assertEquals(1, gateway.creates)
        assertNull(model.command.value)
    }

    @Test fun wechatReturnQueriesServerAndAcknowledgmentVerifiesTerminalAgain() {
        val gateway = FakeGateway()
        val model = model(gateway)
        model.scanReturned("mock-device", null)
        model.createPayment("4.00")
        model.consumeCommand()
        gateway.checkout = LaundryPaymentStatus.Paying
        model.wechatReturned()
        assertEquals(LaundryPaymentStatus.Paying, model.state.value.payment?.status)
        assertEquals(LaundryPage.Payment, model.state.value.page)
        assertEquals(0, gateway.acknowledgments)
        gateway.checkout = LaundryPaymentStatus.Success
        model.wechatReturned()
        assertEquals(LaundryPage.Home, model.state.value.page)
        assertNotNull(gateway.pending)
        model.acknowledgePayment()
        assertNull(gateway.pending)
        assertEquals(1, gateway.acknowledgments)
        assertTrue(gateway.samples.drop(1).all { !it })
    }

    @Test fun multipleOrdersUseSampleTimeAndFailureKeepsThemStale() {
        val gateway = FakeGateway().apply { running = listOf(order(90), order(1)) }
        val model = model(gateway)
        assertEquals(listOf(88L, 0L), model.state.value.orders.map { it.seconds })
        gateway.ordersFail = true
        model.refresh()
        assertEquals(2, model.state.value.orders.size)
        assertTrue(model.state.value.stale)
        gateway.session = false
        model.refresh()
        assertEquals(LaundryCommandType.Login, model.command.value?.type)
        assertTrue(model.state.value.orders.isEmpty())
    }

    @Test fun readOnlyGatewayShowsProgramsAndOrdersWithoutQuoteOrCreate() {
        val gateway = FakeGateway().apply { supportsPayment = false }
        val model = model(gateway)
        model.scanReturned("mock-device", null)
        model.selectProgram("quick")
        model.createPayment("3.00")
        assertFalse(model.state.value.paymentAvailable)
        assertEquals(LaundryPage.Programs, model.state.value.page)
        assertEquals("quick", model.state.value.selectedProgram)
        assertFalse(model.state.value.quoteLoading)
        assertNull(model.state.value.quote)
        assertTrue(gateway.quoted.isEmpty())
        assertEquals(0, gateway.creates)
        model.refresh()
        assertTrue(gateway.samples.isNotEmpty())
    }

    private class FakeGateway : LaundryGateway {
        override var supportsPayment = true
        var session = true
        var pending: LaundryPayment? = null
        var checkout = LaundryPaymentStatus.Unpaid
        var running = emptyList<LaundryOrder>()
        var uncertain = false
        var ordersFail = false
        var creates = 0
        var acknowledgments = 0
        val quoted = mutableListOf<String>()
        val samples = mutableListOf<Boolean>()
        override suspend fun initialize() {}
        override suspend fun hasSession() = session
        override suspend fun verify() = checkSession()
        private fun checkSession() { if (!session) error("SESSION_EXPIRED") }
        override suspend fun lookupDevice(resNo: String) = LaundryDevice(resNo, "测试设备", "测试宿舍", "空闲", true,
            listOf(LaundryProgram("standard", "标准洗", "", "4.00"), LaundryProgram("quick", "快速洗", "", "3.00")))
        override suspend fun previewOrder(resNo: String, key: String): LaundryQuote {
            quoted += key
            return LaundryQuote("4.00", "0.00", "4.00")
        }
        override suspend fun pendingPayment() = pending
        override suspend fun createConfirmedPayment(amount: String) {
            check(pending == null)
            creates++
            pending = payment()
            if (uncertain) error("CREATE_UNCERTAIN")
        }
        override suspend fun paymentCheckout(): LaundryPaymentStatus {
            if (uncertain) error("CREATE_UNCERTAIN")
            return checkout
        }
        override suspend fun wechatPaymentUri() = "weixin://mock-test-only"
        override suspend fun acknowledgeTerminalPayment() {
            check(paymentCheckout() in listOf(LaundryPaymentStatus.Success, LaundryPaymentStatus.Closed))
            acknowledgments++
            pending = null
        }
        override suspend fun runningOrders(useVerified: Boolean): LaundryOrderSnapshot {
            checkSession()
            if (ordersFail) error("NETWORK_ERROR")
            samples += useVerified
            return LaundryOrderSnapshot(running, 1000L)
        }
        override suspend fun recentOrders() = emptyList<LaundryOrder>()
    }

    companion object {
        private fun payment() = LaundryPayment("测试设备", "测试宿舍", "标准洗", "4.00", reference = "mock-order")
        private fun order(seconds: Long) = LaundryOrder("测试设备", "标准洗", status = "运行中", running = true, seconds = seconds)
    }
}
