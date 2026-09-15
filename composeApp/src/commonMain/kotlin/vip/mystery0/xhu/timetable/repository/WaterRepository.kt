package vip.mystery0.xhu.timetable.repository

import io.ktor.client.plugins.ClientRequestException
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.ResponseException
import io.ktor.http.HttpStatusCode
import vip.mystery0.xhu.timetable.api.WaterApi
import vip.mystery0.xhu.timetable.base.BaseDataRepo
import vip.mystery0.xhu.timetable.config.HINT_NETWORK
import vip.mystery0.xhu.timetable.model.water.WaterCommandRequest
import vip.mystery0.xhu.timetable.model.water.WaterCommandResponse
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterDeviceListRequest

class WaterRepository(
    private val waterApi: WaterApi,
) : BaseDataRepo {
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
                message = response.resultData?.message.orEmpty().ifBlank { response.message },
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
                message = response.resultData?.message.orEmpty().ifBlank { response.message },
            )
            response.resultData?.message.orEmpty().ifBlank {
                response.message.ifBlank { "操作成功" }
            }
        }
    }

    private fun ensureAuthenticated(credentials: WaterCredentials) {
        if (!credentials.authenticated) {
            throw WaterMissingParametersException("缺少 openid 或 JSESSIONID")
        }
    }

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
            throw WaterBusinessException(message.ifBlank { "用水服务返回失败" })
        }
        if (result.isNullOrBlank()) {
            throw WaterUnknownResponseException("用水服务返回了无法识别的响应")
        }
        if (result != SUCCESS_CODE) {
            throw WaterBusinessException(message.ifBlank { "用水服务操作失败" })
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

class WaterAuthExpiredException : RuntimeException("用水服务登录状态已失效，请重新导入认证信息")

class WaterNetworkException(message: String, cause: Throwable? = null) : RuntimeException(message, cause)

class WaterBusinessException(message: String) : RuntimeException(message)

class WaterMissingParametersException(message: String) : RuntimeException(message)

class WaterUnknownResponseException(message: String) : RuntimeException(message)
