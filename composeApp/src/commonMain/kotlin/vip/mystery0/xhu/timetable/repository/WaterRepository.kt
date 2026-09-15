package vip.mystery0.xhu.timetable.repository

import io.ktor.client.plugins.ClientRequestException
import io.ktor.http.HttpStatusCode
import vip.mystery0.xhu.timetable.api.WaterApi
import vip.mystery0.xhu.timetable.base.BaseDataRepo
import vip.mystery0.xhu.timetable.model.water.WaterCommandRequest
import vip.mystery0.xhu.timetable.model.water.WaterCommandResponse
import vip.mystery0.xhu.timetable.model.water.WaterCredentials

class WaterRepository(
    private val waterApi: WaterApi,
) : BaseDataRepo {
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
        checkForceLoadFromCloud(true)
        val value = credentials.normalized()
        try {
            val response = request(
                "JSESSIONID=${value.sessionId}",
                value.orgId,
                "uniapp",
                "true",
                "XMLHttpRequest",
                WATER_ORIGIN,
                "$WATER_ORIGIN/",
                value.openId,
                WaterCommandRequest(
                    openId = value.openId,
                    posCode = value.posCode,
                    orgId = value.orgId,
                ),
            )
            if (!response.success || response.resultData?.result != SUCCESS_CODE) {
                throw WaterRequestException(
                    response.resultData?.message
                        ?.takeIf { it.isNotBlank() }
                        ?: response.message.ifBlank { "操作失败" }
                )
            }
            return response.resultData.message.ifBlank { response.message }
        } catch (e: ClientRequestException) {
            if (e.response.status == HttpStatusCode.Unauthorized ||
                e.response.status == HttpStatusCode.Forbidden
            ) {
                throw WaterAuthExpiredException()
            }
            throw e
        }
    }

    private companion object {
        const val WATER_ORIGIN = "https://ecard.xhu.edu.cn"
        const val SUCCESS_CODE = "000000"
    }
}

class WaterAuthExpiredException : RuntimeException("用水服务登录状态已失效，请更新 JSESSIONID")

class WaterRequestException(message: String) : RuntimeException(message)
