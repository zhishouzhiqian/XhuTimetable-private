package vip.mystery0.xhu.timetable.repository

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json

class PerfectCampusRepositoryTest {
    @Test
    fun authorizationUrlContainsCapturedPublicConfiguration() {
        val url = buildPerfectCampusAuthorizationUrl("synthetic-token")
        assertEquals(1, Regex("token=").findAll(url).count())
        assertFalse(url.contains("JSESSIONID"))
        assertFalse(url.contains("openid"))
        assertEquals(true, url.startsWith("https://open.17wanxiao.com/api/authorize?"))
        assertTrue(url.contains("redirect_uri=https%3A%2F%2Fecard.xhu.edu.cn%2Fhomedwapp%2FopenHomePage"))
        assertTrue(url.contains("state=waterpage"))
    }

    @Test
    fun parsesMainAndSubsidyBalanceAsYuan() {
        val body = Json.parseToJsonElement(
            """{"mainFare":"12.34","subsidyFare":"0.66","status":"synthetic"}""",
        )
        assertEquals(1300L, parsePerfectCampusBalance(body))
    }

    @Test
    fun rejectsMissingOrMalformedMainBalance() {
        assertNull(parsePerfectCampusBalance(Json.parseToJsonElement("""{"subsidyFare":"1.00"}""")))
        assertNull(parsePerfectCampusBalance(Json.parseToJsonElement("""{"mainFare":"unknown"}""")))
        assertNull(parsePerfectCampusBalance(Json.parseToJsonElement("""{"mainFare":"1.00","subsidyFare":"bad"}""")))
    }

    @Test
    fun acceptsJsonStringBodyReturnedByCardApi() {
        val body = Json.parseToJsonElement(""""{\"mainFare\":\"8.00\",\"subsidyFare\":\"\"}"""")
        assertEquals(800L, parsePerfectCampusBalance(body))
    }
}
