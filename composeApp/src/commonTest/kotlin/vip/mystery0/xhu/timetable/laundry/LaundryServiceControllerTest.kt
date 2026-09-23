package vip.mystery0.xhu.timetable.laundry

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import vip.mystery0.xhu.timetable.model.laundry.LaundryPhase
import vip.mystery0.xhu.timetable.model.laundry.LaundryWebCommand

class LaundryServiceControllerTest {
    @Test
    fun filtersUnpaidAndKeepsMultipleRunningOrders() {
        val controller = LaundryServiceController()
        controller.initialize()
        val session = controller.webCommand.value as LaundryWebCommand.CheckSession
        controller.onSessionResult(session.id, true)
        val query = controller.webCommand.value as LaundryWebCommand.QueryOrders
        controller.onOrdersResult(
            query.id,
            """[
                {"orderId":"one","deviceName":"一号洗衣机","status":"FULFILLING","expectedEndAtEpochMillis":2000},
                {"orderId":"two","deviceName":"二号洗衣机","status":"FULFILLING","expectedEndAtEpochMillis":3000},
                {"orderId":"unpaid","status":"TO_PAY"}
            ]""",
        )
        assertEquals(LaundryPhase.Running, controller.uiState.value.phase)
        assertEquals(listOf("one", "two"), controller.uiState.value.orders.map { it.orderId })

        controller.refreshOrders()
        assertEquals(LaundryPhase.Running, controller.uiState.value.phase)
        assertTrue(controller.uiState.value.refreshing)
        val retry = controller.webCommand.value as LaundryWebCommand.QueryOrders
        controller.onWebError(retry.id, "网络异常", authenticationExpired = false)
        assertFalse(controller.uiState.value.refreshing)
        assertTrue(controller.uiState.value.stale)
        assertEquals(2, controller.uiState.value.orders.size)
    }

    @Test
    fun expiredSessionClearsOrderAndIgnoresObsoleteResponses() {
        val controller = LaundryServiceController()
        controller.initialize()
        val first = controller.webCommand.value as LaundryWebCommand.CheckSession
        controller.checkSession()
        val second = controller.webCommand.value as LaundryWebCommand.CheckSession
        controller.onSessionResult(first.id, true)
        assertEquals(second.id, controller.webCommand.value?.id)
        controller.onSessionResult(second.id, false)
        assertEquals(LaundryPhase.NeedsLogin, controller.uiState.value.phase)
        assertFalse(controller.uiState.value.stale)
        assertTrue(controller.uiState.value.orders.isEmpty())
    }

    @Test
    fun loginReturnIsNotMistakenForCampusAuthentication() {
        val controller = LaundryServiceController()
        controller.checkSession(afterLogin = true)
        val check = controller.webCommand.value as LaundryWebCommand.CheckSession
        assertTrue(check.afterLogin)
        controller.onSessionResult(check.id, false)
        assertEquals(LaundryPhase.NeedsLogin, controller.uiState.value.phase)
        assertTrue(controller.uiState.value.message.contains("尚未确认登录"))
        assertTrue(controller.uiState.value.orders.isEmpty())
    }

    @Test
    fun foregroundWebViewOwnsTheQuery() {
        val gateway = LaundryWebSessionGateway()
        val background = gateway.register(false)
        val foreground = gateway.register(true)
        assertEquals(foreground, gateway.activeToken.value)
        gateway.unregister(foreground)
        assertEquals(background, gateway.activeToken.value)
    }

    @Test
    fun expiredAuthenticationDropsPreviouslyVisibleOrders() {
        val controller = LaundryServiceController()
        controller.initialize()
        val session = controller.webCommand.value as LaundryWebCommand.CheckSession
        controller.onSessionResult(session.id, true)
        val query = controller.webCommand.value as LaundryWebCommand.QueryOrders
        controller.onOrdersResult(query.id, """[{"orderId":"one","status":"FULFILLING"}]""")
        controller.checkSession()
        val recheck = controller.webCommand.value as LaundryWebCommand.CheckSession
        controller.onWebError(recheck.id, "expired", authenticationExpired = true)
        assertEquals(LaundryPhase.Expired, controller.uiState.value.phase)
        assertTrue(controller.uiState.value.orders.isEmpty())
    }
}
