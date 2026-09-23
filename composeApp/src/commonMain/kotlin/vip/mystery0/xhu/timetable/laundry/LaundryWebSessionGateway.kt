package vip.mystery0.xhu.timetable.laundry

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** 一个登录会话可以有首页后台与洗衣页两个 WebView，但每次只由优先级最高者执行查询。 */
class LaundryWebSessionGateway {
    private var nextToken = 0L
    private val clients = mutableMapOf<Long, Int>()
    private val _activeToken = MutableStateFlow<Long?>(null)
    val activeToken: StateFlow<Long?> = _activeToken.asStateFlow()

    fun register(foreground: Boolean): Long {
        val token = ++nextToken
        clients[token] = if (foreground) 1 else 0
        updateActive()
        return token
    }

    fun unregister(token: Long) {
        clients.remove(token)
        updateActive()
    }

    private fun updateActive() {
        _activeToken.value = clients.maxWithOrNull(
            compareBy<Map.Entry<Long, Int>> { it.value }.thenBy { it.key },
        )?.key
    }
}
