package vip.mystery0.xhu.timetable.repository

import kotlin.test.Test
import kotlin.test.assertEquals

class PerfectCampusCryptoTest {
    @Test
    fun encryptsWithCapturedTripleDesProtocol() {
        assertEquals(
            "6Xg7n0dfdfGMj/Kaz47gQw==",
            perfectCampusTripleDesEncrypt(
                plainText = "{\"test\":true}",
                key = "123456789012345678901234",
            ),
        )
    }
}
