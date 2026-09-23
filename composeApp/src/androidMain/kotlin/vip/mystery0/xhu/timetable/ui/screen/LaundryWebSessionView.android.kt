package vip.mystery0.xhu.timetable.ui.screen

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.io.ByteArrayInputStream
import vip.mystery0.xhu.timetable.laundry.LaundryServiceController
import vip.mystery0.xhu.timetable.laundry.isAllowedLaundryHost
import vip.mystery0.xhu.timetable.model.laundry.LaundryPhase
import vip.mystery0.xhu.timetable.model.laundry.LaundryWebCommand

actual val isLaundryServiceSupported: Boolean = true

@SuppressLint("SetJavaScriptEnabled")
@Composable
internal actual fun LaundryWebSessionView(
    modifier: Modifier,
    controller: LaundryServiceController,
    loginMode: Boolean,
    foreground: Boolean,
) {
    val command by controller.webCommand.collectAsState()
    val uiState by controller.uiState.collectAsState()
    val lifecycleOwner = LocalLifecycleOwner.current
    var resumed by remember(lifecycleOwner) {
        mutableStateOf(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, _ ->
            resumed = lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val activeToken by controller.webSessionGateway.activeToken.collectAsState()
    val token = remember(controller, foreground) {
        controller.webSessionGateway.register(foreground)
    }
    DisposableEffect(controller, token) {
        onDispose { controller.webSessionGateway.unregister(token) }
    }
    val currentLoginMode by rememberUpdatedState(loginMode)
    var webView by remember { mutableStateOf<WebView?>(null) }
    var runtimeReady by remember { mutableStateOf(false) }
    var loginRequested by remember { mutableStateOf(false) }
    var loginPageVisited by remember { mutableStateOf(false) }
    val bridge = remember(controller) { LaundryWebMessageListener(controller) }

    AndroidView(
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.cacheMode = WebSettings.LOAD_DEFAULT
                settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                val sessionWebView = this
                CookieManager.getInstance().apply {
                    setAcceptCookie(true)
                    setAcceptThirdPartyCookies(sessionWebView, true)
                }
                if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
                    WebViewCompat.addWebMessageListener(
                        this,
                        JS_BRIDGE_NAME,
                        setOf("https://share.confong.cn"),
                        bridge,
                    )
                } else {
                    controller.onRuntimeUnsupported()
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(
                        view: WebView,
                        request: WebResourceRequest,
                    ): WebResourceResponse? = if (isAllowedLaundryUrl(request.url)) null else
                        WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(byteArrayOf()))

                    override fun shouldOverrideUrlLoading(
                        view: WebView,
                        request: WebResourceRequest,
                    ): Boolean {
                        if (isAllowedLaundryUrl(request.url)) return false
                        if (request.isForMainFrame) {
                            controller.onWebError(
                                command?.id ?: return true,
                                "官方登录跳转到了不受信任的地址",
                                false,
                            )
                        }
                        return true
                    }

                    override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                        runtimeReady = false
                        val host = url?.let(Uri::parse)?.host
                        if (currentLoginMode && host != null && !isConfongHost(host)) {
                            loginPageVisited = true
                        }
                    }

                    override fun onPageFinished(view: WebView, url: String?) {
                        val uri = url?.let(Uri::parse)
                        runtimeReady = uri?.scheme == "https" && uri.host == "share.confong.cn"
                        if (runtimeReady && currentLoginMode && loginPageVisited) {
                            loginPageVisited = false
                            CookieManager.getInstance().flush()
                            controller.checkSession(afterLogin = true)
                        }
                    }

                    override fun onReceivedError(
                        view: WebView,
                        request: WebResourceRequest,
                        error: WebResourceError,
                    ) {
                        if (request.isForMainFrame) {
                            command?.id?.let {
                                controller.onWebError(it, "天猫校园页面加载失败", false)
                            }
                        }
                    }
                }
                webView = this
                loadUrl(LAUNDRY_ENTRY_URL)
            }
        },
        update = { view ->
            webView = view
            if (loginMode && !loginRequested) {
                loginRequested = true
                loginPageVisited = false
                view.loadUrl(LAUNDRY_LOGIN_URL)
            } else if (!loginMode) {
                loginRequested = false
            }
        },
        modifier = modifier,
        onRelease = { view ->
            runtimeReady = false
            webView = null
            view.stopLoading()
            view.webViewClient = WebViewClient()
            view.destroy()
        },
    )

    LaunchedEffect(command, runtimeReady, webView, activeToken) {
        val pending = command ?: return@LaunchedEffect
        val view = webView ?: return@LaunchedEffect
        if (!runtimeReady || activeToken != token) return@LaunchedEffect
        bridge.activeCommandId = pending.id
        view.evaluateJavascript(buildLaundryScript(pending), null)
    }

    LaunchedEffect(activeToken, token, resumed, uiState.phase, uiState.refreshing) {
        if (activeToken != token || !resumed || uiState.phase != LaundryPhase.Running || uiState.refreshing) return@LaunchedEffect
        delay(30_000)
        controller.refreshOrders()
    }
}

