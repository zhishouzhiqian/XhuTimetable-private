package vip.mystery0.xhu.timetable.model.water

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import vip.mystery0.xhu.timetable.water.WaterServiceController
import kotlinx.serialization.json.Json
import vip.mystery0.xhu.timetable.repository.hasActiveWaterRecord
import vip.mystery0.xhu.timetable.repository.isWaterAuthenticationExpiredMessage

class WaterModelsTest {
    @Test
    fun balanceStringUsesIntegerCents() {
        assertEquals(200L, parseYuanToCents("2"))
        assertEquals(205L, parseYuanToCents("2.05"))
        assertEquals(250L, parseYuanToCents("￥2.5"))
        assertNull(parseYuanToCents("2.005"))
        assertNull(parseYuanToCents("unknown"))
    }

    @Test
    fun lowBalanceBoundaryIsStrictlyBelowTwoYuan() {
        assertTrue(199L < WaterServiceController.LOW_BALANCE_CENTS)
        assertFalse(200L < WaterServiceController.LOW_BALANCE_CENTS)
    }

    @Test
    fun balanceDifferenceRejectsRechargeOrMissingValue() {
        assertEquals(35L, calculateWaterCost(500L, 465L))
        assertNull(calculateWaterCost(500L, 520L))
        assertNull(calculateWaterCost(null, 465L))
    }

    @Test
    fun recordCarriesServerFields() {
        val record = WaterUseRecord(
            beginTime = "2026-01-01 00:00:00",
            amountFen = 25,
            durationSeconds = 61,
            waterUsage = "1.2",
            chargingType = "test",
            posCode = "000000",
        )
        assertEquals(25L, record.amountFen)
        assertEquals(61L, record.durationSeconds)
        assertEquals("000000", record.posCode)
    }

    @Test
    fun serverRunningStateUsesNonEmptyUnclosedRecordList() {
        assertTrue(hasActiveWaterRecord(Json.parseToJsonElement("{\"data\":{\"wcrList\":[{}]}}")))
        assertFalse(hasActiveWaterRecord(Json.parseToJsonElement("{\"data\":{\"wcrList\":[]}}")))
    }

    @Test
    fun authenticationAndHomeNavigationAreDistinct() {
        val configured = WaterCredentials("open", "session", "000000", "2")
        assertTrue(isWaterAuthenticationExpiredMessage("session expired"))
        assertEquals(
            WaterQuickAction.NavigateToDetails,
            decideWaterQuickAction(configured, WaterUiState.AuthExpired, false),
        )
        assertEquals(
            WaterQuickAction.Start,
            decideWaterQuickAction(configured, WaterUiState.Ready, false),
        )
        assertEquals(
            WaterQuickAction.Stop,
            decideWaterQuickAction(configured, WaterUiState.Running("ok"), true),
        )
    }
}
