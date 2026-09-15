package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.config.coroutine.safeLaunch
import vip.mystery0.xhu.timetable.config.store.WaterStore
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.module.desc
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterRepository

class WaterViewModel(
    private val waterRepository: WaterRepository,
) : ComposeViewModel() {
    private val _uiState = MutableStateFlow<WaterUiState>(WaterUiState.Loading)
    val uiState: StateFlow<WaterUiState> = _uiState

    private val _credentials = MutableStateFlow<WaterCredentials?>(null)
    val credentials: StateFlow<WaterCredentials?> = _credentials

    private val _lastKnownRunning = MutableStateFlow(false)
    val lastKnownRunning: StateFlow<Boolean> = _lastKnownRunning

    private var initialized = false

    fun init() {
        if (initialized) return
        initialized = true
        viewModelScope.safeLaunch(onException = {
            _uiState.value = WaterUiState.Error(it.desc())
            true
        }) {
            val value = WaterStore.loadCredentials()
            _credentials.value = value
            _lastKnownRunning.value = WaterStore.isLastKnownRunning()
            _uiState.value = when {
                value?.configured != true -> WaterUiState.NotBound
                _lastKnownRunning.value -> WaterUiState.Running("本机记录的上次状态为已开水")
                else -> WaterUiState.Ready
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
            !value.posCode.matches(Regex("\\d{6}")) -> "设备号必须是 6 位数字"
            value.orgId.isBlank() -> "组织编号不能为空"
            else -> null
        }
        if (error != null) {
            _uiState.value = WaterUiState.Error(error)
            return false
        }
        viewModelScope.safeLaunch(onException = {
            _uiState.value = WaterUiState.Error(it.desc())
            true
        }) {
            WaterStore.saveCredentials(value)
            _credentials.value = value
            _uiState.value = if (_lastKnownRunning.value) {
                WaterUiState.Running("凭据已更新")
            } else {
                WaterUiState.Ready
            }
        }
        return true
    }

    fun clearCredentials() {
        if (_lastKnownRunning.value) {
            _uiState.value = WaterUiState.Error("请先关水，再清除本地凭据")
            return
        }
        viewModelScope.safeLaunch(onException = {
            _uiState.value = WaterUiState.Error(it.desc())
            true
        }) {
            WaterStore.clearCredentials()
            _credentials.value = null
            _lastKnownRunning.value = false
            _uiState.value = WaterUiState.NotBound
        }
    }

    fun startWater() {
        val value = _credentials.value ?: run {
            _uiState.value = WaterUiState.NotBound
            return
        }
        if (_uiState.value == WaterUiState.Starting || _uiState.value == WaterUiState.Stopping) {
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
        val value = _credentials.value ?: run {
            _uiState.value = WaterUiState.NotBound
            return
        }
        if (_uiState.value == WaterUiState.Starting || _uiState.value == WaterUiState.Stopping) {
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
        _uiState.value = if (throwable is WaterAuthExpiredException) {
            WaterUiState.AuthExpired
        } else {
            WaterUiState.Error(throwable.desc())
        }
    }
}
