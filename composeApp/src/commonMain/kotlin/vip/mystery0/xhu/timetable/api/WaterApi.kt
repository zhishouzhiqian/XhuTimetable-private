package vip.mystery0.xhu.timetable.api

import de.jensklingenberg.ktorfit.http.Body
import de.jensklingenberg.ktorfit.http.Header
import de.jensklingenberg.ktorfit.http.POST
import de.jensklingenberg.ktorfit.http.Query
import vip.mystery0.xhu.timetable.model.water.WaterCommandRequest
import vip.mystery0.xhu.timetable.model.water.WaterCommandResponse

interface WaterApi {
    @POST("boiling/termcodeOpenValve")
    suspend fun startWater(
        @Header("Cookie") sessionCookie: String,
        @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String,
        @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String,
        @Header("Origin") origin: String,
        @Header("Referer") referer: String,
        @Query("openid") openId: String,
        @Body request: WaterCommandRequest,
    ): WaterCommandResponse

    @POST("boiling/endUse")
    suspend fun stopWater(
        @Header("Cookie") sessionCookie: String,
        @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String,
        @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String,
        @Header("Origin") origin: String,
        @Header("Referer") referer: String,
        @Query("openid") openId: String,
        @Body request: WaterCommandRequest,
    ): WaterCommandResponse
}
