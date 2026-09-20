package vip.mystery0.xhu.timetable.repository

import io.ktor.client.plugins.ClientRequestException
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.ResponseException
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import vip.mystery0.xhu.timetable.api.WaterApi
import vip.mystery0.xhu.timetable.base.BaseDataRepo
import vip.mystery0.xhu.timetable.config.HINT_NETWORK
import vip.mystery0.xhu.timetable.model.water.WaterCommandRequest
import vip.mystery0.xhu.timetable.model.water.WaterCommandResponse
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterDeviceListRequest
import vip.mystery0.xhu.timetable.model.water.WaterHomeRequest
import vip.mystery0.xhu.timetable.model.water.WaterOverview
import vip.mystery0.xhu.timetable.model.water.WaterUseRecord
import vip.mystery0.xhu.timetable.model.water.parseYuanToCents

class WaterRepository(
    private val waterApi: WaterApi,
) : BaseDataRepo {
    suspend fun getOverview(credentials: WaterCredentials): WaterOverview {
        val value = credentials.normalized()
        ensureAuthenticated(value)
        ensureOnline()
        val userType = getUserType(value)
        val balance = getBalance(value, userType)
        val records = getUseWaterRecords(value)
        val running = getRunningState(value)
        return WaterOverview(balance, records, running)
    }

    suspend fun getBalance(credentials: WaterCredentials): Long {
        val value = credentials.normalized()
        ensureAuthenticated(value)
        ensureOnline()
        return getBalance(value, getUserType(value))
    }

    suspend fun getUseWaterRecords(credentials: WaterCredentials): List<WaterUseRecord> {
        val value = credentials.normalized()
        ensureAuthenticated(value)
        ensureOnline()
        return requestSafely {
            val response = waterApi.getUseWaterRecords(
                sessionCookie(value), value.orgId, SESSION_TYPE, IS_WECHAT_APP,
                REQUESTED_WITH, WATER_ORIGIN, "$WATER_ORIGIN/", WaterHomeRequest(value.openId),
            )
            validateResponse(
                response.success,
                response.resultData?.result,
                response.resultData?.message.orEmpty().ifBlank { response.message.orEmpty() },
            )
            response.resultData?.data.orEmpty().sortedByDescending { it.beginTime }
        }
    }

    suspend fun getRunningState(credentials: WaterCredentials): Boolean {
        val value = credentials.normalized()
        ensureAuthenticated(value)
        ensureOnline()
        return requestSafely {
            val response = waterApi.getRunningState(
                sessionCookie(value), value.orgId, SESSION_TYPE, IS_WECHAT_APP,
                REQUESTED_WITH, WATER_ORIGIN, "$WATER_ORIGIN/", WaterHomeRequest(value.openId),
            )
            if (!response.success) {
                throwIfAuthenticationExpired(response.message.orEmpty())
                throw WaterBusinessException(response.message.orEmpty().ifBlank { "查询水阀状态失败" })
            }
            hasActiveWaterRecord(response.wcrList) || hasActiveWaterRecord(response.resultData)
        }
    }

    suspend fun getOftenUsedDevices(credentials: WaterCredentials): List<WaterDevice> {
        val value = credentials.normalized()
        ensureAuthenticated(value)
        if (value.orgId.isBlank()) {
            throw WaterMissingParametersException("缺少组织编号，无法自动获取设备")
        }
        ensureOnline()
        return requestSafely {
            val response = waterApi.getOftenUsedDevices(
                sessionCookie = "JSESSIONID=${value.sessionId}",
                orgId = value.orgId,
                sessionType = SESSION_TYPE,
                isWechatApp = IS_WECHAT_APP,
                requestedWith = REQUESTED_WITH,
                origin = WATER_ORIGIN,
                referer = "$WATER_ORIGIN/",
                openId = value.openId,
                request = WaterDeviceListRequest(value.openId, value.orgId),
            )
            validateResponse(
                success = response.success,
                result = response.resultData?.result,
                message = response.resultData?.message.orEmpty().ifBlank { response.message.orEmpty() },
            )
            response.resultData?.data.orEmpty()
                .filter { it.posCode.matches(Regex("\\d{6}")) && it.orgId.isNotBlank() }
                .distinctBy { it.posCode to it.orgId }
        }
    }

    suspend fun startWater(credentials: WaterCredentials): String =
        execute(credentials, waterApi::startWater)

    suspend fun stopWater(credentials: WaterCredentials): String =
        execute(credentials, waterApi::stopWater)

    private suspend fun execute(
        credentials: WaterCredentials,
        request: suspend (
            sessionCookie: String,
            orgId: String,
            sessionType: String,
            isWechatApp: String,
            requestedWith: String,
            origin: String,
            referer: String,
            openId: String,
            body: WaterCommandRequest,
        ) -> WaterCommandResponse,
    ): String {
        val value = credentials.normalized()
        ensureAuthenticated(value)
        if (!value.bound) {
            throw WaterMissingParametersException("设备号或组织编号缺失")
        }
        ensureOnline()
        return requestSafely {
            val response = request(
                "JSESSIONID=${value.sessionId}",
                value.orgId,
                SESSION_TYPE,
                IS_WECHAT_APP,
                REQUESTED_WITH,
                WATER_ORIGIN,
                "$WATER_ORIGIN/",
                value.openId,
                WaterCommandRequest(
                    openId = value.openId,
                    posCode = value.posCode,
                    orgId = value.orgId,
                ),
            )
            validateResponse(
                success = response.success,
                result = response.resultData?.result,
                message = response.resultData?.message.orEmpty().ifBlank { response.message.orEmpty() },
            )
            response.resultData?.message.orEmpty().ifBlank {
                response.message.orEmpty().ifBlank { "操作成功" }
            }
        }
    }

    private fun ensureAuthenticated(credentials: WaterCredentials) {
        if (!credentials.authenticated) {
            throw WaterMissingParametersException("缺少 JSESSIONID")
        }
    }

    private suspend fun getUserType(credentials: WaterCredentials): String = requestSafely {
        val response = waterApi.getWaterHome(
            sessionCookie(credentials), credentials.orgId, SESSION_TYPE, IS_WECHAT_APP,
            REQUESTED_WITH, WATER_ORIGIN, "$WATER_ORIGIN/", WaterHomeRequest(credentials.openId),
        )
        val userType = response.data?.userType.orEmpty()
        if (!response.success || userType.isBlank()) {
            throwIfAuthenticationExpired(response.message.orEmpty())
            throw WaterUnknownResponseException(response.message.orEmpty().ifBlank { "无法读取用水账户类型" })
        }
        userType
    }

    private suspend fun getBalance(credentials: WaterCredentials, userType: String): Long =
        requestSafely {
            val response = waterApi.getBalance(
                sessionCookie(credentials), credentials.orgId, SESSION_TYPE, IS_WECHAT_APP,
                REQUESTED_WITH, WATER_ORIGIN, "$WATER_ORIGIN/", credentials.openId,
                "", userType, credentials.orgId,
            )
            if (!response.success) {
                throwIfAuthenticationExpired(response.message.orEmpty())
                throw WaterBusinessException(response.message.orEmpty().ifBlank { "读取校园卡余额失败" })
            }
            parseYuanToCents(response.data?.cardBalance.orEmpty())
                ?: throw WaterUnknownResponseException("校园卡余额格式无法识别")
        }

    private fun sessionCookie(credentials: WaterCredentials): String =
        "JSESSIONID=${credentials.sessionId}"

    private fun ensureOnline() {
        if (!isOnline) {
            throw WaterNetworkException(HINT_NETWORK)
        }
    }

    private suspend fun <T> requestSafely(block: suspend () -> T): T = try {
        block()
    } catch (e: ClientRequestException) {
        if (e.response.status == HttpStatusCode.Unauthorized ||
            e.response.status == HttpStatusCode.Forbidden
        ) {
            throw WaterAuthExpiredException()
        }
        throw WaterNetworkException("用水服务请求失败（HTTP ${e.response.status.value}）", e)
    } catch (e: HttpRequestTimeoutException) {
        throw WaterNetworkException("用水服务请求超时，请稍后重试", e)
    } catch (e: ResponseException) {
        throw WaterNetworkException("用水服务暂时不可用（HTTP ${e.response.status.value}）", e)
    }

    private fun validateResponse(
        success: Boolean,
        result: String?,
        message: String,
    ) {
        if (!success) {
            throwIfAuthenticationExpired(message)
            throw WaterBusinessException(message.ifBlank { "用水服务返回失败" })
        }
        if (result.isNullOrBlank()) {
            throw WaterUnknownResponseException("用水服务返回了无法识别的响应")
        }
        if (result != SUCCESS_CODE) {
            throwIfAuthenticationExpired(message)
            throw WaterBusinessException(message.ifBlank { "用水服务操作失败" })
        }
    }

    private fun throwIfAuthenticationExpired(message: String) {
        val normalized = message.lowercase()
        if (isWaterAuthenticationExpiredMessage(normalized)) {
            throw WaterAuthExpiredException()
        }
    }

    private companion object {
        const val WATER_ORIGIN = "https://ecard.xhu.edu.cn"
        const val SUCCESS_CODE = "000000"
        const val SESSION_TYPE = "uniapp"
        const val IS_WECHAT_APP = "true"
        const val REQUESTED_WITH = "XMLHttpRequest"
    }
}

internal fun hasActiveWaterRecord(value: JsonElement?): Boolean = value.hasNonEmptyList("wcrList")

internal fun isWaterAuthenticationExpiredMessage(message: String): Boolean {
    val normalized = message.lowercase()
    return normalized.contains("登录") || normalized.contains("认证") ||
            normalized.contains("session") || normalized.contains("openid")
}

private fun JsonElement?.hasNonEmptyList(key: String): Boolean = when (this) {
    is JsonArray -> isNotEmpty()
    is JsonObject -> entries.any { (name, value) ->
        (name == key && value is JsonArray && value.isNotEmpty()) || value.hasNonEmptyList(key)
    }
    else -> false
}

class WaterAuthExpiredException : RuntimeException("用水服务登录状态已失效，请重新导入认证信息")

class WaterNetworkException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

class WaterBusinessException(message: String) : RuntimeException(message)

class WaterMissingParametersException(message: String) : RuntimeException(message)

class WaterUnknownResponseException(message: String) : RuntimeException(message)
