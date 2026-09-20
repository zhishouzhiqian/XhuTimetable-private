package vip.mystery0.xhu.timetable.ui.screen

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

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

    @Test
    fun allowsOAuthIntermediateRoutes() {
        assertFalse(requiresWaterAuthenticationInteraction("https://open.weixin.qq.com/connect/oauth2/authorize?code=test"))
        assertFalse(requiresWaterAuthenticationInteraction("https://api.szszcloud.cn/v1/wechat/oauth2?state=test"))
        assertFalse(requiresWaterAuthenticationInteraction("https://api.szszcloud.cn/v1/wechat/oauth/back?code=test"))
        assertFalse(requiresWaterAuthenticationInteraction(WATER_AUTH_ENTRY_URL))
    }

    @Test
    fun detectsKnownInteractivePages() {
        assertTrue(requiresWaterAuthenticationInteraction("https://xhyb.xhu.edu.cn/v1/wechat/qrcodelogin"))
        assertTrue(requiresWaterAuthenticationInteraction("https://xhyb.xhu.edu.cn/v1/wechat/qrcodelogin/?clientId=test#test"))
        assertTrue(requiresWaterAuthenticationInteraction("https://xhyb.xhu.edu.cn/v1/wechat/bindpage?open_id=redacted"))
        assertFalse(requiresWaterAuthenticationInteraction("https://ecard.xhu.edu.cn/#/pages/homepage/index/index?openid=redacted"))
    }

    @Test
    fun doesNotClassifyByPathPrefixOrQueryContents() {
        assertFalse(requiresWaterAuthenticationInteraction("https://xhyb.xhu.edu.cn/v1/wechat/qrcodelogin/callback"))
        assertFalse(requiresWaterAuthenticationInteraction("https://xhyb.xhu.edu.cn/v1/wechat/bindpage-callback"))
        assertFalse(requiresWaterAuthenticationInteraction("https://example.com/v1/wechat/qrcodelogin"))
        assertFalse(requiresWaterAuthenticationInteraction("$WATER_AUTH_ENTRY_URL?next=https://xhyb.xhu.edu.cn/v1/wechat/qrcodelogin"))
    }
}
