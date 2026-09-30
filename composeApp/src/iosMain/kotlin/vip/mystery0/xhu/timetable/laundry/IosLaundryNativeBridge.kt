package vip.mystery0.xhu.timetable.laundry

import kotlinx.coroutines.*
import kotlin.coroutines.resume
import vip.mystery0.xhu.timetable.model.laundry.LaundryAuthorizationPolicy
import vip.mystery0.xhu.timetable.model.laundry.LaundryNativeRequestGuard
import vip.mystery0.xhu.timetable.repository.LaundryGateway

/** 校园客户端须提供当次授权地址，并转换、持久化、核验当前账号的会话。 */
interface IosLaundryLoginGateway : LaundryGateway {
    suspend fun authorizationUrl(forceLogin: Boolean): String
    suspend fun exchangeAuthorization(code: String)
}

/** Swift 只管理原生页面；不处理校园会话、签名或付款结果。 */
interface IosLaundryNativeUi {
    fun authorize(url: String, requestId: Long)
    fun scan(requestId: Long)
    fun openWechat(uri: String, requestId: Long)
    fun cancel(requestId: Long)
}

object IosLaundryNativeBridge {
    private var ui: IosLaundryNativeUi? = null
    private val guard = LaundryNativeRequestGuard()
    private var pending: CancellableContinuation<IosLaundryScanResult>? = null
    private val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun install(ui: IosLaundryNativeUi) {
        check(this.ui == null) { "原生洗衣桥接只能初始化一次" }
        this.ui = ui
    }

    /** Swift 在主线程返回；旧页面的结果不能交给新页面。 */
    fun complete(requestId: Long, contents: String?, error: String?) {
        if (!guard.finish(requestId)) return
        val continuation = pending
        pending = null
        if (continuation?.isActive == true) continuation.resume(IosLaundryScanResult(contents, error))
    }

    private suspend fun awaitResult(show: (IosLaundryNativeUi, Long) -> Unit): IosLaundryScanResult =
        withContext(Dispatchers.Main.immediate) {
            val native = checkNotNull(ui) { "原生洗衣页面未初始化" }
            suspendCancellableCoroutine { continuation ->
                val id = guard.begin()
                pending = continuation
                continuation.invokeOnCancellation {
                    cleanup.launch {
                        if (guard.finish(id)) {
                            pending = null
                            native.cancel(id)
                        }
                    }
                }
                try { if (continuation.isActive) show(native, id) }
                catch (_: Exception) {
                    native.cancel(id)
                    complete(id, null, "暂时无法打开页面，请重试。")
                }
            }
        }

    internal suspend fun authorize(url: String): IosLaundryScanResult {
        require(LaundryAuthorizationPolicy.navigation(url, true).allowed) { "授权地址无效" }
        return awaitResult { native, id -> native.authorize(url, id) }
    }

    internal suspend fun scan(): IosLaundryScanResult = awaitResult { native, id -> native.scan(id) }

    internal suspend fun openWechat(uri: String): String? {
        if (!LaundryAuthorizationPolicy.acceptsWechat(uri)) return "付款链接无效，订单已保留。"
        return awaitResult { native, id -> native.openWechat(uri, id) }.error
    }
}

internal class IosCampusLaundryPresenter(private val client: IosLaundryLoginGateway) : IosLaundryPresenter {
    override suspend fun login(forceLogin: Boolean): Boolean {
        val result = IosLaundryNativeBridge.authorize(client.authorizationUrl(forceLogin))
        result.error?.let { throw IllegalStateException(it) }
        val code = result.contents ?: return false
        client.exchangeAuthorization(code)
        client.verify()
        return true
    }

    override suspend fun scan(): IosLaundryScanResult = IosLaundryNativeBridge.scan()
    override suspend fun openWechat(uri: String): String? = IosLaundryNativeBridge.openWechat(uri)
}
