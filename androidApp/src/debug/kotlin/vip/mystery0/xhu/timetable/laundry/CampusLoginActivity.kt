package vip.mystery0.xhu.timetable.laundry

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.webkit.*
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.*
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryLoginContent
import vip.mystery0.xhu.timetable.ui.theme.NightMode
import vip.mystery0.xhu.timetable.ui.theme.XhuTimetableTheme

/** 授权码始终留在校园进程内存，不进入 Intent、日志或持久化。 */
class CampusLoginActivity : ComponentActivity() {
    companion object { private var webDirectoryConfigured = false }
    private lateinit var client: CampusClient
    private var web: WebView? = null
    private var busy by mutableStateOf(true)
    private var error by mutableStateOf<String?>(null)
    private var webVisible by mutableStateOf(false)
    private var acceptingCallback = false
    private var ready = false
    private var loginUrl: String? = null
    private var pageWatchdog: Job? = null
    private val requestDispatcher get() = CampusLaundryRuntime.dispatcher

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        if (!webDirectoryConfigured && Build.VERSION.SDK_INT >= 28) {
            WebView.setDataDirectorySuffix("campus_login")
            webDirectoryConfigured = true
        }
        client = CampusLaundryRuntime.client(applicationContext)
        val mode = NightMode.entries.firstOrNull { it.name == intent.getStringExtra("night_mode") } ?: NightMode.AUTO
        setContent {
            XhuTimetableTheme(mode) {
                LaundrySystemBars(window)
                LaundryLoginContent(busy, error, { finish() }, ::beginLogin, webVisible) {
                    AndroidView(modifier = Modifier.fillMaxSize(), factory = { context -> WebView(context).also {
                        web = it
                        configureWeb(it)
                        loginUrl?.let(it::loadUrl)
                    } }, onRelease = { view ->
                        if (web === view) web = null
                        view.stopLoading()
                        view.webViewClient = WebViewClient()
                        view.destroy()
                    })
                }
            }
        }
        work {
            val verified = withContext(requestDispatcher) {
                client.initialize(); ready = true
                if (intent.getBooleanExtra("force_login", false)) { client.forgetSession(); false }
                else if (client.hasSession()) { client.verify(); client.allowLoginHandoff(); true }
                else false
            }
            if (verified) verified()
        }
    }

    @android.annotation.SuppressLint("SetJavaScriptEnabled")
    private fun configureWeb(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            useWideViewPort = true
            loadWithOverviewMode = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(view, true)
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
                navigate(request.url, request.isForMainFrame)
            @Deprecated("兼容旧版 WebView")
            override fun shouldOverrideUrlLoading(view: WebView, url: String) = navigate(Uri.parse(url), true)
            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                val uri = Uri.parse(url)
                if (uri.host == "www.alipay.com" && uri.path == "/webviewbridge") {
                    view.stopLoading()
                    navigate(uri, true)
                }
                watchPage(view)
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) failWeb("登录页面加载失败，请检查网络后重试。")
            }
            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                if (request.isForMainFrame && response.statusCode >= 400) failWeb("登录服务暂时不可用，请稍后重试。")
            }
            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: android.net.http.SslError) {
                handler.cancel()
                failWeb("登录页面的安全连接失败，请检查网络后重试。")
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                failWeb("登录页面已停止响应，请重新打开。")
                return true
            }
        }
        view.webChromeClient = WebChromeClient()
    }

    /** 只判断页面是否出现可交互控件，不读取输入值、授权码或网页正文。 */
    private fun watchPage(view: WebView) {
        pageWatchdog?.cancel()
        pageWatchdog = lifecycleScope.launch {
            delay(45000)
            if (!acceptingCallback || !webVisible || web !== view) return@launch
            view.evaluateJavascript("Array.from(document.querySelectorAll('input:not([type=hidden]),button,a[href],[role=button]')).some(e=>e.getClientRects().length>0)") { interactive ->
                if (interactive == "false" && acceptingCallback && web === view) {
                    failWeb("授权页面没有完成跳转，请重试；若仍停在此处，请换用真机登录。")
                }
            }
        }
    }

    private fun navigate(uri: Uri, mainFrame: Boolean): Boolean {
        if (uri.scheme == "https" && uri.host == "www.alipay.com" && uri.path == "/webviewbridge") {
            if (!mainFrame || !acceptingCallback || busy) return true
            val code = uri.getQueryParameter("top_auth_code")
            if (code == null || !code.matches(Regex("[A-Za-z0-9_-]{16,512}")) ||
                uri.getQueryParameter("action") != "taobao_auth_token") {
                failWeb("登录结果无效，请重新登录。")
                return true
            }
            acceptingCallback = false
            pageWatchdog?.cancel()
            web?.stopLoading()
            webVisible = false
            work {
                withContext(requestDispatcher) { client.exchange(code); client.verify(); client.allowLoginHandoff() }
                verified()
            }
            return true
        }
        val host = uri.host
        val allowed = uri.scheme == "https" && host != null &&
            (host == "taobao.com" || host.endsWith(".taobao.com") || host.endsWith(".tmall.com") ||
                host.endsWith(".alipay.com") || host.endsWith(".alicdn.com"))
        if (!allowed && mainFrame) failWeb("请使用登录页中的手机号验证码登录。")
        return !allowed
    }

    private fun failWeb(message: String) {
        pageWatchdog?.cancel()
        acceptingCallback = false
        web?.stopLoading()
        webVisible = false
        error = message
    }

    private fun beginLogin() {
        if (busy) return
        work {
            if (!ready) withContext(requestDispatcher) { client.initialize(); ready = true }
            loginUrl = withContext(requestDispatcher) { client.forgetSession(); client.loginUrl() }
            acceptingCallback = true
            if (webVisible) web?.loadUrl(loginUrl!!)
            webVisible = true
        }
    }

    private fun work(action: suspend () -> Unit) {
        busy = true
        error = null
        lifecycleScope.launch {
            try { action() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { failWeb("登录暂未完成，请检查网络后重试。") }
            finally { busy = false }
        }
    }

    private fun verified() {
        setResult(Activity.RESULT_OK, Intent().putExtra("campus_verified", true))
        finish()
    }

    override fun onDestroy() {
        acceptingCallback = false
        pageWatchdog?.cancel()
        web?.apply { stopLoading(); webViewClient = WebViewClient(); destroy() }
        web = null
        super.onDestroy()
    }
}
