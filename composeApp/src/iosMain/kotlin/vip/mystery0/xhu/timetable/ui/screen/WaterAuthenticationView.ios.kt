package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitView
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.readValue
import platform.CoreGraphics.CGRectZero
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSURL
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.NSObject
import org.koin.mp.KoinPlatform
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.water.WaterServiceController

@OptIn(ExperimentalForeignApi::class)
@Composable
internal actual fun WaterAuthenticationView(
    modifier: Modifier,
    onAuthenticated: (openId: String, sessionId: String) -> Unit,
    onError: (String) -> Unit,
) {
    val currentOnAuthenticated by rememberUpdatedState(onAuthenticated)
    val currentOnError by rememberUpdatedState(onError)
    var delivered by remember { mutableStateOf(false) }
    val automaticRecovery = remember {
        KoinPlatform.getKoin().get<WaterServiceController>().uiState.value ==
                WaterUiState.RecoveringAuthentication
    }
    val navigationDelegate = remember {
        WaterNavigationDelegate(
            onNavigationStarted = navigationStarted@{ webView ->
                if (delivered) return@navigationStarted
                val url = webView.URL?.absoluteString ?: return@navigationStarted
                if (!isAllowedWaterAuthenticationUrl(url)) {
                    delivered = true
                    webView.stopLoading()
                    currentOnError("官方认证跳转到了不受信任的地址")
                    return@navigationStarted
                }
                if (automaticRecovery && requiresWaterAuthenticationInteraction(url)) {
                    delivered = true
                    webView.stopLoading()
                    currentOnError("学校登录状态也已失效，需要重新扫码认证")
                }
            },
            onNavigationFinished = navigationFinished@{ webView ->
                if (delivered) return@navigationFinished
                val url = webView.URL?.absoluteString ?: return@navigationFinished
                val openId = extractWaterOpenId(url) ?: return@navigationFinished
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies ->
                    if (delivered) return@getAllCookies
                    val sessionId = cookies
                        ?.asSequence()
                        ?.filterIsInstance<NSHTTPCookie>()
                        ?.firstOrNull { cookie ->
                            cookie.name == "JSESSIONID" &&
                                    cookie.domain.removePrefix(".") == WATER_HOST
                        }
                        ?.value
                        .orEmpty()
                    if (sessionId.isBlank()) {
                        currentOnError("官方页面已完成跳转，但没有建立用水会话")
                        return@getAllCookies
                    }
                    delivered = true
                    currentOnAuthenticated(openId, sessionId)
                }
            },
        )
    }

    UIKitView(
        factory = {
            val configuration = WKWebViewConfiguration().apply {
                websiteDataStore = WKWebsiteDataStore.defaultDataStore()
                defaultWebpagePreferences.allowsContentJavaScript = true
            }
            WKWebView(
                frame = CGRectZero.readValue(),
                configuration = configuration,
            ).apply {
                this.navigationDelegate = navigationDelegate
                allowsBackForwardNavigationGestures = true
                val url = NSURL(string = WATER_AUTH_ENTRY_URL)
                if (url == null) {
                    currentOnError("官方认证地址无效")
                } else if (automaticRecovery) {
                    deleteWaterSessionCookieAndLoad(webView, url)
                } else {
                    loadRequest(NSMutableURLRequest.requestWithURL(url))
                }
            }
        },
        modifier = modifier,
        onRelease = { webView ->
            webView.stopLoading()
            webView.navigationDelegate = null
        },
    )
}

@OptIn(ExperimentalForeignApi::class)
private class WaterNavigationDelegate(
    private val onNavigationStarted: (WKWebView) -> Unit,
    private val onNavigationFinished: (WKWebView) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol {
    override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) {
        onNavigationStarted(webView)
    }

    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
        onNavigationFinished(webView)
    }
}

private fun deleteWaterSessionCookieAndLoad(webView: WKWebView, url: NSURL) {
    val cookieStore = webView.configuration.websiteDataStore.httpCookieStore
    cookieStore.getAllCookies { cookies ->
        val sessionCookies = cookies
            ?.asSequence()
            ?.filterIsInstance<NSHTTPCookie>()
            ?.filter { cookie ->
                cookie.name == "JSESSIONID" &&
                        cookie.domain.removePrefix(".") == WATER_HOST
            }
            ?.toList()
            .orEmpty()
        if (sessionCookies.isEmpty()) {
            webView.loadRequest(NSMutableURLRequest.requestWithURL(url))
            return@getAllCookies
        }
        var remaining = sessionCookies.size
        sessionCookies.forEach { cookie ->
            cookieStore.deleteCookie(cookie) {
                remaining--
                if (remaining == 0) {
                    webView.loadRequest(NSMutableURLRequest.requestWithURL(url))
                }
            }
        }
    }
}

private fun isAllowedWaterAuthenticationUrl(url: String): Boolean {
    if (!url.startsWith("https://")) return false
    val host = url.removePrefix("https://")
        .substringBefore('/')
        .substringBefore(':')
        .lowercase()
    return host in WATER_AUTH_ALLOWED_HOSTS
}

private const val WATER_HOST = "ecard.xhu.edu.cn"

private val WATER_AUTH_ALLOWED_HOSTS = setOf(
    "xhyb.xhu.edu.cn",
    "api.szszcloud.cn",
    "open.weixin.qq.com",
    WATER_HOST,
)
