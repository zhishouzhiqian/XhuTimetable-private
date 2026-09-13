package vip.mystery0.xhu.timetable

import android.app.Activity

/** 由 Android 宿主提供随构建渠道变化的信息，共享库不依赖宿主的 BuildConfig。 */
data class AndroidAppConfiguration(
    val applicationId: String,
    val appName: String,
    val versionName: String,
    val versionCode: Long,
    val isDebug: Boolean,
    val enableUpdateCheck: Boolean,
    val featureApiKey: String,
    val launcherActivity: Class<out Activity>,
)

internal lateinit var androidAppConfiguration: AndroidAppConfiguration
