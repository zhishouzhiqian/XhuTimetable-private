package vip.mystery0.xhu.timetable.config.store

import com.russhwolf.settings.ExperimentalSettingsImplementation
import com.russhwolf.settings.KeychainSettings

@OptIn(ExperimentalSettingsImplementation::class)
internal actual object WaterSecureStore {
    private val keychain = KeychainSettings("vip.mystery0.xhu.timetable.water")

    actual fun get(key: String): String? = keychain.getStringOrNull(key)

    actual fun set(key: String, value: String) {
        if (value.isBlank()) {
            remove(key)
        } else {
            keychain.putString(key, value)
        }
    }

    actual fun remove(key: String) {
        keychain.remove(key)
    }
}
