package vip.mystery0.xhu.timetable.config.store

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterSchoolSession

object WaterStore {
    private const val DEVICE_CONFIGURATION = "waterDeviceConfiguration"
    private const val LEGACY_CREDENTIALS = "waterCredentials"
    private const val LAST_KNOWN_RUNNING = "waterLastKnownRunning"
    private const val OPEN_ID = "openid"
    private const val SESSION_ID = "sessionId"
    private const val START_BALANCE_CENTS = "startBalanceCents"
    private const val EXIT_RECOVERY_PENDING = "waterExitRecoveryPending"

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    suspend fun loadCredentials(): WaterCredentials? = withContext(Dispatchers.IO) {
        val legacyText = Store.UserStore.getConfiguration(LEGACY_CREDENTIALS, "")
        val legacy = legacyText.takeIf(String::isNotBlank)?.let {
            runCatching { json.decodeFromString<WaterCredentials>(it) }.getOrNull()
        }
        var openId = WaterSecureStore.get(OPEN_ID).orEmpty()
        var sessionId = WaterSecureStore.get(SESSION_ID).orEmpty()
        if (openId.isBlank() && legacy?.openId?.isNotBlank() == true) {
            openId = legacy.openId
            WaterSecureStore.set(OPEN_ID, openId)
        }
        if (sessionId.isBlank() && legacy?.sessionId?.isNotBlank() == true) {
            sessionId = legacy.sessionId
            WaterSecureStore.set(SESSION_ID, sessionId)
        }

        val deviceText = Store.UserStore.getConfiguration(DEVICE_CONFIGURATION, "")
        val device = deviceText.takeIf(String::isNotBlank)?.let {
            runCatching { json.decodeFromString<WaterDeviceConfiguration>(it) }.getOrNull()
        } ?: legacy?.let { WaterDeviceConfiguration(it.posCode, it.orgId) }

        if (legacy != null) {
            device?.let(::saveDeviceConfiguration)
            Store.UserStore.removeConfiguration(LEGACY_CREDENTIALS)
        }
        if (openId.isBlank() && sessionId.isBlank() && device == null) {
            return@withContext null
        }
        WaterCredentials(
            openId = openId,
            sessionId = sessionId,
            posCode = device?.posCode.orEmpty(),
            orgId = device?.orgId.orEmpty(),
        ).normalized()
    }

    suspend fun saveCredentials(credentials: WaterCredentials) = withContext(Dispatchers.IO) {
        val value = credentials.normalized()
        WaterSecureStore.set(OPEN_ID, value.openId)
        WaterSecureStore.set(SESSION_ID, value.sessionId)
        saveDeviceConfiguration(WaterDeviceConfiguration(value.posCode, value.orgId))
        Store.UserStore.removeConfiguration(LEGACY_CREDENTIALS)
    }

    suspend fun saveDevice(posCode: String, orgId: String) = withContext(Dispatchers.IO) {
        saveDeviceConfiguration(WaterDeviceConfiguration(posCode.trim(), orgId.trim()))
    }

    suspend fun clearAuthentication() = withContext(Dispatchers.IO) {
        WaterSecureStore.remove(OPEN_ID)
        WaterSecureStore.remove(SESSION_ID)
        removeLegacySecrets()
    }

    suspend fun clearCredentials() = withContext(Dispatchers.IO) {
        WaterSecureStore.remove(WaterSchoolSession.STORAGE_KEY)
        WaterSecureStore.remove(OPEN_ID)
        WaterSecureStore.remove(SESSION_ID)
        Store.UserStore.removeConfiguration(DEVICE_CONFIGURATION)
        Store.UserStore.removeConfiguration(LEGACY_CREDENTIALS)
        Store.UserStore.removeConfiguration(LAST_KNOWN_RUNNING)
    }

    suspend fun isLastKnownRunning(): Boolean = withContext(Dispatchers.IO) {
        Store.UserStore.getConfiguration(LAST_KNOWN_RUNNING, false)
    }

    suspend fun setLastKnownRunning(running: Boolean) = withContext(Dispatchers.IO) {
        Store.UserStore.setConfiguration(LAST_KNOWN_RUNNING, running)
    }

    suspend fun getStartBalanceCents(): Long? = withContext(Dispatchers.IO) {
        WaterSecureStore.get(START_BALANCE_CENTS)?.toLongOrNull()
    }

    suspend fun setStartBalanceCents(value: Long?) = withContext(Dispatchers.IO) {
        if (value == null) WaterSecureStore.remove(START_BALANCE_CENTS)
        else WaterSecureStore.set(START_BALANCE_CENTS, value.toString())
    }

    suspend fun isExitRecoveryPending(): Boolean = withContext(Dispatchers.IO) {
        Store.UserStore.getConfiguration(EXIT_RECOVERY_PENDING, false)
    }

    suspend fun setExitRecoveryPending(pending: Boolean) = withContext(Dispatchers.IO) {
        Store.UserStore.setConfiguration(EXIT_RECOVERY_PENDING, pending)
    }

    private fun saveDeviceConfiguration(configuration: WaterDeviceConfiguration) {
        Store.UserStore.setConfiguration(
            DEVICE_CONFIGURATION,
            json.encodeToString(configuration),
        )
    }

    private fun removeLegacySecrets() {
        val legacyText = Store.UserStore.getConfiguration(LEGACY_CREDENTIALS, "")
        if (legacyText.isBlank()) return
        val legacy = runCatching {
            json.decodeFromString<WaterCredentials>(legacyText)
        }.getOrNull() ?: return
        saveDeviceConfiguration(WaterDeviceConfiguration(legacy.posCode, legacy.orgId))
        Store.UserStore.removeConfiguration(LEGACY_CREDENTIALS)
    }
}

@Serializable
private data class WaterDeviceConfiguration(
    val posCode: String = "",
    val orgId: String = "",
)
