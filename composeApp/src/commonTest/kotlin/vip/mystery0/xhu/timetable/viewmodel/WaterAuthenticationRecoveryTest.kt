package vip.mystery0.xhu.timetable.viewmodel

import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException

class WaterAuthenticationRecoveryTest {
    @Test
    fun successfulRecoveryRetriesOriginalOperationOnce() {
        var calls = 0
        var recoveries = 0

        val result = runImmediateSuspend {
            retryOnceAfterWaterAuthenticationExpired(
                operation = {
                    calls++
                    if (calls == 1) throw WaterAuthExpiredException()
                    "restored"
                },
                recover = {
                    recoveries++
                    true
                },
            )
        }.getOrThrow()

        assertEquals("restored", result)
        assertEquals(2, calls)
        assertEquals(1, recoveries)
    }

    @Test
    fun failedRecoveryDoesNotRetryOperation() {
        var calls = 0
        var recoveries = 0

        assertFailsWith<WaterAuthExpiredException> {
            runImmediateSuspend {
                retryOnceAfterWaterAuthenticationExpired(
                    operation = {
                        calls++
                        throw WaterAuthExpiredException()
                    },
                    recover = {
                        recoveries++
                        false
                    },
                )
            }.getOrThrow()
        }

        assertEquals(1, calls)
        assertEquals(1, recoveries)
    }

    @Test
    fun secondAuthenticationFailureDoesNotStartRecoveryLoop() {
        var calls = 0
        var recoveries = 0

        assertFailsWith<WaterAuthExpiredException> {
            runImmediateSuspend {
                retryOnceAfterWaterAuthenticationExpired(
                    operation = {
                        calls++
                        throw WaterAuthExpiredException()
                    },
                    recover = {
                        recoveries++
                        true
                    },
                )
            }.getOrThrow()
        }

        assertEquals(2, calls)
        assertEquals(1, recoveries)
    }

    @Test
    fun replacingAuthenticationPreservesSelectedDevice() {
        val restored = WaterCredentials(
            openId = "old-open-id",
            sessionId = "old-session",
            posCode = "123456",
            orgId = "2",
        ).withAuthentication("new-open-id", "new-session")

        assertEquals("123456", restored.posCode)
        assertEquals("2", restored.orgId)
        assertTrue(restored.authenticated)
    }
}

private fun <T> runImmediateSuspend(block: suspend () -> T): Result<T> {
    var outcome: Result<T>? = null
    block.startCoroutine(object : Continuation<T> {
        override val context = EmptyCoroutineContext

        override fun resumeWith(result: Result<T>) {
            outcome = result
        }
    })
    return checkNotNull(outcome) { "测试协程发生了意外挂起" }
}
