package vip.mystery0.xhu.timetable.laundry

import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.*
import vip.mystery0.xhu.timetable.model.laundry.*

class CampusLaundryViewModelTest {
    private val scopes = mutableListOf<CoroutineScope>()
    private fun model(gateway: FakeGateway, scan: Boolean = false, external: Boolean = false): CampusLaundryViewModel {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        scopes += scope
        return CampusLaundryViewModel(gateway, scan, external, scope, Dispatchers.Unconfined,
            elapsedRealtime = { 1000L }, quotePause = {})
    }
    @AfterTest fun cleanup() { scopes.forEach { it.cancel() } }

    @Test fun loginGatesCameraAndAutoScanIsConsumedOnce() {
        val gateway = FakeGateway().apply { session = false }
        val model = model(gateway, scan = true)
        assertEquals(LaundryCommandType.Login, model.command.value?.type)
        model.consumeCommand()
        gateway.session = true
        model.loginReturned(true)
        assertEquals(LaundryCommandType.Scan, model.command.value?.type)
        model.consumeCommand()
        model.scanReturned(null, null)
        model.foreground(true)
        assertNull(model.command.value)
        assertEquals(LaundryPage.Home, model.state.value.page)
        assertFalse(model.autoScanPending)
    }

    @Test fun pendingPaymentSurvivesRestartAndPreventsAutoScan() {
        val gateway = FakeGateway().apply { pending = pendingOrder() }
        val model = model(gateway, scan = true)
        assertNotNull(model.state.value.payment)
        assertNull(model.command.value)
        assertEquals(0, gateway.creates)
        model.scan()
        assertEquals(LaundryPage.Payment, model.state.value.page)
        assertNull(model.command.value)
    }

    @Test fun ambiguousCreationKeepsIntentAndNeverRetriesCreate() {
        val gateway = FakeGateway().apply { uncertain = true }
        val model = model(gateway)
        model.scanReturned("mock-device", null)
        model.createPayment("4.00")
        assertEquals(1, gateway.creates)
        assertEquals(LaundryPage.Payment, model.state.value.page)
        assertNotNull(model.state.value.payment)
        assertNull(model.command.value)
        model.createPayment("4.00")
        model.refresh()
        assertEquals(1, gateway.creates)
        assertTrue(gateway.pending.length() > 0)
    }

    @Test fun wechatReturnRequiresServerSuccessAndExplicitAcknowledgment() {
        val gateway = FakeGateway()
        val model = model(gateway)
        model.scanReturned("mock-device", null)
        model.createPayment("4.00")
        assertEquals(LaundryCommandType.Wechat, model.command.value?.type)
        model.consumeCommand()
        gateway.checkoutStatus = "PAYING"
        model.wechatReturned()
        assertEquals(LaundryPaymentStatus.Paying, model.state.value.payment?.status)
        assertEquals(LaundryPage.Payment, model.state.value.page)
        gateway.checkoutStatus = "SUCCESS"
        gateway.running = runningOrder(119)
        model.refresh()
        assertEquals(LaundryPage.Home, model.state.value.page)
        assertEquals(119L, model.state.value.orders.single().seconds)
        assertTrue(gateway.pending.length() > 0)
        assertEquals(0, gateway.acknowledgments)
        model.acknowledgePayment()
        assertEquals(1, gateway.acknowledgments)
        assertNull(model.state.value.payment)
    }

    @Test fun failedQueryKeepsLastOrderAndMarksItStale() {
        val gateway = FakeGateway().apply { running = runningOrder(119) }
        val model = model(gateway)
        gateway.ordersFail = true
        model.refresh()
        assertEquals(119L, model.state.value.orders.single().seconds)
        assertTrue(model.state.value.stale)
        assertNotNull(model.state.value.error)
    }

    @Test fun expiredSessionClearsPrivateUiAndShowsLogin() {
        val gateway = FakeGateway().apply { running = runningOrder(119) }
        val model = model(gateway)
        gateway.session = false
        model.refresh()
        assertEquals(LaundryCommandType.Login, model.command.value?.type)
        assertTrue(model.state.value.orders.isEmpty())
        assertNull(model.state.value.device)
        assertEquals(LaundryPage.Loading, model.state.value.page)
    }

    @Test fun restoredExternalScanWaitsForResultWithoutRelaunch() {
        val gateway = FakeGateway()
        val model = model(gateway, external = true)
        assertNull(model.command.value)
        model.scanReturned("mock-device", null)
        assertEquals(LaundryPage.Programs, model.state.value.page)
        assertEquals("standard", model.state.value.selectedProgram)
        assertNull(model.command.value)
    }

    @Test fun mismatchedAccountBlocksNewScanAndOffersLogin() {
        val gateway = FakeGateway().apply { accountMismatch = true }
        val model = model(gateway, scan = true)
        assertTrue(model.state.value.payment?.accountMismatch == true)
        model.scan()
        assertNull(model.command.value)
        assertEquals(0, gateway.creates)
        model.relogin()
        assertEquals(LaundryCommandType.Login, model.command.value?.type)
        assertEquals("force_login", model.command.value?.uri)
    }

