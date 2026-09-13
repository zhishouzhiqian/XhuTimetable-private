package vip.mystery0.xhu.timetable

import vip.mystery0.xhu.timetable.ui.activity.StartActivity

class Application : TimetableApplication() {
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
