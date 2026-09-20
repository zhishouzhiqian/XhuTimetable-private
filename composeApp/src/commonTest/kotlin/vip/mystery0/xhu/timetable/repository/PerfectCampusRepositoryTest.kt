package vip.mystery0.xhu.timetable.repository

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

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
}
