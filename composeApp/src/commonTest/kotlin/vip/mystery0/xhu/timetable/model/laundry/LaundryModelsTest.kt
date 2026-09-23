package vip.mystery0.xhu.timetable.model.laundry

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class LaundryModelsTest {
    @Test
    fun homepageUsesNearestKnownEndTime() {
        val orders = listOf(
            LaundryOrderSummary("unknown"),
            LaundryOrderSummary("later", expectedEndAtEpochMillis = 20),
            LaundryOrderSummary("near", expectedEndAtEpochMillis = 10),
        )
        assertEquals("near", selectHomepageLaundryOrder(orders)?.orderId)
    }

    @Test
    fun transactionsAreHardDisabled() {
        assertFailsWith<IllegalStateException> { requireLaundryTransactionsEnabled() }
    }
}
