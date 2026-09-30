package vip.mystery0.xhu.timetable

import vip.mystery0.xhu.timetable.ui.activity.StartActivity

class Application : TimetableApplication() {
    override fun onCreate() {
        // 测试登录进程只运行认证组件，避免重复启动课表、推送及数据库。
        val processName = if (android.os.Build.VERSION.SDK_INT >= 28) android.app.Application.getProcessName()
        else (getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager)
            .runningAppProcesses?.firstOrNull { it.pid == android.os.Process.myPid() }?.processName
        if (BuildConfig.DEBUG && processName?.endsWith(":campus_login") == true) return
        super.onCreate()
    }

    override val appConfiguration: AndroidAppConfiguration
        get() = AndroidAppConfiguration(
            applicationId = BuildConfig.APPLICATION_ID,
            appName = getString(R.string.app_name),
            versionName = BuildConfig.VERSION_NAME,
            versionCode = BuildConfig.VERSION_CODE.toLong(),
            isDebug = BuildConfig.DEBUG,
            enableUpdateCheck = BuildConfig.ENABLE_UPDATE_CHECK,
            featureApiKey = getString(R.string.feature_api_key),
            launcherActivity = StartActivity::class.java,
        )
}
