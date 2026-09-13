package vip.mystery0.xhu.timetable

import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import co.touchlab.kermit.Logger
import co.touchlab.kermit.koin.KermitKoinLogger
import com.tencent.mmkv.MMKV
import com.tencent.mmkv.MMKVLogLevel
import multiplatform.network.cmptoast.AppContext
import org.koin.android.ext.koin.androidContext
import org.koin.core.context.startKoin
import vip.mystery0.xhu.timetable.config.mmkv.KermitMMKVLogger
import vip.mystery0.xhu.timetable.config.store.GlobalCacheStore
import vip.mystery0.xhu.timetable.module.moduleList

@SuppressLint("StaticFieldLeak")
internal lateinit var context: Context

abstract class TimetableApplication : Application(), DefaultLifecycleObserver {
    protected abstract val appConfiguration: AndroidAppConfiguration

    override fun onCreate() {
        super<Application>.onCreate()
        // 日志、依赖注入和功能开关初始化前，先接收宿主的渠道配置。
        androidAppConfiguration = appConfiguration
        AppContext.apply { set(applicationContext) }
        context = this
        initLogger()
        initCoroutine()
        startKoin {
            logger(KermitKoinLogger(Logger.withTag("koin")))
            androidContext(this@TimetableApplication)
            modules(moduleList())
        }
        val root = context.filesDir.absolutePath + "/mmkv"
        MMKV.initialize(this, root, null, MMKVLogLevel.LevelWarning, KermitMMKVLogger())
        if (GlobalCacheStore.allowPrivacy) {
            initFeature()
        }
    }

    override fun onStop(owner: LifecycleOwner) {
        super.onStop(owner)
        Logger.i("App is in the background. Stopping FileLogWriter to flush logs.")
        fileLogWriter.stop()
    }
}
