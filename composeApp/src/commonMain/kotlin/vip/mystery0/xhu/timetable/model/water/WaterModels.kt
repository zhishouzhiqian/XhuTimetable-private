package vip.mystery0.xhu.timetable.model.water

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class WaterCredentials(
    val openId: String = "",
    val sessionId: String = "",
    val posCode: String = "",
    val orgId: String = "2",
) {
    val configured: Boolean
        get() = openId.isNotBlank() &&
                sessionId.isNotBlank() &&
                posCode.matches(Regex("\\d{6}")) &&
                orgId.isNotBlank()

    fun normalized(): WaterCredentials = copy(
        openId = openId.trim(),
        sessionId = sessionId.trim()
            .removePrefix("JSESSIONID=")
            .substringBefore(';'),
        posCode = posCode.trim(),
        orgId = orgId.trim(),
    )
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
data class WaterCommandResponse(
    val success: Boolean = false,
    val message: String = "",
    val resultData: WaterResultData? = null,
)

@Serializable
data class WaterResultData(
    val result: String = "",
    val message: String = "",
)

sealed interface WaterUiState {
    data object Loading : WaterUiState
    data object NotBound : WaterUiState
    data object Ready : WaterUiState
    data object Starting : WaterUiState
    data class Running(val message: String) : WaterUiState
    data object Stopping : WaterUiState
    data object AuthExpired : WaterUiState
    data class Error(val message: String) : WaterUiState
}
