package vip.mystery0.xhu.timetable.model.water

import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertEquals

class WaterSchoolSessionTest {
    @Test
    fun sessionCookieSurvivesSerializationWithoutInventingExpiration() {
        val restored = Json.decodeFromString<WaterSchoolSession>(Json.encodeToString(cookie()))
        assertTrue(restored.canRestore(10_000.0))
        assertEquals(null, restored.expiresAtSeconds)
        assertTrue(restored.httpOnly)
        assertFalse(restored.toString().contains("synthetic-session"))
    }

    @Test
    fun rejectsExpiredAndForeignCookies() {
        assertFalse(cookie(expires = 100.0).canRestore(100.0))
        assertTrue(cookie(expires = 101.0).canRestore(100.0))
        assertFalse(cookie(domain = "xhyb.xhu.edu.cn.attacker.test").canRestore(100.0))
        assertFalse(cookie(value = "").canRestore(100.0))
        assertFalse(cookie(value = "synthetic;injected=value").canRestore(100.0))
    }

    private fun cookie(
        value: String = "synthetic-session",
        domain: String = "xhyb.xhu.edu.cn",
        expires: Double? = null,
    ) = WaterSchoolSession(value, domain, "/", false, true, expires)
}
