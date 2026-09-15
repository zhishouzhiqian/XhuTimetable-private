package vip.mystery0.xhu.timetable.config.store

internal actual object WaterSecureStore {
    actual fun get(key: String): String? =
        Store.UserStore.getConfiguration(storageKey(key), "").takeIf(String::isNotBlank)

    actual fun set(key: String, value: String) {
        if (value.isBlank()) {
            remove(key)
        } else {
            Store.UserStore.setConfiguration(storageKey(key), value)
        }
    }

    actual fun remove(key: String) {
        Store.UserStore.removeConfiguration(storageKey(key))
    }

    private fun storageKey(key: String): String = "waterSecure.$key"
}
