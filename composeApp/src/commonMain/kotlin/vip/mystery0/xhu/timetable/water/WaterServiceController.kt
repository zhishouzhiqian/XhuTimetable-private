package vip.mystery0.xhu.timetable.water

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import vip.mystery0.xhu.timetable.config.store.WaterStore
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterErrorType
import vip.mystery0.xhu.timetable.model.water.WaterStartDecision
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.model.water.WaterUseRecord
import vip.mystery0.xhu.timetable.model.water.calculateWaterCost
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterBusinessException
import vip.mystery0.xhu.timetable.repository.WaterMissingParametersException
import vip.mystery0.xhu.timetable.repository.WaterNetworkException
import vip.mystery0.xhu.timetable.repository.WaterRepository
import vip.mystery0.xhu.timetable.repository.WaterUnknownResponseException

class WaterServiceController(private val repository: WaterRepository) {
    private val mutex = Mutex()
    private var initialized = false

    private val _uiState = MutableStateFlow<WaterUiState>(WaterUiState.Loading)
    val uiState: StateFlow<WaterUiState> = _uiState
    private val _credentials = MutableStateFlow<WaterCredentials?>(null)
    val credentials: StateFlow<WaterCredentials?> = _credentials
    private val _devices = MutableStateFlow<List<WaterDevice>>(emptyList())
    val devices: StateFlow<List<WaterDevice>> = _devices
    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running
    private val _balanceCents = MutableStateFlow<Long?>(null)
    val balanceCents: StateFlow<Long?> = _balanceCents
    private val _records = MutableStateFlow<List<WaterUseRecord>>(emptyList())
    val records: StateFlow<List<WaterUseRecord>> = _records
    private val _lastCostCents = MutableStateFlow<Long?>(null)
    val lastCostCents: StateFlow<Long?> = _lastCostCents

    suspend fun initialize() = mutex.withLock {
        if (initialized) return
        initialized = true
        val value = WaterStore.loadCredentials()
        _credentials.value = value
        when {
            value?.authenticated != true -> _uiState.value = WaterUiState.NotAuthenticated
            !value.bound -> {
                _uiState.value = WaterUiState.NotBound
                refreshDevicesLocked(value)
            }
            else -> {
                refreshOverviewLocked(value)
                if (WaterStore.isExitRecoveryPending() && _running.value) stopLocked(value)
                else if (!_running.value) WaterStore.setExitRecoveryPending(false)
            }
        }
    }

    suspend fun refreshOverview() = mutex.withLock {
        val value = configuredCredentials() ?: return
        refreshOverviewLocked(value)
    }

    suspend fun refreshDevices() = mutex.withLock {
        val value = authenticatedCredentials() ?: return
        refreshDevicesLocked(value)
    }

    suspend fun saveCredentials(value: WaterCredentials) = mutex.withLock {
        WaterStore.saveCredentials(value)
        _credentials.value = value
        if (value.bound) refreshOverviewLocked(value) else refreshDevicesLocked(value)
    }

    suspend fun saveAuthentication(openId: String, sessionId: String) = mutex.withLock {
        val current = _credentials.value ?: WaterCredentials(orgId = DEFAULT_ORG_ID)
        val updated = current.copy(openId = openId, sessionId = sessionId).normalized()
        if (!updated.authenticated) throw WaterMissingParametersException("官方认证未返回完整凭据")
        WaterStore.saveCredentials(updated)
        _credentials.value = updated
        if (updated.bound) refreshOverviewLocked(updated) else refreshDevicesLocked(updated)
    }

    suspend fun selectDevice(device: WaterDevice) = mutex.withLock {
        val current = authenticatedCredentials() ?: return
        val updated = current.copy(posCode = device.posCode, orgId = device.orgId).normalized()
        WaterStore.saveDevice(updated.posCode, updated.orgId)
        _credentials.value = updated
        refreshOverviewLocked(updated)
    }

    suspend fun clearCredentials() = mutex.withLock {
        if (_running.value) throw WaterBusinessException("请先关水，再清除本地凭据")
        WaterStore.clearCredentials()
        WaterStore.setStartBalanceCents(null)
        WaterStore.setExitRecoveryPending(false)
        _credentials.value = null
        _devices.value = emptyList()
        _balanceCents.value = null
        _records.value = emptyList()
        _uiState.value = WaterUiState.NotAuthenticated
    }

    suspend fun prepareStart(): WaterStartDecision = mutex.withLock {
        val value = configuredCredentials() ?: throw WaterMissingParametersException("用水服务尚未就绪")
        _uiState.value = WaterUiState.Starting
        val balance = repository.getBalance(value)
        _balanceCents.value = balance
        WaterStore.setStartBalanceCents(balance)
        _uiState.value = WaterUiState.Ready
        if (balance < LOW_BALANCE_CENTS) WaterStartDecision.LowBalance(balance)
        else WaterStartDecision.Ready(balance)
    }

