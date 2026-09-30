package vip.mystery0.xhu.timetable.model.laundry

import io.ktor.http.Url

/** 两端采用相同的二维码来源校验，结果只用于查询设备，不能直接打开网址。 */
object LaundryQrPolicy {
    fun deviceNumber(contents: String): String? = runCatching {
        if (contents.length > 2048) return null
        var uri = Url(contents.trim())
        if (!allowed(uri)) return null
        if (uri.encodedPath == "/app/tmall-xiaoyuan/tmxy-m-share/laundry/deviceDetail") {
            val nested = uri.parameters["result"] ?: return null
            if (nested.length > 2048) return null
            uri = Url(nested)
        }
        if (!allowed(uri) || uri.encodedPath != "/cf" || uri.parameters["biz"].isNullOrEmpty() ||
            uri.parameters["isv"].isNullOrEmpty()) return null
        uri.parameters["id"]?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,128}")) }
    }.getOrNull()

    private fun allowed(uri: Url) = uri.protocol.name.equals("https", ignoreCase = true) &&
        uri.host.equals("share.confong.cn", ignoreCase = true)
}
