package vip.mystery0.xhu.timetable.water

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import vip.mystery0.xhu.timetable.config.store.WaterStore
import vip.mystery0.xhu.timetable.base.publicDeviceId
import vip.mystery0.xhu.timetable.model.water.PerfectCampusLoginState
import vip.mystery0.xhu.timetable.model.water.WaterAuthenticationRequest
import vip.mystery0.xhu.timetable.model.water.WaterAuthenticationSource
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterErrorType
import vip.mystery0.xhu.timetable.model.water.WaterStartDecision
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.model.water.WaterUseRecord
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterBusinessException
import vip.mystery0.xhu.timetable.repository.WaterMissingParametersException
import vip.mystery0.xhu.timetable.repository.WaterNetworkException
import vip.mystery0.xhu.timetable.repository.WaterRepository
import vip.mystery0.xhu.timetable.repository.WaterUnknownResponseException
import vip.mystery0.xhu.timetable.repository.PerfectCampusRepository

class WaterServiceController(
    private val repository: WaterRepository,
    private val perfectCampusRepository: PerfectCampusRepository,
) {
    private val mutex = Mutex()
    private var initialized = false
    private var authenticationRecovery: CompletableDeferred<Boolean>? = null
    private var startPrepared = false
    private var startConfirmationPending = false
    private var commandRevision = 0L

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
    private val _authenticationRequest = MutableStateFlow<WaterAuthenticationRequest?>(null)
    val authenticationRequest: StateFlow<WaterAuthenticationRequest?> = _authenticationRequest
    private val _perfectCampusLoginState = MutableStateFlow<PerfectCampusLoginState>(PerfectCampusLoginState.Idle)
    val perfectCampusLoginState: StateFlow<PerfectCampusLoginState> = _perfectCampusLoginState

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

    suspend fun refreshAfterAuthentication() = mutex.withLock {
        val value = authenticatedCredentials() ?: return@withLock
        if (value.bound) refreshOverviewLocked(value) else refreshDevicesLocked(value)
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
        val updated = current.withAuthentication(openId, sessionId)
        if (!updated.authenticated) throw WaterMissingParametersException("官方认证未返回完整凭据")
        WaterStore.saveCredentials(updated)
        _credentials.value = updated
        _authenticationRequest.value = null
        _perfectCampusLoginState.value = PerfectCampusLoginState.Idle
        val recovery = authenticationRecovery
        if (recovery == null) {
            if (updated.bound) refreshOverviewLocked(updated) else refreshDevicesLocked(updated)
        } else {
            authenticationRecovery = null
            _uiState.value = if (updated.bound) WaterUiState.Ready else WaterUiState.NotBound
            recovery.complete(true)
        }
    }

    suspend fun requestAuthenticationRecovery(): Boolean {
        val recovery = mutex.withLock {
            authenticationRecovery ?: CompletableDeferred<Boolean>().also {
                authenticationRecovery = it
                val perfectCampusSession = WaterStore.loadPerfectCampusSession()
                _authenticationRequest.value = if (perfectCampusSession == null) {
                    schoolAuthenticationRequest(replaceSessionCookie = true)
                } else {
                    WaterAuthenticationRequest(
                        entryUrl = perfectCampusRepository.authorizationUrl(perfectCampusSession),
                        source = WaterAuthenticationSource.PerfectCampus,
                        replaceSessionCookie = true,
                    )
                }
                _uiState.value = WaterUiState.RecoveringAuthentication
            }
        }
        val recovered = withTimeoutOrNull(AUTHENTICATION_RECOVERY_TIMEOUT_MILLIS) {
            recovery.await()
        } ?: false
        if (!recovered) {
            mutex.withLock {
                if (authenticationRecovery === recovery) {
                    authenticationRecovery = null
                    if (_authenticationRequest.value?.source == WaterAuthenticationSource.PerfectCampus) {
                        WaterStore.clearPerfectCampusSession()
                    }
                    _authenticationRequest.value = null
                }
            }
        }
        return recovered
    }

    suspend fun failAuthenticationRecovery() {
        val recovery = mutex.withLock {
            if (_authenticationRequest.value?.source == WaterAuthenticationSource.PerfectCampus) {
                WaterStore.clearPerfectCampusSession()
            }
            _authenticationRequest.value = null
            authenticationRecovery.also { authenticationRecovery = null }
        }
        recovery?.complete(false)
    }

    suspend fun requestPerfectCampusSms(phone: String) {
        _perfectCampusLoginState.value = PerfectCampusLoginState.SendingSms
        try {
            perfectCampusRepository.requestSms(phone, publicDeviceId())
            _perfectCampusLoginState.value = PerfectCampusLoginState.SmsSent
        } catch (error: Throwable) {
            _perfectCampusLoginState.value = PerfectCampusLoginState.Error(
                error.message?.takeIf(String::isNotBlank) ?: "验证码发送失败",
                canSubmitCode = false,
            )
        }
    }

    suspend fun completePerfectCampusSms(code: String) {
        _perfectCampusLoginState.value = PerfectCampusLoginState.Verifying
        try {
            val session = perfectCampusRepository.completeSms(code)
            WaterStore.savePerfectCampusSession(session)
            _authenticationRequest.value = WaterAuthenticationRequest(
                entryUrl = perfectCampusRepository.authorizationUrl(session),
                source = WaterAuthenticationSource.PerfectCampus,
                replaceSessionCookie = true,
            )
            _perfectCampusLoginState.value = PerfectCampusLoginState.Idle
            _uiState.value = WaterUiState.Authenticating
        } catch (error: Throwable) {
            _perfectCampusLoginState.value = PerfectCampusLoginState.Error(
                error.message?.takeIf(String::isNotBlank) ?: "验证码校验失败",
                canSubmitCode = true,
            )
        }
    }

    fun cancelPerfectCampusLogin() {
        perfectCampusRepository.cancelLogin()
        _perfectCampusLoginState.value = PerfectCampusLoginState.Idle
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
        authenticationRecovery?.complete(false)
        authenticationRecovery = null
        WaterStore.clearCredentials()
        WaterStore.setStartBalanceCents(null)
        startPrepared = false
        startConfirmationPending = false
        WaterStore.setExitRecoveryPending(false)
        _credentials.value = null
        _authenticationRequest.value = null
        _perfectCampusLoginState.value = PerfectCampusLoginState.Idle
        _devices.value = emptyList()
        _balanceCents.value = null
        _records.value = emptyList()
        _uiState.value = WaterUiState.NotAuthenticated
    }

    suspend fun prepareStart(): WaterStartDecision = mutex.withLock {
        val value = configuredCredentials() ?: throw WaterMissingParametersException("用水服务尚未就绪")
        _uiState.value = WaterUiState.Starting
        startPrepared = false
        startConfirmationPending = false
        WaterStore.setStartBalanceCents(null)
        val balance = if (value.canQueryBalance) {
            repository.getBalance(value)
        } else {
            getPerfectCampusBalance()
        }
        if (balance == null) {
            _balanceCents.value = null
            startConfirmationPending = true
            _uiState.value = WaterUiState.Ready
            return@withLock WaterStartDecision.BalanceUnavailable
        }
        _balanceCents.value = balance
        WaterStore.setStartBalanceCents(balance)
        _uiState.value = WaterUiState.Ready
        if (balance < LOW_BALANCE_CENTS) {
            startConfirmationPending = true
            WaterStartDecision.LowBalance(balance)
        } else {
            startPrepared = true
            WaterStartDecision.Ready(balance)
        }
    }

    suspend fun confirmPreparedStart() = mutex.withLock {
        configuredCredentials() ?: return@withLock
        if (startPrepared) return@withLock
        if (!startConfirmationPending) {
            throw WaterMissingParametersException("没有待确认的开水请求")
        }
        startConfirmationPending = false
        startPrepared = true
    }

    suspend fun start() = mutex.withLock {
        val value = configuredCredentials() ?: return
        if (!startPrepared) {
            throw WaterMissingParametersException("请先完成开水前确认")
        }
        _uiState.value = WaterUiState.Starting
        commandRevision++
        // 请求可能已经到达设备；网关错误时只核实状态，绝不重复发送开阀。
        WaterStore.setExitRecoveryPending(true)
        try {
            executeWaterCommandWithReconciliation(
                command = { repository.startWater(value) },
                readRunning = { repository.getRunningState(value) },
                expectedRunning = true,
            )
        } catch (error: WaterCommandUncertainException) {
            _running.value = true
            WaterStore.setLastKnownRunning(true)
            platformSetWaterRunning(true)
            throw error
        }
        startPrepared = false
        startConfirmationPending = false
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

    fun setAuthenticating() {
        _authenticationRequest.value = schoolAuthenticationRequest(replaceSessionCookie = false)
        _uiState.value = WaterUiState.Authenticating
    }

    suspend fun cancelPreparedStart() = mutex.withLock {
        if (!_running.value) {
            startPrepared = false
            startConfirmationPending = false
            WaterStore.setStartBalanceCents(null)
        }
    }

    suspend fun handleError(error: Throwable) {
        if (_uiState.value == WaterUiState.Starting && !_running.value) {
            startPrepared = false
            startConfirmationPending = false
            WaterStore.setStartBalanceCents(null)
        }
        _uiState.value = when (error) {
            is WaterAuthExpiredException -> {
                authenticationRecovery?.complete(false)
                authenticationRecovery = null
                WaterStore.clearAuthentication()
                _credentials.value = _credentials.value?.copy(openId = "", sessionId = "")
                _authenticationRequest.value = null
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
        val (overview, perfectCampusBalance) = coroutineScope {
            val balance = async { if (!value.canQueryBalance) getPerfectCampusBalance() else null }
            repository.getOverview(value) to balance.await()
        }
        _balanceCents.value = overview.balanceCents ?: perfectCampusBalance
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
        commandRevision++
        executeWaterCommandWithReconciliation(
            command = { repository.stopWater(value) },
            readRunning = { repository.getRunningState(value) },
            expectedRunning = false,
        )
        markStopped()
        _uiState.value = WaterUiState.Ready
    }

    // 查询不持有操作锁，也不改动开关状态；旧操作的结果不能覆盖新操作。
    suspend fun refreshAccountAfterCommand() {
        val snapshot = mutex.withLock {
            val value = _credentials.value ?: return
            Triple(value, commandRevision, _running.value)
        }
        val (value, revision, running) = snapshot
        if (!running) delay(900)
        val (balance, records) = coroutineScope {
            val balance = async {
                optionalAccountQuery {
                    if (value.canQueryBalance) repository.getBalance(value) else getPerfectCampusBalance()
                }
            }
            val records = async { optionalAccountQuery { repository.getUseWaterRecords(value) } }
            balance.await() to records.await()
        }
        mutex.withLock {
            if (commandRevision != revision || _credentials.value != value) return@withLock
            _balanceCents.value = balance
            if (records != null) {
                val previous = _records.value.firstOrNull { it.posCode == value.posCode }
                _records.value = records.take(100)
                if (!running) {
                    _lastCostCents.value = records.firstOrNull { it.posCode == value.posCode }
                        ?.takeIf { it != previous }?.amountFen
                }
            }
        }
    }

    private suspend fun <T> optionalAccountQuery(block: suspend () -> T): T? =
        withTimeoutOrNull(4_000L) {
            try { block() }
            catch (error: CancellationException) { throw error }
            catch (_: Exception) { null }
        }

    private suspend fun markStopped() {
        _running.value = false
        startPrepared = false
        startConfirmationPending = false
        WaterStore.setLastKnownRunning(false)
        WaterStore.setStartBalanceCents(null)
        WaterStore.setExitRecoveryPending(false)
        platformSetWaterRunning(false)
    }

    private suspend fun getPerfectCampusBalance(): Long? {
        val session = WaterStore.loadPerfectCampusSession() ?: return null
        return withTimeoutOrNull(4_000L) {
            try {
                perfectCampusRepository.getBalance(session)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            }
        }
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
        private const val AUTHENTICATION_RECOVERY_TIMEOUT_MILLIS = 45_000L
        private const val SCHOOL_AUTH_ENTRY_URL = "https://xhyb.xhu.edu.cn/short/hcXum6gj7Lc"

        private fun schoolAuthenticationRequest(replaceSessionCookie: Boolean) =
            WaterAuthenticationRequest(
                entryUrl = SCHOOL_AUTH_ENTRY_URL,
                source = WaterAuthenticationSource.SchoolPage,
                replaceSessionCookie = replaceSessionCookie,
            )
    }
}

expect fun platformSetWaterRunning(running: Boolean)