    @Test fun restoredScannerHonorsPersistedPendingPayment() {
        val gateway = FakeGateway().apply { pending = pendingOrder() }
        val model = model(gateway, external = true)
        model.scanReturned("mock-device", null)
        assertEquals(LaundryPage.Home, model.state.value.page)
        assertNotNull(model.state.value.payment)
        assertNull(model.state.value.device)
        assertEquals(0, gateway.creates)
    }

    @Test fun multipleOrdersAndServerCompletionDriveHomeState() {
        val gateway = FakeGateway().apply { running = JSONArray().put(runningOrder(119).getJSONObject(0))
            .put(runningOrder(90).getJSONObject(0)) }
        val model = model(gateway)
        assertEquals(2, model.state.value.orders.count { it.running })
        gateway.running = JSONArray().put(JSONObject().put("name", "测试设备").put("completed", true)
            .put("status", "已付款 · 洗衣完成"))
        model.refresh()
        assertTrue(model.state.value.orders.none { it.running })
    }

    @Test fun changedAmountDoesNotCreateOrOpenWechat() {
        val gateway = FakeGateway().apply { priceChanged = true }
        val model = model(gateway)
        model.scanReturned("mock-device", null)
        model.createPayment("4.00")
        assertEquals(0, gateway.creates)
        assertNull(model.state.value.payment)
        assertNull(model.command.value)
        assertNull(model.state.value.quote)
        assertNotNull(model.state.value.error)
    }

    @Test fun acknowledgmentKeepsPaidWaitingUntilServerOrderAppears() {
        val gateway = FakeGateway().apply { pending = pendingOrder(); checkoutStatus = "SUCCESS" }
        val model = model(gateway)
        model.acknowledgePayment()
        assertNull(model.state.value.payment)
        assertNotNull(model.state.value.acknowledgedPaidOrder)
        gateway.running = runningOrder(119).apply { getJSONObject(0).put("reference", "mock-sequence") }
        model.refresh()
        assertNull(model.state.value.acknowledgedPaidOrder)
        assertTrue(model.state.value.orders.single().running)
    }

    @Test fun paidWaitingOrderRemainsVisibleAfterRestartWithoutPaymentRecord() {
        val gateway = FakeGateway().apply { running = JSONArray().put(JSONObject().put("name", "测试设备")
            .put("reference", "mock-sequence").put("waitingForDevice", true)) }
        val model = model(gateway)
        assertNull(model.state.value.payment)
        assertTrue(model.state.value.orders.single().waitingForDevice)
        assertFalse(model.state.value.orders.single().running)
        assertNull(model.state.value.orders.single().seconds)
    }

    @Test fun acknowledgedOrderCanCompleteWithoutEverAppearingInUrgentList() {
        val gateway = FakeGateway().apply { pending = pendingOrder(); checkoutStatus = "SUCCESS" }
        val model = model(gateway)
        model.acknowledgePayment()
        assertNotNull(model.state.value.acknowledgedPaidOrder)
        gateway.history = JSONArray().put(JSONObject().put("reference", "mock-sequence").put("completed", true))
        model.refresh()
        assertNull(model.state.value.acknowledgedPaidOrder)
        assertTrue(model.state.value.orders.isEmpty())
    }

    @Test fun onlyInitialEntryMayReuseVerifiedOrders() {
        val gateway = FakeGateway()
        val model = model(gateway)
        model.refresh()
        model.wechatReturned()
        assertEquals(listOf(true, false, false), gateway.samples)
    }

