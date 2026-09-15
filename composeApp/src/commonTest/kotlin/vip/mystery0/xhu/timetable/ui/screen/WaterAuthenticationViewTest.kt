package vip.mystery0.xhu.timetable.ui.screen

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class WaterAuthenticationViewTest {
    @Test
    fun extractsEcardOpenIdFromRedirectFragment() {
        val openId = "a".repeat(64)

        assertEquals(
            openId,
            extractWaterOpenId(
                "https://ecard.xhu.edu.cn/#/pages/homepage/index/index?openid=$openId",
            ),
        )
    }

    @Test
    fun rejectsWechatOpenId() {
        assertNull(
            extractWaterOpenId(
                "https://ecard.xhu.edu.cn/#/pages/homepage/index/index?openid=${"a".repeat(28)}",
            ),
        )
    }

    @Test
    fun rejectsOpenIdFromUntrustedOrigin() {
        assertNull(
            extractWaterOpenId(
                "https://example.com/#/pages/homepage/index/index?openid=${"a".repeat(64)}",
            ),
        )
    }

    @Test
    fun extractsSessionIdWithoutReturningOtherCookies() {
        assertEquals(
            "session-value",
            extractWaterSessionId("theme=dark; JSESSIONID=session-value; locale=zh-CN"),
        )
    }
}
