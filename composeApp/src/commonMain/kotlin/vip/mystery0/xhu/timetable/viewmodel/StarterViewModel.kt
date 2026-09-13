package vip.mystery0.xhu.timetable.viewmodel

import androidx.lifecycle.viewModelScope
import io.github.vinceglb.filekit.PlatformFile
import io.github.vinceglb.filekit.exists
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.datetime.LocalDate
import org.koin.core.component.KoinComponent
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.config.Customisable
import vip.mystery0.xhu.timetable.config.clearDownloadDir
import vip.mystery0.xhu.timetable.config.coroutine.safeLaunch
import vip.mystery0.xhu.timetable.config.externalPictureDir
import vip.mystery0.xhu.timetable.config.networkErrorHandler
import vip.mystery0.xhu.timetable.config.store.EventBus
import vip.mystery0.xhu.timetable.config.store.GlobalCacheStore
import vip.mystery0.xhu.timetable.config.store.UserStore
import vip.mystery0.xhu.timetable.config.store.getCacheStore
import vip.mystery0.xhu.timetable.config.store.setCacheStore
import vip.mystery0.xhu.timetable.config.store.setConfigStore
import vip.mystery0.xhu.timetable.initFeature
import vip.mystery0.xhu.timetable.model.TermStartChangeAlert
import vip.mystery0.xhu.timetable.model.event.EventType
import vip.mystery0.xhu.timetable.module.desc
import vip.mystery0.xhu.timetable.repository.StartRepo
import vip.mystery0.xhu.timetable.utils.MIN
import vip.mystery0.xhu.timetable.utils.md5
import vip.mystery0.xhu.timetable.utils.now
import vip.mystery0.xhu.timetable.utils.sha1
import vip.mystery0.xhu.timetable.utils.sha256
import kotlin.time.Clock

class StarterViewModel : ComposeViewModel(), KoinComponent {
    private val _allowPrivacy = MutableStateFlow(GlobalCacheStore.allowPrivacy)
    val allowPrivacy: StateFlow<Boolean> = _allowPrivacy

    private val _readyState = MutableStateFlow(ReadyState(loading = true))
    val readyState: StateFlow<ReadyState> = _readyState

    fun allowPrivacy() {
        viewModelScope.safeLaunch {
            initFeature()
            setCacheStore { this.allowPrivacy = true }
            _allowPrivacy.value = true
            EventBus.post(EventType.ALLOW_PRIVACY)
        }
    }

    fun syncTermStartDate() {
        viewModelScope.safeLaunch {
            setConfigStore {
                customTermStartDate = Customisable.clearCustom(LocalDate.MIN)
            }
            StartRepo.pendingTermStartChangeAlert = null
            _readyState.update { it.copy(termStartChangeAlert = null) }
            EventBus.post(EventType.CHANGE_TERM_START_TIME)
        }
    }

    fun keepCustomTermStartDate() {
        viewModelScope.safeLaunch {
            StartRepo.pendingTermStartChangeAlert = null
            _readyState.update { it.copy(termStartChangeAlert = null) }
        }
    }

    fun doInitAndReady() {
        viewModelScope.safeLaunch(onException = networkErrorHandler { throwable ->
            logger.w("init failed", throwable)
            _readyState.update {
                it.copy(
                    loading = false,
                    errorMessage = throwable.desc(),
                    termStartChangeAlert = StartRepo.pendingTermStartChangeAlert,
                )
            }
        }) {
            val isLogin = UserStore.isLogin()
            _readyState.update { it.copy(isLogin = isLogin) }
            clearDownloadDir()
            doPlatformInit()
            StartRepo.init()
            val alert = StartRepo.pendingTermStartChangeAlert
            val hideTime = getCacheStore { hideSplashBefore }
            if (LocalDate.now() < hideTime) {
                //已经设置了隐藏时间，且当前时间还未到达隐藏时间
                _readyState.update {
                    it.copy(
                        loading = false,
                        splashFile = null,
                        splashId = null,
                        termStartChangeAlert = alert,
                    )
                }
                return@safeLaunch
            }
            val dir = PlatformFile(externalPictureDir, "splash")
            val now = Clock.System.now()
            val splashList = getCacheStore { splashList }
                .filter { now >= it.startShowTime && now <= it.endShowTime }
                .map {
                    val extension = it.imageUrl.substringAfterLast(".")
                    val name = "${it.splashId.toString().sha1()}-${it.imageUrl.md5()}"
                    PlatformFile(
                        dir,
                        "${name.sha256()}.${extension}"
                    ) to it
                }
                .filter { it.first.exists() }
            if (splashList.isNotEmpty()) {
                doCheckDownloadSplash()
            }
            val splash = splashList.randomOrNull()
            if (splash == null) {
                _readyState.update {
                    it.copy(
                        loading = false,
                        splashFile = null,
                        splashId = null,
                        termStartChangeAlert = alert,
                    )
                }
                return@safeLaunch
            }
            _readyState.update {
                it.copy(
                    loading = false,
                    splashFile = splash.first,
                    splashId = splash.second.splashId,
                    termStartChangeAlert = alert,
                )
            }
        }
    }
}

expect suspend fun doPlatformInit()

expect suspend fun doCheckDownloadSplash()

data class ReadyState(
    val loading: Boolean = false,
    val isLogin: Boolean = false,
    val splashFile: PlatformFile? = null,
    val splashId: Long? = null,
    val errorMessage: String = "",
    val termStartChangeAlert: TermStartChangeAlert? = null,
) {
    val canNavigate: Boolean
        get() = !loading && termStartChangeAlert == null
}