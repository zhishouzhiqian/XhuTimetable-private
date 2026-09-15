package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.config.coroutine.safeLaunch
import vip.mystery0.xhu.timetable.config.store.WaterStore
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterErrorType
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.module.desc
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterBusinessException
import vip.mystery0.xhu.timetable.repository.WaterMissingParametersException
import vip.mystery0.xhu.timetable.repository.WaterNetworkException
import vip.mystery0.xhu.timetable.repository.WaterRepository
import vip.mystery0.xhu.timetable.repository.WaterUnknownResponseException

class WaterViewModel(
    private val waterRepository: WaterRepository,
) : ComposeViewModel() {
    private val _uiState = MutableStateFlow<WaterUiState>(WaterUiState.Loading)
    val uiState: StateFlow<WaterUiState> = _uiState

    private val _credentials = MutableStateFlow<WaterCredentials?>(null)
    val credentials: StateFlow<WaterCredentials?> = _credentials

    private val _availableDevices = MutableStateFlow<List<WaterDevice>>(emptyList())
    val availableDevices: StateFlow<List<WaterDevice>> = _availableDevices

    private val _lastKnownRunning = MutableStateFlow(false)
    val lastKnownRunning: StateFlow<Boolean> = _lastKnownRunning

    private var initialized = false

    fun init() {
        if (initialized) return
        initialized = true
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            val value = WaterStore.loadCredentials()
            _credentials.value = value
            _lastKnownRunning.value = WaterStore.isLastKnownRunning()
            _uiState.value = when {
                value?.authenticated != true -> WaterUiState.NotAuthenticated
                !value.bound -> WaterUiState.NotBound
                _lastKnownRunning.value -> WaterUiState.Running("本机记录的上次状态为已开水")
                else -> WaterUiState.Ready
            }
            if (value?.authenticated == true && !value.bound && value.orgId.isNotBlank()) {
                refreshDevicesInternal(value)
            }
        }
    }

    fun saveCredentials(
        openId: String,
        sessionId: String,
        posCode: String,
        orgId: String,
    ): Boolean {
        val value = WaterCredentials(openId, sessionId, posCode, orgId).normalized()
        val error = when {
            value.openId.isBlank() -> "openid 不能为空"
            value.sessionId.isBlank() -> "JSESSIONID 不能为空"
            value.posCode.isNotBlank() && !value.posCode.matches(Regex("\\d{6}")) ->
                "设备号必须是 6 位数字"
            value.orgId.isBlank() -> "组织编号不能为空"
            else -> null
        }
        if (error != null) {
            _uiState.value = WaterUiState.Error(WaterErrorType.MissingParameters, error)
            return false
        }
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            WaterStore.saveCredentials(value)
            _credentials.value = value
            if (value.bound) {
                _uiState.value = if (_lastKnownRunning.value) {
                    WaterUiState.Running("配置已更新")
                } else {
                    WaterUiState.Ready
                }
            } else {
                _uiState.value = WaterUiState.NotBound
                refreshDevicesInternal(value)
            }
        }
        return true
    }

    fun refreshDevices() {
        val value = _credentials.value ?: run {
            _uiState.value = WaterUiState.NotAuthenticated
            return
        }
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            refreshDevicesInternal(value)
        }
    }

    fun selectDevice(device: WaterDevice) {
        val value = _credentials.value ?: run {
            _uiState.value = WaterUiState.NotAuthenticated
            return
        }
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            val updated = value.copy(
                posCode = device.posCode,
                orgId = device.orgId,
            ).normalized()
            WaterStore.saveDevice(updated.posCode, updated.orgId)
            _credentials.value = updated
            _uiState.value = if (_lastKnownRunning.value) {
                WaterUiState.Running("设备已更新")
            } else {
                WaterUiState.Ready
            }
        }
    }

    fun clearCredentials() {
        if (_lastKnownRunning.value) {
            _uiState.value = WaterUiState.Error(
                WaterErrorType.Business,
                "请先关水，再清除本地凭据",
            )
            return
        }
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            WaterStore.clearCredentials()
            _credentials.value = null
            _availableDevices.value = emptyList()
            _lastKnownRunning.value = false
            _uiState.value = WaterUiState.NotAuthenticated
        }
    }

    fun startWater() {
        val value = configuredCredentials() ?: run {
            return
        }
        if (_uiState.value.isBusy()) {
            return
        }
        _uiState.value = WaterUiState.Starting
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            waterRepository.startWater(value)
            WaterStore.setLastKnownRunning(true)
            _lastKnownRunning.value = true
            _uiState.value = WaterUiState.Running("开水成功")
        }
    }

    fun stopWater() {
        val value = configuredCredentials() ?: run {
            return
        }
        if (_uiState.value.isBusy()) {
            return
        }
        _uiState.value = WaterUiState.Stopping
        viewModelScope.safeLaunch(onException = {
            handleRequestError(it)
            true
        }) {
            waterRepository.stopWater(value)
            WaterStore.setLastKnownRunning(false)
            _lastKnownRunning.value = false
            _uiState.value = WaterUiState.Ready
            toastMessage("关水成功")
        }
    }

    private fun handleRequestError(throwable: Throwable) {
        _uiState.value = when (throwable) {
            is WaterAuthExpiredException -> {
                clearExpiredAuthentication()
                WaterUiState.AuthExpired
            }

            is WaterNetworkException ->
                WaterUiState.Error(WaterErrorType.Network, throwable.message.orEmpty())

            is WaterBusinessException ->
                WaterUiState.Error(WaterErrorType.Business, throwable.message.orEmpty())

            is WaterMissingParametersException ->
                WaterUiState.Error(WaterErrorType.MissingParameters, throwable.message.orEmpty())

            is WaterUnknownResponseException ->
                WaterUiState.Error(WaterErrorType.UnknownResponse, throwable.message.orEmpty())

            else -> WaterUiState.Error(WaterErrorType.UnknownResponse, throwable.desc())
        }
    }

    private suspend fun refreshDevicesInternal(credentials: WaterCredentials) {
        _uiState.value = WaterUiState.Loading
        val devices = waterRepository.getOftenUsedDevices(credentials)
        _availableDevices.value = devices
        val selected = when {
            credentials.bound -> devices.firstOrNull {
                it.posCode == credentials.posCode && it.orgId == credentials.orgId
            }

            devices.size == 1 -> devices.single()
            else -> null
        }
        if (selected != null) {
            val updated = credentials.copy(
                posCode = selected.posCode,
                orgId = selected.orgId,
            ).normalized()
            WaterStore.saveDevice(updated.posCode, updated.orgId)
            _credentials.value = updated
            _uiState.value = if (_lastKnownRunning.value) {
                WaterUiState.Running("设备信息已自动刷新")
            } else {
                WaterUiState.Ready
            }
        } else if (credentials.bound) {
            _uiState.value = if (_lastKnownRunning.value) {
                WaterUiState.Running("当前设备未出现在常用设备列表中")
            } else {
                WaterUiState.Ready
            }
        } else {
            _uiState.value = WaterUiState.NotBound
        }
    }

    private fun configuredCredentials(): WaterCredentials? {
        val value = _credentials.value
        _uiState.value = when {
            value?.authenticated != true -> WaterUiState.NotAuthenticated
            !value.bound -> WaterUiState.NotBound
            else -> return value
        }
        return null
    }

    private fun clearExpiredAuthentication() {
        val value = _credentials.value
        viewModelScope.safeLaunch(onException = {
            _uiState.value = WaterUiState.Error(WaterErrorType.UnknownResponse, it.desc())
            true
        }) {
            WaterStore.clearAuthentication()
            _credentials.value = value?.copy(openId = "", sessionId = "")
        }
    }
}

private fun WaterUiState.isBusy(): Boolean =
    this == WaterUiState.Authenticating ||
            this == WaterUiState.Starting ||
            this == WaterUiState.Stopping