    suspend fun start() = mutex.withLock {
        val value = configuredCredentials() ?: return
        if (WaterStore.getStartBalanceCents() == null) {
            throw WaterMissingParametersException("未取得开水前余额，请重试")
        }
        _uiState.value = WaterUiState.Starting
        repository.startWater(value)
        _running.value = true
        WaterStore.setLastKnownRunning(true)
        WaterStore.setExitRecoveryPending(true)
        platformSetWaterRunning(true)
        _uiState.value = WaterUiState.Running("水阀已开启")
    }

    suspend fun stop() = mutex.withLock {
        val value = configuredCredentials() ?: return
        stopLocked(value)
    }

    suspend fun bestEffortStopAfterExit(): Boolean = mutex.withLock {
        val value = _credentials.value ?: WaterStore.loadCredentials() ?: return false
        if (!value.configured) return false
        WaterStore.setExitRecoveryPending(true)
        if (!repository.getRunningState(value)) {
            markStopped()
            return true
        }
        stopLocked(value)
        true
    }

    fun setAuthenticating() { _uiState.value = WaterUiState.Authenticating }

    suspend fun cancelPreparedStart() {
        if (!_running.value) WaterStore.setStartBalanceCents(null)
    }

    suspend fun handleError(error: Throwable) {
        if (_uiState.value == WaterUiState.Starting && !_running.value) {
            WaterStore.setStartBalanceCents(null)
        }
        _uiState.value = when (error) {
            is WaterAuthExpiredException -> {
                WaterStore.clearAuthentication()
                _credentials.value = _credentials.value?.copy(openId = "", sessionId = "")
                WaterUiState.AuthExpired
            }
            is WaterNetworkException -> WaterUiState.Error(WaterErrorType.Network, error.message.orEmpty())
            is WaterBusinessException -> WaterUiState.Error(WaterErrorType.Business, error.message.orEmpty())
            is WaterMissingParametersException -> WaterUiState.Error(WaterErrorType.MissingParameters, error.message.orEmpty())
            is WaterUnknownResponseException -> WaterUiState.Error(WaterErrorType.UnknownResponse, error.message.orEmpty())
            else -> WaterUiState.Error(WaterErrorType.UnknownResponse, error.message ?: "未知错误")
        }
    }

    private suspend fun refreshOverviewLocked(value: WaterCredentials) {
        _uiState.value = WaterUiState.Loading
        val overview = repository.getOverview(value)
        _balanceCents.value = overview.balanceCents
        _records.value = overview.records
        _running.value = overview.running
        WaterStore.setLastKnownRunning(overview.running)
        platformSetWaterRunning(overview.running)
        _uiState.value = if (overview.running) WaterUiState.Running("服务器显示水阀已开启") else WaterUiState.Ready
    }

    private suspend fun refreshDevicesLocked(value: WaterCredentials) {
        _uiState.value = WaterUiState.Loading
        val values = repository.getOftenUsedDevices(value)
        _devices.value = values
        val selected = values.singleOrNull()
        if (selected == null) {
            _uiState.value = WaterUiState.NotBound
        } else {
            val updated = value.copy(posCode = selected.posCode, orgId = selected.orgId).normalized()
            WaterStore.saveDevice(updated.posCode, updated.orgId)
            _credentials.value = updated
            refreshOverviewLocked(updated)
        }
    }

    private suspend fun stopLocked(value: WaterCredentials) {
        _uiState.value = WaterUiState.Stopping
        repository.stopWater(value)
        val startBalance = WaterStore.getStartBalanceCents()
        var endBalance: Long? = null
        for (attempt in 0 until 3) {
            if (attempt > 0) delay(900)
            endBalance = runCatching { repository.getBalance(value) }.getOrNull() ?: endBalance
            if (calculateWaterCost(startBalance, endBalance) != null) break
        }
        endBalance?.let { _balanceCents.value = it }
        _records.value = runCatching { repository.getUseWaterRecords(value) }.getOrDefault(_records.value)
        val balanceCost = calculateWaterCost(startBalance, endBalance)
        val serverCost = _records.value.firstOrNull { it.posCode == value.posCode }?.amountFen
        _lastCostCents.value = when {
            serverCost != null && serverCost != balanceCost -> serverCost
            else -> balanceCost ?: serverCost
        }
        markStopped()
        _uiState.value = WaterUiState.Ready
    }

    private suspend fun markStopped() {
        _running.value = false
        WaterStore.setLastKnownRunning(false)
        WaterStore.setStartBalanceCents(null)
        WaterStore.setExitRecoveryPending(false)
        platformSetWaterRunning(false)
    }

    private fun authenticatedCredentials(): WaterCredentials? {
        val value = _credentials.value
        if (value?.authenticated != true) _uiState.value = WaterUiState.NotAuthenticated
        return value?.takeIf { it.authenticated }
    }

    private fun configuredCredentials(): WaterCredentials? {
        val value = authenticatedCredentials() ?: return null
        if (!value.bound) {
            _uiState.value = WaterUiState.NotBound
            return null
        }
        return value
    }

    companion object {
        const val LOW_BALANCE_CENTS = 200L
        private const val DEFAULT_ORG_ID = "2"
    }
}

expect fun platformSetWaterRunning(running: Boolean)
