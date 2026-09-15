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
    val authenticated: Boolean
        get() = openId.isNotBlank() && sessionId.isNotBlank()

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
    val message: String = "",
    val resultData: WaterDeviceListResultData? = null,
)

@Serializable
data class WaterDeviceListResultData(
    val result: String = "",
    val message: String = "",
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
    data object NotAuthenticated : WaterUiState
    data object Authenticating : WaterUiState
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
