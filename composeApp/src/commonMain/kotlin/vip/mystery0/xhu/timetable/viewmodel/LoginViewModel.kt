package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.config.FeatureString
import vip.mystery0.xhu.timetable.config.coroutine.safeLaunch
import vip.mystery0.xhu.timetable.config.networkErrorHandler
import vip.mystery0.xhu.timetable.config.store.EventBus
import vip.mystery0.xhu.timetable.config.store.User
import vip.mystery0.xhu.timetable.config.store.UserStore
import vip.mystery0.xhu.timetable.model.event.EventType
import vip.mystery0.xhu.timetable.module.desc
import vip.mystery0.xhu.timetable.repository.UserRepo

class LoginViewModel : ComposeViewModel() {
    private val _loginLabel = MutableStateFlow("")
    val loginLabel: StateFlow<String> = _loginLabel

    private val _loginState = MutableStateFlow(LoginState())
    val loginState: StateFlow<LoginState> = _loginState.asStateFlow()

    private val failureTracker = LoginFailureTracker(failureThreshold = 3)
    private var loginJob: Job? = null

    fun init() {
        viewModelScope.safeLaunch {
            _loginLabel.value = FeatureString.LOGIN_LABEL.getValue()
        }
    }

    fun login(
        username: String,
        password: String,
    ) {
        // ViewModel 统一防重复提交，覆盖按钮和键盘完成键
        if (_loginState.value.loading || loginJob?.isActive == true) {
            return
        }

        // 下一次实际提交时清除最近一次登录失败原因
        _loginState.value = _loginState.value.copy(
            loading = true,
            success = false,
            errorMessage = "",
            lastErrorMessage = "",
            showHelpDialog = false,
        )

        loginJob = viewModelScope.safeLaunch(onException = networkErrorHandler { throwable ->
            logger.w("login failed", throwable)
            // 实际提交后认证失败、网络/服务异常等登录未完成计数；协程取消不计数
            val shouldShowHelp = failureTracker.recordFailure()
            val errorMsg = throwable.desc()
            _loginState.value = _loginState.value.copy(
                loading = false,
                success = false,
                errorMessage = errorMsg,
                lastErrorMessage = errorMsg,
                showHelpDialog = shouldShowHelp,
            )
        }) {
            val isDuplicate = withContext(Dispatchers.Default) {
                UserStore.getUserByStudentId(username) != null
            }
            if (isDuplicate) {
                // 本地已登录账号不通过异常方式处理，避免在离线时被 networkErrorHandler 转换为网络错误而误计数
                _loginState.value = _loginState.value.copy(
                    loading = false,
                    success = false,
                    errorMessage = "该用户已登录！",
                    lastErrorMessage = "该用户已登录！",
                    showHelpDialog = false,
                )
                return@safeLaunch
            }
            val loginResponse = UserRepo.doLogin(username, password)
            val userInfo = UserRepo.getUserInfo(loginResponse.sessionToken)
            val user = User(
                studentId = username,
                password = password,
                token = loginResponse.sessionToken,
                info = userInfo,
                null,
            )
            UserStore.login(user)
            if (UserStore.mainUser().studentId == username) {
                // 刚刚登录的账号是主账号，说明是异常情况下登录
                EventBus.post(EventType.CHANGE_MAIN_USER)
            }
            // 成功清零
            failureTracker.recordSuccess()
            _loginState.value = _loginState.value.copy(
                loading = false,
                success = true,
                errorMessage = "",
                lastErrorMessage = "",
                showHelpDialog = false,
            )
        }
    }

    /**
     * 关闭求助 AlertDialog 后清除触发状态，避免重组反复弹窗
     */
    fun dismissHelpDialog() {
        if (_loginState.value.showHelpDialog) {
            _loginState.value = _loginState.value.copy(showHelpDialog = false)
        }
    }
}

data class LoginState(
    val loading: Boolean = false,
    val success: Boolean = false,
    val errorMessage: String = "",
    val lastErrorMessage: String = "",
    val showHelpDialog: Boolean = false,
)