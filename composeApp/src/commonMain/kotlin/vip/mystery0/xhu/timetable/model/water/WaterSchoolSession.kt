package vip.mystery0.xhu.timetable.model.water

import kotlinx.serialization.Serializable

/** 仅用于平台安全存储，不进入业务请求头或日志。 */
@Serializable
internal class WaterSchoolSession(
    val value: String,
    val domain: String,
    val path: String,
    val secure: Boolean,
    val httpOnly: Boolean,
    val expiresAtSeconds: Double? = null,
    val sameSite: String? = null,
) {
    fun canRestore(nowSeconds: Double): Boolean =
        domain.removePrefix(".") == HOST && path == "/" &&
                value.isNotBlank() && value.none { it == '\r' || it == '\n' || it == ';' } &&
                (expiresAtSeconds == null || expiresAtSeconds > nowSeconds) &&
                (sameSite == null || sameSite.lowercase() in setOf("lax", "strict", "none"))

    override fun toString(): String = "WaterSchoolSession(<redacted>)"

    companion object {
        const val HOST = "xhyb.xhu.edu.cn"
        const val NAME = "_sop_session_"
        const val STORAGE_KEY = "schoolSessionCookie.v1"
    }
}