    @Test fun rapidSelectionsWaitThenRequestOnlyLatestProgram() = runBlocking {
        val gateway = FakeGateway()
        val pause = CompletableDeferred<Unit>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined).also { scopes += it }
        val model = CampusLaundryViewModel(gateway, false, scope = scope,
            ioDispatcher = Dispatchers.Unconfined, elapsedRealtime = { 1000L }, quotePause = { pause.await() })
        model.scanReturned("mock-device", null)
        assertEquals(listOf("standard"), gateway.quotes)
        model.selectProgram("quick")
        model.selectProgram("large")
        model.selectProgram("spin")
        assertTrue(model.state.value.quoteLoading)
        assertNull(model.state.value.quote)
        model.createPayment("4.00")
        assertEquals(0, gateway.creates)
        assertEquals(listOf("standard"), gateway.quotes)
        pause.complete(Unit)
        assertEquals(listOf("standard", "spin"), gateway.quotes)
        assertEquals("spin", model.state.value.selectedProgram)
        assertNotNull(model.state.value.quote)
        Unit
    }

    @Test fun repeatedRefreshAndWechatReturnQueueOneFreshCheckout() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { io ->
            val gateway = FakeGateway().apply { pending = pendingOrder() }
            val scope = CoroutineScope(coroutineContext + SupervisorJob()).also { scopes += it }
            val model = CampusLaundryViewModel(gateway, false, scope = scope, ioDispatcher = io,
                elapsedRealtime = { 1000L }, quotePause = {})
            awaitState { !model.state.value.busy }
            val started = CompletableDeferred<Unit>()
            val release = CountDownLatch(1)
            gateway.beforeOrders = {
                started.complete(Unit)
                check(release.await(3, TimeUnit.SECONDS))
            }
            try {
                model.refresh()
                withTimeout(3000) { started.await() }
                repeat(8) { model.refresh() }
                gateway.checkoutStatus = "SUCCESS"
                model.wechatReturned()
                gateway.beforeOrders = null
                release.countDown()
                awaitState { gateway.samples.size == 3 && !model.state.value.ordersLoading }
                assertEquals(listOf(true, false, false), gateway.samples)
                assertEquals(3, gateway.checkouts)
                assertEquals(LaundryPaymentStatus.Success, model.state.value.payment?.status)
            } finally { release.countDown(); scope.cancel() }
        }
    }

    @Test fun countdownUsesOriginalSampleAndKeepsTickingDuringSlowRefresh() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { io ->
            val gateway = FakeGateway().apply { running = runningOrder(90); observedAt = 1000L }
            var now = 3000L
            val scope = CoroutineScope(coroutineContext + SupervisorJob()).also { scopes += it }
            val model = CampusLaundryViewModel(gateway, false, scope = scope, ioDispatcher = io,
                elapsedRealtime = { now }, quotePause = {})
            awaitState { !model.state.value.busy }
            assertEquals(88L, model.state.value.orders.single().seconds)
            val release = CountDownLatch(1)
            gateway.beforeOrders = { check(release.await(4, TimeUnit.SECONDS)) }
            try {
                model.foreground(true)
                awaitState { model.state.value.ordersLoading }
                assertEquals(88L, model.state.value.orders.single().seconds)
                now = 5000L
                awaitState { model.state.value.orders.single().seconds == 86L }
                assertTrue(model.state.value.ordersLoading)
                now = 92000L
                awaitState { model.state.value.orders.single().seconds == 0L }
                assertTrue(model.state.value.stale)
                assertEquals(1, gateway.samples.size)
            } finally { model.foreground(false); release.countDown(); scope.cancel() }
        }
    }

    private suspend fun awaitState(condition: () -> Boolean) {
        withTimeout(3000) { while (!condition()) delay(10) }
    }

    private class FakeGateway : CampusLaundryGateway {
        var session = true
        var pending = JSONObject()
        var running = JSONArray()
        var history = JSONArray()
        var checkoutStatus = "INIT"
        var uncertain = false
        var ordersFail = false
        var accountMismatch = false
        var priceChanged = false
        var creates = 0
        var acknowledgments = 0
        var samples = mutableListOf<Boolean>()
        var observedAt = 1000L
        val quotes = mutableListOf<String>()
        var checkouts = 0
        @Volatile var beforeOrders: (() -> Unit)? = null
        override fun initialize() {}
        override fun hasSession() = session
        override fun verify() { checkSession() }
        private fun checkSession() { if (!session) throw IllegalStateException("SESSION_EXPIRED") }
        override fun lookupDevice(resNo: String) = JSONObject().put("resNo", resNo).put("canUse", true)
            .put("name", "测试洗衣机").put("programs", JSONArray().put(JSONObject().put("key", "standard")
                .put("name", "标准洗").put("priceYuan", "4.00")))
        override fun previewOrder(resNo: String, key: String): JSONObject {
            quotes += key
            return JSONObject().put("total", "4.00").put("discount", "0.00").put("pay", "4.00")
        }
        override fun pendingPayment(): JSONObject {
            if (accountMismatch) throw IllegalStateException("PAYMENT_ACCOUNT_MISMATCH")
            return pending
        }
        override fun createConfirmedPayment(amount: String) {
            if (priceChanged) throw IllegalStateException("PRICE_CHANGED")
            if (pending.length() > 0) throw IllegalStateException("PAYMENT_PENDING")
            creates++
            pending = pendingOrder()
            if (uncertain) throw IllegalStateException("CREATE_UNCERTAIN")
        }
        override fun paymentCheckout(): JSONObject {
            checkouts++
            if (uncertain) throw IllegalStateException("CREATE_UNCERTAIN")
            return JSONObject().put("status", checkoutStatus)
        }
        override fun wechatPaymentUri() = "weixin://mock-test-only"
        override fun acknowledgeTerminalPayment() {
            check(checkoutStatus == "SUCCESS" || checkoutStatus == "CLOSE")
            acknowledgments++
            pending = JSONObject()
        }
        override fun runningOrders(useVerified: Boolean): CampusOrderSnapshot {
            beforeOrders?.invoke()
            checkSession()
            if (ordersFail) throw IllegalStateException("NETWORK_ERROR")
            samples += useVerified
            return CampusOrderSnapshot(running, observedAt)
        }
        override fun recentOrders() = history
    }

    companion object {
        private fun pendingOrder() = JSONObject().put("isvOrderId", "mock-sequence").put("amount", 400)
            .put("device", "测试洗衣机").put("program", "标准洗")
        private fun runningOrder(seconds: Long) = JSONArray().put(JSONObject().put("name", "测试洗衣机")
            .put("program", "标准洗").put("status", "已付款 · 运行中").put("running", true).put("seconds", seconds))
    }
}
