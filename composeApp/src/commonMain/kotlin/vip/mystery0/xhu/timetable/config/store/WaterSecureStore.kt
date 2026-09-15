package vip.mystery0.xhu.timetable.config.store

internal expect object WaterSecureStore {
    fun get(key: String): String?

    fun set(key: String, value: String)

    fun remove(key: String)
}
