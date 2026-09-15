package vip.mystery0.xhu.timetable.api

import de.jensklingenberg.ktorfit.http.Body
import de.jensklingenberg.ktorfit.http.GET
import de.jensklingenberg.ktorfit.http.Header
import de.jensklingenberg.ktorfit.http.POST
import de.jensklingenberg.ktorfit.http.Query
import vip.mystery0.xhu.timetable.model.water.WaterCommandRequest
import vip.mystery0.xhu.timetable.model.water.WaterCommandResponse
import vip.mystery0.xhu.timetable.model.water.WaterDeviceListRequest
import vip.mystery0.xhu.timetable.model.water.WaterDeviceListResponse
import vip.mystery0.xhu.timetable.model.water.WaterBalanceResponse
import vip.mystery0.xhu.timetable.model.water.WaterHomeRequest
import vip.mystery0.xhu.timetable.model.water.WaterHomeResponse
import vip.mystery0.xhu.timetable.model.water.WaterRawResponse
import vip.mystery0.xhu.timetable.model.water.WaterUseRecordResponse

interface WaterApi {
    @POST("waterpage/waterHomePage")
    suspend fun getWaterHome(
        @Header("Cookie") sessionCookie: String, @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String, @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String, @Header("Origin") origin: String,
        @Header("Referer") referer: String, @Body request: WaterHomeRequest,
    ): WaterHomeResponse

    @GET("home/openHomePageApp")
    suspend fun getBalance(
        @Header("Cookie") sessionCookie: String, @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String, @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String, @Header("Origin") origin: String,
        @Header("Referer") referer: String, @Query("openid") openId: String,
        @Query("unionid") unionId: String, @Query("usertype") userType: String,
        @Query("orgid") queryOrgId: String,
    ): WaterBalanceResponse

    @POST("bathroom/getUseWaterRecord")
    suspend fun getUseWaterRecords(
        @Header("Cookie") sessionCookie: String, @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String, @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String, @Header("Origin") origin: String,
        @Header("Referer") referer: String, @Body request: WaterHomeRequest,
    ): WaterUseRecordResponse

    @POST("bathroom/selectCloseDeviceValve")
    suspend fun getRunningState(
        @Header("Cookie") sessionCookie: String, @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String, @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String, @Header("Origin") origin: String,
        @Header("Referer") referer: String, @Body request: WaterHomeRequest,
    ): WaterRawResponse

    @POST("bathroom/getOftenUsetermList")
    suspend fun getOftenUsedDevices(
        @Header("Cookie") sessionCookie: String,
        @Header("orgid") orgId: String,
        @Header("session-type") sessionType: String,
        @Header("isWechatApp") isWechatApp: String,
        @Header("x-requested-with") requestedWith: String,
        @Header("Origin") origin: String,
        @Header("Referer") referer: String,
        @Query("openid") openId: String,
        @Body request: WaterDeviceListRequest,
    ): WaterDeviceListResponse

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
