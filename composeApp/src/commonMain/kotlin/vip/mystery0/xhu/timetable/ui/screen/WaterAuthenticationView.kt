package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import vip.mystery0.xhu.timetable.model.water.WaterAuthenticationRequest

internal const val WATER_AUTH_ENTRY_URL = "https://xhyb.xhu.edu.cn/short/hcXum6gj7Lc"
internal const val WATER_AUTH_ORIGIN = "https://ecard.xhu.edu.cn"

@Composable
internal expect fun WaterAuthenticationView(
    modifier: Modifier,
    request: WaterAuthenticationRequest,
    onAuthenticated: (openId: String, sessionId: String) -> Unit,
    onError: (String) -> Unit,
)

internal fun extractWaterOpenId(url: String): String? {
    if (url.substringBefore('#').trimEnd('/') != WATER_AUTH_ORIGIN) return null
    val fragment = url.substringAfter('#', missingDelimiterValue = "")
    val query = fragment.substringAfter('?', missingDelimiterValue = "")
    return query.split('&')
        .asSequence()
        .mapNotNull { parameter ->
            val parts = parameter.split('=', limit = 2)
            parts.takeIf { it.size == 2 }?.let { it[0] to it[1] }
        }
        .firstOrNull { it.first == "openid" }
        ?.second
        ?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{64}")) }
}

internal fun extractWaterSessionId(cookieHeader: String?): String? = cookieHeader
    ?.split(';')
    ?.asSequence()
    ?.map { it.trim().split('=', limit = 2) }
    ?.firstOrNull { it.size == 2 && it[0] == "JSESSIONID" }
    ?.get(1)
    ?.takeIf(String::isNotBlank)

internal fun requiresWaterAuthenticationInteraction(url: String): Boolean {
    val originAndPath = url.substringBefore('?').substringBefore('#').trimEnd('/')
    // OAuth 入口可能继续自动跳转，不能仅凭进入授权链就认定必须交互。
    // 未识别的停留页面由恢复流程的总超时兜底。
    return originAndPath == "https://xhyb.xhu.edu.cn/v1/wechat/qrcodelogin" ||
            originAndPath == "https://xhyb.xhu.edu.cn/v1/wechat/bindpage"
}