private class LaundryWebMessageListener(
    private val controller: LaundryServiceController,
) : WebViewCompat.WebMessageListener {
    @Volatile
    var activeCommandId: Long = -1L

    override fun onPostMessage(
        view: WebView,
        message: WebMessageCompat,
        sourceOrigin: Uri,
        isMainFrame: Boolean,
        replyProxy: JavaScriptReplyProxy,
    ) {
        if (!isMainFrame || sourceOrigin.scheme != "https" ||
            sourceOrigin.host != "share.confong.cn" ||
            view.url?.let(Uri::parse)?.host != "share.confong.cn"
        ) return
        if (message.type != WebMessageCompat.TYPE_STRING) return
        val raw = message.data ?: return
        if (raw.length > 100_000) return
        val envelope = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val id = envelope.optLong("id", -1)
        if (id != activeCommandId) return
        when (envelope.optString("kind")) {
            "session" -> controller.onSessionResult(id, envelope.optBoolean("loggedIn"))
            "orders" -> controller.onOrdersResult(id, envelope.optString("payload", "[]"))
            "failure" -> {
                val expired = envelope.optBoolean("authenticationExpired")
                controller.onWebError(
                    id,
                    if (expired) "天猫校园登录已失效" else "暂时无法获取洗衣状态",
                    expired,
                )
            }
        }
    }
}

