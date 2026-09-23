package vip.mystery0.xhu.timetable.laundry

private val laundryAllowedDomains = setOf(
    "confong.cn",
    "taobao.com",
    "tmall.com",
    "tb.cn",
    "alicdn.com",
    "alipay.com",
    "alipayobjects.com",
)

internal fun isAllowedLaundryHost(host: String?): Boolean {
    val normalized = host?.lowercase() ?: return false
    return laundryAllowedDomains.any { normalized == it || normalized.endsWith(".$it") }
}
