package vip.mystery0.xhu.timetable.water

import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterNetworkException

class WaterCommandReconciliationTest {
    @Test
    fun gatewayFailureAfterExecutionDoesNotResendCommand() = runImmediateTest {
        var commands = 0
        var queries = 0
        executeWaterCommandWithReconciliation(
            command = { commands++; throw WaterNetworkException("HTTP 502") },
            readRunning = { queries++; true },
            expectedRunning = true,
        )
        assertEquals(1, commands)
        assertEquals(1, queries)
    }

    @Test
    fun unavailableStateKeepsOutcomeUncertain() = runImmediateTest {
        assertFailsWith<WaterCommandUncertainException> {
            executeWaterCommandWithReconciliation(
                command = { throw WaterNetworkException("HTTP 503") },
                readRunning = { throw WaterNetworkException("offline") },
                expectedRunning = true,
            )
        }
    }

    @Test
    fun expiredAuthenticationIsPassedToSingleRecovery() = runImmediateTest {
        var queries = 0
        assertFailsWith<WaterAuthExpiredException> {
            executeWaterCommandWithReconciliation(
                command = { throw WaterAuthExpiredException() },
                readRunning = { queries++; false },
                expectedRunning = true,
            )
        }
        assertEquals(0, queries)
    }

    @Test
    fun stopGatewayFailureCanBeConfirmedByClosedState() = runImmediateTest {
        executeWaterCommandWithReconciliation(
            command = { throw WaterNetworkException("HTTP 502") },
            readRunning = { false },
            expectedRunning = false,
        )
    }
}

private fun runImmediateTest(block: suspend () -> Unit) {
    var outcome: Result<Unit>? = null
    block.startCoroutine(object : Continuation<Unit> {
        override val context = EmptyCoroutineContext
        override fun resumeWith(result: Result<Unit>) { outcome = result }
    })
    checkNotNull(outcome) { "测试协程发生了意外挂起" }.getOrThrow()
}