private fun buildLaundryScript(command: LaundryWebCommand): String {
    val action = when (command) {
        is LaundryWebCommand.CheckSession -> """
            (async function() {
              var result;
              for (var attempt = 0; attempt < ${if (command.afterLogin) 3 else 1}; attempt++) {
                if (attempt > 0) await new Promise(function(resolve) { setTimeout(resolve, 1000); });
                result = await request('mtop.tmall.campus.member.user.login', {});
                if (deepValue(result, ['doHaveLogin']) === true) {
                  send('session', {loggedIn: true});
                  return;
                }
              }
              send('session', {loggedIn: false});
            })().catch(function(error) {
              var reason = error && error.ret ? String(error.ret) : '';
              if (reason.indexOf('SESSION_EXPIRED') >= 0 || reason.indexOf('NEED_LOGIN') >= 0) {
                send('session', {loggedIn: false});
              } else {
                fail(error);
              }
            });
        """
        is LaundryWebCommand.QueryOrders -> """
            request('mtop.tmall.campus.share.applet.general.user.urgent.order.list', {
              requestType: 'USER_URGENT_ORDER_LIST',
              requestJson: JSON.stringify({isv: 'CAMPUS', businessType: 'WASH_AND_CARE'})
            }).then(async function(result) {
              var list = deepArray(result);
              var normalized = await Promise.all(list.map(async function(item) {
                var detailRequest = compact({
                  bizOrderId: deepValue(item, ['bizOrderId', 'orderId']),
                  mixBuyerId: deepValue(item, ['mixBuyerId']),
                  isvOrderId: deepValue(item, ['isvOrderId']),
                  isv: deepValue(item, ['isv']) || 'CAMPUS',
                  businessType: deepValue(item, ['businessType']) || 'WASH_AND_CARE'
                });
                var detail = item;
                if (detailRequest.bizOrderId || detailRequest.isvOrderId) {
                  try {
                    detail = await request('mtop.tmall.campus.share.applet.general.order.detail.get', {
                      requestType: 'ORDER_DETAIL_GET',
                      requestJson: JSON.stringify(detailRequest)
                    });
                  } catch (_) { detail = item; }
                }
                var source = {detail: detail, summary: item};
                var expected = deepValue(source, ['actualExpectedEndTime', 'expectedEndTime']);
                var expectedMillis = expected == null ? null : Number(expected);
                if (!Number.isFinite(expectedMillis)) expectedMillis = Date.parse(String(expected));
                if (Number.isFinite(expectedMillis) && expectedMillis < 100000000000) expectedMillis *= 1000;
                return compact({
                  orderId: String(deepValue(source, ['bizOrderId', 'orderId']) || ''),
                  isvOrderId: String(deepValue(source, ['isvOrderId']) || ''),
                  deviceId: String(deepValue(source, ['deviceId', 'deviceCode', 'resNo']) || ''),
                  deviceName: String(deepValue(source, ['deviceName', 'washDeviceName', 'resName']) || '洗衣机'),
                  deviceType: String(deepValue(source, ['washDeviceType', 'deviceType']) || ''),
                  status: String(deepValue(source, ['userOrderDetailStatus', 'orderStatus', 'status']) || ''),
                  expectedEndAtEpochMillis: Number.isFinite(expectedMillis) ? expectedMillis : null
                });
              }));
              send('orders', {payload: JSON.stringify(normalized)});
            }).catch(fail);
        """
    }
    return """
        (function() {
          var commandId = ${command.id};
          var bridge = window.$JS_BRIDGE_NAME;
          function send(kind, fields) {
            bridge.postMessage(JSON.stringify(Object.assign({id: commandId, kind: kind}, fields)));
          }
          function fail(error) {
            var text = '';
            try { text = JSON.stringify(error || {}); } catch (_) {}
            send('failure', {authenticationExpired: text.indexOf('SESSION_EXPIRED') >= 0 || text.indexOf('NEED_LOGIN') >= 0});
          }
          function request(api, data) {
            return new Promise(function(resolve, reject) {
              var attempts = 0;
              function run() {
                if (!window.lib || !window.lib.mtop || !window.lib.mtop.request) {
                  if (++attempts < 50) { setTimeout(run, 100); return; }
                  reject({ret: ['RUNTIME_NOT_READY']});
                  return;
                }
                var mtop = window.lib.mtop;
                mtop.config.prefix = 'acs-m';
                mtop.config.subDomain = '';
                mtop.config.mainDomain = 'confong.cn';
                mtop.request(
                  {api: api, v: '1.0', type: 'POST', dataType: 'json', H5Request: true, data: data},
                  function(result) {
                    var ret = Array.isArray(result.ret) ? result.ret.join(',') : String(result.ret || '');
                    if (ret && ret.indexOf('SUCCESS') < 0) reject(result);
                    else resolve(result);
                  },
                  reject
                );
              }
              run();
            });
          }
          function deepValue(value, keys) {
            for (var i = 0; i < keys.length; i++) {
              var found = deepKey(value, keys[i], []);
              if (found != null) return found;
            }
            return null;
          }
          function deepKey(value, key, seen) {
            if (value == null || typeof value !== 'object') return null;
            if (seen.indexOf(value) >= 0) return null;
            seen.push(value);
            if (Object.prototype.hasOwnProperty.call(value, key) && value[key] != null) return value[key];
            var names = Object.keys(value);
            for (var j = 0; j < names.length; j++) {
              var found = deepKey(value[names[j]], key, seen);
              if (found != null) return found;
            }
            return null;
          }
          function deepArray(value) {
            var seen = [];
            function search(node, depth) {
              if (depth > 8 || node == null || typeof node !== 'object') return null;
              if (seen.indexOf(node) >= 0) return null;
              seen.push(node);
              if (Array.isArray(node)) {
                if (node.some(function(item) {
                  return item && typeof item === 'object' &&
                    (item.bizOrderId != null || item.orderId != null || item.isvOrderId != null);
                })) return node;
              }
              var keys = Object.keys(node);
              for (var i = 0; i < keys.length; i++) {
                var found = search(node[keys[i]], depth + 1);
                if (found) return found;
              }
              return null;
            }
            var direct = search(value, 0);
            if (direct) return direct;
            return [];
          }
          function compact(value) {
            Object.keys(value).forEach(function(key) {
              if (value[key] == null || value[key] === '') delete value[key];
            });
            return value;
          }
          $action
        })();
    """.trimIndent()
}

private fun isAllowedLaundryUrl(uri: Uri): Boolean {
    if (uri.scheme != "https") return false
    return isAllowedLaundryHost(uri.host)
}

private fun isConfongHost(host: String): Boolean =
    host == "confong.cn" || host.endsWith(".confong.cn")

private const val JS_BRIDGE_NAME = "XgkbLaundryBridge"
private const val LAUNDRY_ENTRY_URL =
    "https://share.confong.cn/app/tmall-xiaoyuan/tmxy-m-share/laundry"
private const val LAUNDRY_LOGIN_URL =
    "https://login.m.taobao.com/login.htm?redirectURL=https%3A%2F%2Fshare.confong.cn%2Fapp%2Ftmall-xiaoyuan%2Ftmxy-m-share%2Flaundry"
