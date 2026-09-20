package vip.mystery0.xhu.timetable.model.water

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

@Serializable
data class WaterCredentials(
    val openId: String = "",
    val sessionId: String = "",
    val posCode: String = "",
    val orgId: String = "2",
) {
    val authenticated: Boolean
        get() = sessionId.isNotBlank()

    val canQueryBalance: Boolean
        get() = openId.isNotBlank()

    val bound: Boolean
        get() = posCode.matches(Regex("\\d{6}")) && orgId.isNotBlank()

    val configured: Boolean
        get() = authenticated && bound

    fun normalized(): WaterCredentials = copy(
        openId = openId.trim(),
        sessionId = sessionId.trim()
            .removePrefix("JSESSIONID=")
            .substringBefore(';'),
        posCode = posCode.trim(),
        orgId = orgId.trim(),
    )

    fun withAuthentication(openId: String, sessionId: String): WaterCredentials = copy(
        openId = openId,
        sessionId = sessionId,
    ).normalized()
}

enum class WaterAuthenticationSource { SchoolPage, PerfectCampus }

data class WaterAuthenticationRequest(
    val entryUrl: String,
    val source: WaterAuthenticationSource,
    val replaceSessionCookie: Boolean = false,
) {
    val allowsEmptyOpenId: Boolean
        get() = source == WaterAuthenticationSource.PerfectCampus
}

sealed interface PerfectCampusLoginState {
    data object Idle : PerfectCampusLoginState
    data object SendingSms : PerfectCampusLoginState
    data object SmsSent : PerfectCampusLoginState
    data object Verifying : PerfectCampusLoginState
    data class Error(
        val message: String,
        val canSubmitCode: Boolean,
    ) : PerfectCampusLoginState
}

@Serializable
data class WaterCommandRequest(
    @SerialName("openid")
    val openId: String,
    @SerialName("poscode")
    val posCode: String,
    @SerialName("orgid")
    val orgId: String,
)

@Serializable
data class WaterDeviceListRequest(
    @SerialName("openid")
    val openId: String,
    @SerialName("orgid")
    val orgId: String,
)

@Serializable
data class WaterDeviceListResponse(
    val success: Boolean = false,
    val message: String? = null,
    val resultData: WaterDeviceListResultData? = null,
)

@Serializable
data class WaterDeviceListResultData(
    val result: String = "",
    val message: String? = null,
    val data: List<WaterDevice> = emptyList(),
)

@Serializable
data class WaterDevice(
    @SerialName("poscode")
    val posCode: String = "",
    @SerialName("orgid")
    val orgId: String = "",
    @SerialName("posname")
    val name: String = "",
)

@Serializable
data class WaterHomeRequest(@SerialName("openid") val openId: String)

@Serializable
data class WaterHomeResponse(val success: Boolean = false, val message: String? = null, val data: WaterHomeData? = null)

@Serializable
data class WaterHomeData(@SerialName("usertype") val userType: String = "")

@Serializable
data class WaterBalanceResponse(val success: Boolean = false, val message: String? = null, val data: WaterBalanceData? = null)

@Serializable
data class WaterBalanceData(@SerialName("cardbal") val cardBalance: String = "")

@Serializable
data class WaterUseRecordResponse(val success: Boolean = false, val message: String? = null, val resultData: WaterUseRecordResultData? = null)

@Serializable
data class WaterUseRecordResultData(val result: String = "", val message: String? = null, val data: List<WaterUseRecord> = emptyList())

@Serializable
data class WaterUseRecord(
    @SerialName("begintimestr") val beginTime: String = "",
    @SerialName("txamt") val amountFen: Long? = null,
    @SerialName("sumtime") val durationSeconds: Long? = null,
    @SerialName("sumuse") val waterUsage: String = "",
    @SerialName("chargingtype") val chargingType: String = "",
    @SerialName("poscode") val posCode: String = "",
)

@Serializable
data class WaterRawResponse(
    val success: Boolean = false,
    val message: String? = null,
    val resultData: JsonElement? = null,
    val wcrList: JsonElement? = null,
)

data class WaterOverview(val balanceCents: Long?, val records: List<WaterUseRecord>, val running: Boolean)

sealed interface WaterStartDecision {
    data class Ready(val balanceCents: Long) : WaterStartDecision
    data class LowBalance(val balanceCents: Long) : WaterStartDecision
    data object BalanceUnavailable : WaterStartDecision
}

enum class WaterQuickAction { NavigateToDetails, Start, Stop, Wait }

fun decideWaterQuickAction(
    credentials: WaterCredentials?,
    state: WaterUiState,
    running: Boolean,
): WaterQuickAction {
    if (state == WaterUiState.Loading || state == WaterUiState.Authenticating ||
        state == WaterUiState.RecoveringAuthentication ||
        state == WaterUiState.Starting || state == WaterUiState.Stopping
    ) return WaterQuickAction.Wait
    if (credentials?.configured != true || state == WaterUiState.AuthExpired ||
        state == WaterUiState.NotAuthenticated || state == WaterUiState.NotBound
    ) return WaterQuickAction.NavigateToDetails
    return if (running) WaterQuickAction.Stop else WaterQuickAction.Start
}

@Serializable
data class WaterCommandResponse(
    val success: Boolean = false,
    val message: String? = null,
    val resultData: WaterResultData? = null,
)

@Serializable
data class WaterResultData(
    val result: String = "",
    val message: String? = null,
)

sealed interface WaterUiState {
    data object Loading : WaterUiState
    data object NotAuthenticated : WaterUiState
    data object Authenticating : WaterUiState
    data object RecoveringAuthentication : WaterUiState
    data object NotBound : WaterUiState
    data object Ready : WaterUiState
    data object Starting : WaterUiState
    data class Running(val message: String) : WaterUiState
    data object Stopping : WaterUiState
    data object AuthExpired : WaterUiState
    data class Error(
        val type: WaterErrorType,
        val message: String,
    ) : WaterUiState
}

enum class WaterErrorType {
    Network,
    Business,
    MissingParameters,
    UnknownResponse,
}

fun parseYuanToCents(value: String): Long? {
    val normalized = value.trim().removePrefix("¥").removePrefix("￥")
    if (normalized.isBlank() || normalized.startsWith('-')) return null
    val parts = normalized.split('.')
    if (parts.size > 2 || parts[0].any { !it.isDigit() }) return null
    val fraction = parts.getOrNull(1).orEmpty()
    if (fraction.length > 2 || fraction.any { !it.isDigit() }) return null
    val yuan = parts[0].toLongOrNull() ?: return null
    val fen = when (fraction.length) { 0 -> 0; 1 -> fraction.toLong() * 10; else -> fraction.toLong() }
    if (yuan > (Long.MAX_VALUE - fen) / 100) return null
    return yuan * 100 + fen
}

fun formatWaterCents(value: Long): String = "${value / 100}.${(value % 100).toString().padStart(2, '0')}"

fun calculateWaterCost(startCents: Long?, endCents: Long?): Long? {
    if (startCents == null || endCents == null || endCents > startCents) return null
    return startCents - endCents
}
