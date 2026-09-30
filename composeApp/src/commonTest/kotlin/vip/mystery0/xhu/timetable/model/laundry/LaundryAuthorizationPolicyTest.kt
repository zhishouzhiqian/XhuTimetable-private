package vip.mystery0.xhu.timetable.model.laundry

import kotlin.test.*

class LaundryAuthorizationPolicyTest {
    private val code = "test_authorization_123456"
    private val callback = "https://www.alipay.com/webviewbridge?action=taobao_auth_token&top_auth_code=$code"
    private val wechat = "weixin://dl/business/?appid=wx48eea1ea40d67ab0" +
        "&path=pages/commonAggregateCashier/miniAppPay/index&query=bizOrderId%3Dtest&env_version=release"

    @Test fun callbackOnlyAcceptedFromMainFrame() {
        val result = LaundryAuthorizationPolicy.navigation(callback, true)
        assertFalse(result.allowed)
        assertEquals(code, result.code)
        assertNull(LaundryAuthorizationPolicy.navigation(callback, false).code)
    }

    @Test fun invalidOrAmbiguousCallbacksCannotEstablishSession() {
        listOf(callback + "&top_auth_code=another_authorization_123", callback + "&action=other",
            callback.replace(code, "short"), callback.replace("taobao_auth_token", "other"),
            callback.replace("www.alipay.com", "www.alipay.com.example.invalid"),
            callback.replace("https:", "http:"), callback.replace("www.alipay.com", "user@www.alipay.com"),
            callback.replace("www.alipay.com", "www.alipay.com:8443")).forEach {
            assertNull(LaundryAuthorizationPolicy.navigation(it, true).code)
        }
    }

    @Test fun navigationRequiresOfficialHttpsOrigin() {
        assertTrue(LaundryAuthorizationPolicy.navigation("https://havanalogin.taobao.com/taobao_oauth_common.htm", true).allowed)
        assertTrue(LaundryAuthorizationPolicy.navigation("https://login.tmall.com/", true).allowed)
        listOf("https://taobao.com.example.invalid/", "javascript:alert(1)", "file:///test",
            "https://taobao.com@evil.invalid/", "https://evil.invalid/?next=https://taobao.com",
            "https://taobao.com/" + "x".repeat(8192)).forEach {
            assertFalse(LaundryAuthorizationPolicy.navigation(it, true).allowed)
        }
    }

    @Test fun paymentBridgeOnlyLaunchesKnownWechatRoute() {
        assertTrue(LaundryAuthorizationPolicy.acceptsWechat(wechat))
        listOf(wechat.replace("wx48eea1ea40d67ab0", "unknown"), wechat + "&appid=unknown",
            wechat.replace("/business/", "/other/"), wechat.replace("weixin:", "https:"),
            wechat.replace("weixin://dl", "weixin://user@dl"), wechat.replace("weixin://dl", "weixin://dl:123"),
            wechat.replace("miniAppPay/index", "other/index"), wechat.replace("release", "develop"),
            wechat.replace("bizOrderId%3Dtest", "")).forEach { assertFalse(LaundryAuthorizationPolicy.acceptsWechat(it)) }
    }

    @Test fun nativeCancellationRejectsLateCallbackAndDuplicateResults() {
        val guard = LaundryNativeRequestGuard()
        val first = guard.begin()
        assertFailsWith<IllegalStateException> { guard.begin() }
        assertTrue(guard.finish(first))
        assertFalse(guard.finish(first))
        val second = guard.begin()
        assertFalse(guard.finish(first))
        assertTrue(guard.finish(second))
    }
}
