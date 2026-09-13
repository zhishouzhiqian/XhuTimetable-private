package vip.mystery0.xhu.timetable.base

import android.annotation.SuppressLint
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import vip.mystery0.xhu.timetable.androidAppConfiguration
import vip.mystery0.xhu.timetable.context

actual fun systemVersion(): String = "Android ${Build.VERSION.RELEASE}-${Build.VERSION.SDK_INT}"
actual fun deviceFactory(): String = Build.MANUFACTURER
actual fun deviceModel(): String = Build.MODEL
actual fun deviceRom(): String = Build.DISPLAY

//设备id
private const val PUBLIC_DEVICE_ID_CACHE_DURATION_MILLIS = 10 * 60 * 1000L
private val publicDeviceIdLock = Any()
private var publicDeviceIdCache: String? = null
private var publicDeviceIdCacheTimeMillis: Long = 0L

private val publicDeviceId: String
    @SuppressLint("HardwareIds")
    get() {
        val nowMillis = SystemClock.elapsedRealtime()
        synchronized(publicDeviceIdLock) {
            val cache = publicDeviceIdCache
            if (cache != null &&
                nowMillis - publicDeviceIdCacheTimeMillis < PUBLIC_DEVICE_ID_CACHE_DURATION_MILLIS
            ) {
                return cache
            }
            val deviceId: String =
                Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
            publicDeviceIdCache = deviceId
            publicDeviceIdCacheTimeMillis = nowMillis
            return deviceId
        }
    }

actual fun publicDeviceId(): String = "android-${publicDeviceId}"

actual fun appName(): String = androidAppConfiguration.appName

actual fun packageName(): String = androidAppConfiguration.applicationId

actual fun appVersionName(): String = androidAppConfiguration.versionName

actual fun appVersionCode(): String = androidAppConfiguration.versionCode.toString()

actual fun appVersionCodeNumber(): Long = androidAppConfiguration.versionCode
