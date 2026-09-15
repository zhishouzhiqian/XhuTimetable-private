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
    val navigationDelegate = remember {
        WaterNavigationDelegate(
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
    private val onNavigationFinished: (WKWebView) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol {
    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
        onNavigationFinished(webView)
    }
}

private const val WATER_HOST = "ecard.xhu.edu.cn"
