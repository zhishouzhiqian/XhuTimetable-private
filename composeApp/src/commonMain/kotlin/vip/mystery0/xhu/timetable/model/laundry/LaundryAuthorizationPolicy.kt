package vip.mystery0.xhu.timetable.model.laundry

import io.ktor.http.Url

data class LaundryAuthorizationNavigation(
    val allowed: Boolean,
    val code: String? = null,
    val error: String? = null,
)

/** 只接受主框架的官方授权回调；授权码不写入日志、路由或持久化。 */
object LaundryAuthorizationPolicy {
    fun navigation(value: String, mainFrame: Boolean): LaundryAuthorizationNavigation {
        if (value.length > 8192) return LaundryAuthorizationNavigation(false)
        val url = runCatching { Url(value) }.getOrNull()
            ?: return LaundryAuthorizationNavigation(false)
        if (url.protocol.name != "https" || url.port != 443 ||
            url.user != null || url.password != null) return LaundryAuthorizationNavigation(false)
        val host = url.host.lowercase()
        if (host == "www.alipay.com" && url.encodedPath == "/webviewbridge") {
            val codes = url.parameters.getAll("top_auth_code")
            val actions = url.parameters.getAll("action")
            val code = codes?.singleOrNull()
            return if (mainFrame && actions?.singleOrNull() == "taobao_auth_token" &&
                code != null && code.matches(Regex("[A-Za-z0-9_-]{16,512}"))) {
                LaundryAuthorizationNavigation(false, code)
            } else LaundryAuthorizationNavigation(false, error = "登录结果无效，请重新登录。")
        }
        val allowed = listOf("taobao.com", "tmall.com", "alipay.com", "alicdn.com").any {
            host == it || host.endsWith(".$it")
        }
        return LaundryAuthorizationNavigation(allowed,
            error = if (!allowed && mainFrame) "请使用登录页中的手机号验证码登录。" else null)
    }

    /** 只唤起现有收银台协议使用的官方微信小程序；付款仍须查询服务端。 */
    fun acceptsWechat(value: String): Boolean {
        if (value.length > 8192) return false
        val url = runCatching { Url(value) }.getOrNull() ?: return false
        return url.protocol.name == "weixin" && url.host == "dl" &&
            url.user == null && url.password == null && url.specifiedPort == 0 &&
            url.encodedPath == "/business/" &&
            url.parameters.getAll("appid")?.singleOrNull() == "wx48eea1ea40d67ab0" &&
            url.parameters.getAll("path")?.singleOrNull() == "pages/commonAggregateCashier/miniAppPay/index" &&
            url.parameters.getAll("env_version")?.singleOrNull() == "release" &&
            !url.parameters.getAll("query")?.singleOrNull().isNullOrBlank()
    }
}

/** 原生返回、取消和晚到回调竞争时，仅消费当前操作一次。由主线程访问。 */
class LaundryNativeRequestGuard {
    private var sequence = 0L
    private var current: Long? = null

    fun begin(): Long {
        check(current == null) { "原生页面仍在显示" }
        return (++sequence).also { current = it }
    }

    fun finish(id: Long): Boolean {
        if (current != id) return false
        current = null
        return true
    }
}
