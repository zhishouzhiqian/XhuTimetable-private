package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterStartDecision
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

    private val _lowBalanceConfirmation = MutableStateFlow<Long?>(null)
    val lowBalanceConfirmation: StateFlow<Long?> = _lowBalanceConfirmation

    fun init() = launchHandled { controller.initialize() }

    fun saveCredentials(openId: String, sessionId: String, posCode: String, orgId: String): Boolean {
        val value = WaterCredentials(openId, sessionId, posCode, orgId).normalized()
        val error = when {
            value.openId.isBlank() -> "openid 不能为空"
            value.sessionId.isBlank() -> "JSESSIONID 不能为空"
            value.posCode.isNotBlank() && !value.posCode.matches(Regex("\\d{6}")) -> "设备号必须是 6 位数字"
            value.orgId.isBlank() -> "组织编号不能为空"
            else -> null
        }
        if (error != null) {
            launchHandled { controller.handleError(WaterMissingParametersException(error)) }
            return false
        }
        launchHandled { controller.saveCredentials(value) }
        return true
    }

    fun startAuthentication() = controller.setAuthenticating()

    fun completeAuthentication(openId: String, sessionId: String) =
        launchHandled { controller.saveAuthentication(openId, sessionId) }

    fun cancelAuthentication() = launchHandled { controller.refreshOverview() }

    fun failAuthentication(message: String) = launchHandled {
        controller.handleError(WaterUnknownResponseException(message.ifBlank { "官方认证页面加载失败" }))
    }

    fun refreshDevices() = launchHandled { controller.refreshDevices() }
    fun refreshOverview() = launchHandled { controller.refreshOverview() }
    fun selectDevice(device: WaterDevice) = launchHandled { controller.selectDevice(device) }
    fun clearCredentials() = launchHandled { controller.clearCredentials() }

    fun startWater() = launchHandled {
        when (val decision = controller.prepareStart()) {
            is WaterStartDecision.Ready -> controller.start()
            is WaterStartDecision.LowBalance -> _lowBalanceConfirmation.value = decision.balanceCents
        }
    }

    fun confirmLowBalanceStart() = launchHandled {
        _lowBalanceConfirmation.value = null
        controller.start()
    }

    fun dismissLowBalanceStart() {
        _lowBalanceConfirmation.value = null
        launchHandled { controller.cancelPreparedStart() }
    }

    fun stopWater() = launchHandled {
        controller.stop()
        toastMessage("关水成功")
    }

    private fun launchHandled(block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block()
            } catch (error: Throwable) {
                controller.handleError(error)
            }
        }
    }
}
