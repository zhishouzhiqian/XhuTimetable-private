package vip.mystery0.xhu.timetable.config.store

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import vip.mystery0.xhu.timetable.model.water.WaterCredentials

object WaterStore {
    private const val CREDENTIALS = "waterCredentials"
    private const val LAST_KNOWN_RUNNING = "waterLastKnownRunning"

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    suspend fun loadCredentials(): WaterCredentials? = withContext(Dispatchers.IO) {
        val value = Store.UserStore.getConfiguration(CREDENTIALS, "")
        if (value.isBlank()) return@withContext null
        runCatching { json.decodeFromString<WaterCredentials>(value) }.getOrNull()
    }

    suspend fun saveCredentials(credentials: WaterCredentials) = withContext(Dispatchers.IO) {
        Store.UserStore.setConfiguration(CREDENTIALS, json.encodeToString(credentials))
    }

    suspend fun clearCredentials() = withContext(Dispatchers.IO) {
        Store.UserStore.removeConfiguration(CREDENTIALS)
        Store.UserStore.removeConfiguration(LAST_KNOWN_RUNNING)
    }

    suspend fun isLastKnownRunning(): Boolean = withContext(Dispatchers.IO) {
        Store.UserStore.getConfiguration(LAST_KNOWN_RUNNING, false)
    }

    suspend fun setLastKnownRunning(running: Boolean) = withContext(Dispatchers.IO) {
        Store.UserStore.setConfiguration(LAST_KNOWN_RUNNING, running)
    }
}
