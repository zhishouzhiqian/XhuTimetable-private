package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterStartDecision
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterMissingParametersException
import vip.mystery0.xhu.timetable.repository.WaterUnknownResponseException
import vip.mystery0.xhu.timetable.water.WaterServiceController

class WaterViewModel(private val controller: WaterServiceController) : ComposeViewModel() {
    val uiState = controller.uiState
    val credentials = controller.credentials
    val availableDevices = controller.devices
    val lastKnownRunning = controller.running
    val balanceCents = controller.balanceCents
    val records = controller.records
    val lastCostCents = controller.lastCostCents
    val authenticationRequest = controller.authenticationRequest
    val perfectCampusLoginState = controller.perfectCampusLoginState
    private val _actionInProgress = MutableStateFlow(false)
    val actionInProgress: StateFlow<Boolean> = _actionInProgress

    private val _startConfirmation = MutableStateFlow<WaterStartDecision?>(null)
    val startConfirmation: StateFlow<WaterStartDecision?> = _startConfirmation

    fun init() = launchHandled(retryOperation = { controller.refreshAfterAuthentication() }) {
        controller.initialize()
    }

    fun saveCredentials(openId: String, sessionId: String, posCode: String, orgId: String): Boolean {
        val value = WaterCredentials(openId, sessionId, posCode, orgId).normalized()
        val error = when {
            value.sessionId.isBlank() -> "JSESSIONID 不能为空"
            value.posCode.isNotBlank() && !value.posCode.matches(Regex("\\d{6}")) -> "设备号必须是 6 位数字"
            value.orgId.isBlank() -> "组织编号不能为空"
            else -> null
        }
        if (error != null) {
            launchHandled { controller.handleError(WaterMissingParametersException(error)) }
            return false
        }
        launchHandled(retryOperation = {
            // 恢复后使用控制器中的新会话，不能再次写入表单中的旧凭据。
            if (value.bound) controller.refreshOverview() else controller.refreshDevices()
        }) { controller.saveCredentials(value) }
        return true
    }

    fun startAuthentication() = controller.setAuthenticating()

    fun requestPerfectCampusSms(phone: String) {
        val normalized = phone.filter(Char::isDigit)
        if (!normalized.matches(Regex("1\\d{10}"))) {
            launchHandled { controller.handleError(WaterMissingParametersException("请输入 11 位手机号")) }
            return
        }
        viewModelScope.launch { controller.requestPerfectCampusSms(normalized) }
    }

    fun completePerfectCampusSms(code: String) {
        val normalized = code.filter(Char::isDigit)
        if (normalized.isBlank()) {
            launchHandled { controller.handleError(WaterMissingParametersException("请输入短信验证码")) }
            return
        }
        viewModelScope.launch { controller.completePerfectCampusSms(normalized) }
    }

    fun cancelPerfectCampusLogin() = controller.cancelPerfectCampusLogin()

    fun completeAuthentication(openId: String, sessionId: String) =
        launchHandled { controller.saveAuthentication(openId, sessionId) }

    fun cancelAuthentication() = launchHandled { controller.refreshOverview() }

    fun failAuthentication(message: String) = launchHandled {
        controller.handleError(WaterUnknownResponseException(message.ifBlank { "官方认证页面加载失败" }))
    }

    fun failAuthenticationRecovery() {
        viewModelScope.launch { controller.failAuthenticationRecovery() }
    }

    fun refreshDevices() = launchHandled { controller.refreshDevices() }
    fun refreshOverview() = launchHandled { controller.refreshOverview() }
    fun selectDevice(device: WaterDevice) = launchHandled { controller.selectDevice(device) }
    fun clearCredentials() = launchHandled { controller.clearCredentials() }

    fun startWater() = launchHandled(userAction = true) { performStart() }

    fun toggleWater() = launchHandled(userAction = true) {
        controller.initialize()
        val ready = withTimeoutOrNull(50_000L) {
            uiState.first {
                it != WaterUiState.Loading && it != WaterUiState.RecoveringAuthentication &&
                        it != WaterUiState.Authenticating
            }
        }
        if (ready == null) throw WaterUnknownResponseException("加载超时，请稍后重试")
        if (credentials.value?.configured != true) {
            throw WaterMissingParametersException("请先登录并选择用水设备")
        }
        if (lastKnownRunning.value) {
            controller.stop()
            commandCompleted("关水成功")
        } else performStart()
    }

    private suspend fun performStart() {
        when (val decision = controller.prepareStart()) {
            is WaterStartDecision.Ready -> {
                controller.start()
                commandCompleted("开水成功")
            }
            is WaterStartDecision.LowBalance,
            WaterStartDecision.BalanceUnavailable -> _startConfirmation.value = decision
        }
    }

    fun confirmStart() = launchHandled(userAction = true) {
        _startConfirmation.value = null
        controller.confirmPreparedStart()
        controller.start()
        commandCompleted("开水成功")
    }

    fun dismissStartConfirmation() {
        _startConfirmation.value = null
        launchHandled { controller.cancelPreparedStart() }
    }

    fun stopWater() = launchHandled(userAction = true) {
        controller.stop()
        commandCompleted("关水成功")
    }

    private fun commandCompleted(message: String) {
        toastMessage(message)
        viewModelScope.launch { controller.refreshAccountAfterCommand() }
    }

    private fun launchHandled(
        retryOperation: (suspend () -> Unit)? = null,
        userAction: Boolean = false,
        block: suspend () -> Unit,
    ) {
        if (userAction && _actionInProgress.value) return
        if (userAction) _actionInProgress.value = true
        viewModelScope.launch {
            try {
                retryOnceAfterWaterAuthenticationExpired(
                    operation = block,
                    recover = controller::requestAuthenticationRecovery,
                    retryOperation = retryOperation ?: block,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                controller.handleError(error)
                if (userAction) toastMessage(error.message ?: "操作失败，请重试")
            } finally {
                if (userAction) _actionInProgress.value = false
            }
        }
    }
}

internal suspend fun <T> retryOnceAfterWaterAuthenticationExpired(
    operation: suspend () -> T,
    recover: suspend () -> Boolean,
    retryOperation: suspend () -> T = operation,
): T = try {
    operation()
} catch (error: WaterAuthExpiredException) {
    if (!recover()) throw error
    retryOperation()
}
