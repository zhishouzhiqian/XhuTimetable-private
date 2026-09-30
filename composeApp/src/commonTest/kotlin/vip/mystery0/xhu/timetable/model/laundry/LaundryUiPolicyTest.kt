package vip.mystery0.xhu.timetable.model.laundry

import kotlin.test.*

class LaundryUiPolicyTest {
    @Test fun onlyServerSuccessConfirmsPayment() {
        assertEquals(LaundryPaymentStatus.Success, LaundryUiPolicy.paymentStatus("SUCCESS"))
        assertEquals(LaundryPaymentStatus.Closed, LaundryUiPolicy.paymentStatus("CLOSE"))
        assertEquals(LaundryPaymentStatus.Unpaid, LaundryUiPolicy.paymentStatus("INIT"))
        assertEquals(LaundryPaymentStatus.Paying, LaundryUiPolicy.paymentStatus("PAYING"))
        assertEquals(LaundryPaymentStatus.Unknown, LaundryUiPolicy.paymentStatus("WECHAT_RETURNED"))
        assertEquals(LaundryPaymentStatus.Unknown, LaundryUiPolicy.paymentStatus("SUCCEED"))
    }
    @Test fun cancelledScannerDoesNotRelaunchOnResume() {
        val guard = LaundryInteractionGuard(true)
        assertTrue(guard.takeAutoScan(false))
        assertFalse(guard.takeAutoScan(false))
        assertFalse(guard.takeAutoScan(false))
    }
    @Test fun recoveryTakesPriorityOverAutomaticScan() {
        val guard = LaundryInteractionGuard(true)
        assertFalse(guard.takeAutoScan(true))
        assertFalse(guard.takeAutoScan(false))
    }
    @Test fun profileEntryDoesNotOpenCamera() {
        assertFalse(LaundryInteractionGuard(false).takeAutoScan(false))
    }
    @Test fun oldQuoteCannotEnablePaymentForNewSelection() {
        val guard = LaundryInteractionGuard(false)
        val first = guard.nextQuote()
        val second = guard.nextQuote()
        assertFalse(guard.isCurrentQuote(first))
        assertTrue(guard.isCurrentQuote(second))
        guard.nextQuote()
        assertFalse(guard.isCurrentQuote(second))
    }
    @Test fun duplicateSubmissionIsRejectedUntilFinished() {
        val guard = LaundryInteractionGuard(false)
        assertTrue(guard.beginSubmission())
        assertFalse(guard.beginSubmission())
        guard.endSubmission()
        assertTrue(guard.beginSubmission())
    }
    @Test fun countdownDoesNotInventMissingTimeOrNegativeTime() {
        assertNull(LaundryUiPolicy.remaining(null, 120))
        assertEquals(20L, LaundryUiPolicy.remaining(30, 10))
        assertEquals(0L, LaundryUiPolicy.remaining(30, 50))
        assertEquals(30L, LaundryUiPolicy.remaining(30, -5))
    }
    @Test fun defaultSelectionUsesOnlyServerPrograms() {
        val quick = LaundryProgram("quick", "快速洗", "", "2.00")
        val standard = LaundryProgram("standard", "标准洗", "", "4.00")
        assertEquals("standard", LaundryUiPolicy.defaultProgram(listOf(quick, standard)))
        assertEquals("quick", LaundryUiPolicy.defaultProgram(listOf(quick)))
        assertEquals("", LaundryUiPolicy.defaultProgram(emptyList()))
    }
}
