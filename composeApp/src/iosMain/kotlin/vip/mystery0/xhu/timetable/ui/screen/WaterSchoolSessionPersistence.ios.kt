package vip.mystery0.xhu.timetable.ui.screen

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.serialization.json.Json
import platform.Foundation.NSDate
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSHTTPCookieDomain
import platform.Foundation.NSHTTPCookieExpires
import platform.Foundation.NSHTTPCookieName
import platform.Foundation.NSHTTPCookiePath
import platform.Foundation.NSHTTPCookieSecure
import platform.Foundation.NSHTTPCookieValue
import platform.Foundation.timeIntervalSince1970
import platform.WebKit.WKHTTPCookieStore
import platform.WebKit.WKHTTPCookieStoreObserverProtocol
import platform.darwin.NSObject
import vip.mystery0.xhu.timetable.config.store.WaterSecureStore
import vip.mystery0.xhu.timetable.model.water.WaterSchoolSession

/** WKWebView 的会话 Cookie 可能在进程退出后丢失，使用 Keychain 保留学校会话。 */
@OptIn(ExperimentalForeignApi::class)
internal class WaterSchoolSessionPersistence : NSObject(), WKHTTPCookieStoreObserverProtocol {
    private var active = true
    private var observing = false
    private var revision = 0
    private val completions = mutableListOf<() -> Unit>()

    fun restoreBeforeLoading(store: WKHTTPCookieStore, onReady: () -> Unit) {
        store.getAllCookies { cookies ->
            if (!active) return@getAllCookies
            val existing = cookies.orEmpty().filterIsInstance<NSHTTPCookie>().firstOrNull(::isSchoolCookie)
            val saved = runCatching {
                WaterSecureStore.get(WaterSchoolSession.STORAGE_KEY)?.let {
                    Json.decodeFromString<WaterSchoolSession>(it)
                }
            }.getOrNull()
            val now = NSDate().timeIntervalSince1970
            val cookie = if (existing == null && saved?.canRestore(now) == true) {
                val properties = mutableMapOf<Any?, Any>(
                    NSHTTPCookieName to WaterSchoolSession.NAME,
                    NSHTTPCookieValue to saved.value,
                    NSHTTPCookieDomain to saved.domain,
                    NSHTTPCookiePath to saved.path,
                )
                if (saved.secure) properties[NSHTTPCookieSecure] = "TRUE"
                if (saved.httpOnly) properties["HttpOnly"] = "TRUE"
                saved.sameSite?.let { properties["SameSite"] = it }
                saved.expiresAtSeconds?.let {
                    properties[NSHTTPCookieExpires] = NSDate(timeIntervalSince1970 = it)
                }
                NSHTTPCookie.cookieWithProperties(properties)
            } else null
            val begin = {
                if (active) {
                    observing = true
                    store.addObserver(this)
                    checkpoint(store)
                    onReady()
                }
            }
            if (cookie != null) store.setCookie(cookie, completionHandler = { begin() })
            else begin()
        }
    }

    override fun cookiesDidChangeInCookieStore(cookieStore: WKHTTPCookieStore) {
        checkpoint(cookieStore)
    }

    /** 成功回调前完成备份，避免 WebView 被释放导致最后一次 Cookie 更新丢失。 */
    fun checkpoint(store: WKHTTPCookieStore, onComplete: () -> Unit = {}) {
        if (!active) return
        completions.add(onComplete)
        val requestRevision = ++revision
        store.getAllCookies { cookies ->
            if (!active || requestRevision != revision) return@getAllCookies
            val cookie = cookies.orEmpty().filterIsInstance<NSHTTPCookie>().firstOrNull(::isSchoolCookie)
            val snapshot = cookie?.let {
                WaterSchoolSession(it.value, it.domain, it.path, it.secure, it.HTTPOnly,
                    it.expiresDate?.timeIntervalSince1970, it.properties?.get("SameSite") as? String)
            }
            // 学校删除/失效该 Cookie 时同步清除，禁止复活已经撤销的会话。
            runCatching {
                if (snapshot?.canRestore(NSDate().timeIntervalSince1970) == true) {
                    WaterSecureStore.set(WaterSchoolSession.STORAGE_KEY, Json.encodeToString(snapshot))
                } else {
                    WaterSecureStore.remove(WaterSchoolSession.STORAGE_KEY)
                }
            }
            val ready = completions.toList()
            completions.clear()
            ready.forEach { it() }
        }
    }

    fun close(store: WKHTTPCookieStore) {
        active = false
        revision++
        completions.clear()
        if (observing) store.removeObserver(this)
    }

    private fun isSchoolCookie(cookie: NSHTTPCookie): Boolean =
        cookie.name == WaterSchoolSession.NAME &&
                cookie.domain.removePrefix(".") == WaterSchoolSession.HOST && cookie.path == "/"
}
