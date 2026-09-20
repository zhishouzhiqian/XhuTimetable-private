package vip.mystery0.xhu.timetable.ui.screen

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import vip.mystery0.xhu.timetable.model.water.WaterAuthenticationRequest

@SuppressLint("SetJavaScriptEnabled")
@Composable
internal actual fun WaterAuthenticationView(
    modifier: Modifier,
    request: WaterAuthenticationRequest,
    onAuthenticated: (openId: String, sessionId: String) -> Unit,
    onError: (String) -> Unit,
) {
    val currentOnAuthenticated by rememberUpdatedState(onAuthenticated)
    val currentOnError by rememberUpdatedState(onError)
    var delivered by remember { mutableStateOf(false) }

    AndroidView(
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.cacheMode = WebSettings.LOAD_DEFAULT
                val webView = this
                CookieManager.getInstance().apply {
                    setAcceptCookie(true)
                    setAcceptThirdPartyCookies(webView, true)
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        view: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        val uri = request.url
                        val allowed = uri.scheme == "https" && uri.host in ALLOWED_AUTH_HOSTS
                        if (!allowed && request.isForMainFrame) {
                            currentOnError("官方认证跳转到了不受信任的地址")
                        }
                        return !allowed
                    }

                    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                        super.onPageStarted(view, url, favicon)
                        captureCredentials(url)
                    }

                    override fun onPageFinished(view: WebView, url: String?) {
                        super.onPageFinished(view, url)
                        captureCredentials(url)
                    }

                    override fun onReceivedError(
                        view: WebView,
                        request: WebResourceRequest,
                        error: WebResourceError,
                    ) {
                        super.onReceivedError(view, request, error)
                        if (request.isForMainFrame && !delivered) {
                            currentOnError("官方认证页面加载失败：${error.description}")
                        }
                    }

                    private fun captureCredentials(url: String?) {
                        if (delivered || url == null) return
                        val openId = extractWaterOpenId(url)
                            ?: if (request.allowsEmptyOpenId && url.startsWith(WATER_AUTH_ORIGIN)) "" else return
                        val sessionId = extractWaterSessionId(
                            CookieManager.getInstance().getCookie(WATER_AUTH_ORIGIN),
                        ) ?: return
                        delivered = true
                        CookieManager.getInstance().flush()
                        currentOnAuthenticated(openId, sessionId)
                    }
                }
                val cookieManager = CookieManager.getInstance()
                if (request.replaceSessionCookie) {
                    cookieManager.setCookie(WATER_AUTH_ORIGIN, "JSESSIONID=; Max-Age=0; Path=/") {
                        cookieManager.flush()
                        loadUrl(request.entryUrl)
                    }
                } else {
                    loadUrl(request.entryUrl)
                }
            }
        },
        modifier = modifier,
        onRelease = { webView ->
            webView.stopLoading()
            webView.webViewClient = WebViewClient()
            webView.destroy()
        },
    )
}

private val ALLOWED_AUTH_HOSTS = setOf(
    "xhyb.xhu.edu.cn",
    "api.szszcloud.cn",
    "open.weixin.qq.com",
    "open.17wanxiao.com",
    "ecard.xhu.edu.cn",
)
