package vip.mystery0.xhu.timetable.repository

import dev.whyoleg.cryptography.BinarySize.Companion.bits
import dev.whyoleg.cryptography.CryptographyProvider
import dev.whyoleg.cryptography.algorithms.RSA
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.URLBuilder
import io.ktor.http.contentType
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import vip.mystery0.xhu.timetable.utils.sha256
import kotlin.io.encoding.Base64

class PerfectCampusRepository(private val client: HttpClient) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private var pending: PendingLogin? = null

    suspend fun requestSms(phone: String, deviceId: String) {
        val login = exchange(phone.trim(), deviceId)
        val response = postEncrypted(SMS_URL, login, SmsRequest(deviceId = deviceId, mobile = phone.trim()))
        if (!response.result) throw PerfectCampusException(response.message.ifBlank { "短信验证码发送失败" })
        pending = login
    }

    suspend fun completeSms(code: String): String {
        val login = pending ?: throw PerfectCampusException("请先获取短信验证码")
        val response = postEncrypted(
            SMS_LOGIN_URL,
            login,
            SmsLoginRequest(deviceId = login.deviceId, mobile = login.phone, sms = code.trim()),
        )
        if (!response.result) throw PerfectCampusException(response.message.ifBlank { "完美校园登录失败" })
        pending = null
        return login.sessionId
    }

    fun authorizationUrl(token: String): String = buildPerfectCampusAuthorizationUrl(token)

    fun cancelLogin() { pending = null }

    private suspend fun exchange(phone: String, deviceId: String): PendingLogin {
        require(phone.isNotBlank() && deviceId.isNotBlank())
        val algorithm = CryptographyProvider.Default.get(RSA.PKCS1)
        val keys = algorithm.keyPairGenerator(1024.bits).generateKey()
        val pem = keys.publicKey.encodeToByteArray(RSA.PublicKey.Format.PEM.Generic).decodeToString()
        val publicKey = pem.lineSequence().filterNot { it.startsWith("---") }.joinToString("")
        val encrypted: String = client.post(EXCHANGE_URL) {
            contentType(ContentType.Application.Json)
            setBody(json.encodeToString(ExchangeRequest(publicKey)))
        }.body()
        val plain = keys.privateKey.decryptor().decrypt(Base64.decode(encrypted.trim())).decodeToString()
        val response = json.decodeFromString<ExchangeResponse>(plain)
        if (response.session.isBlank() || response.key.length < 24) {
            throw PerfectCampusException("完美校园密钥交换响应无效")
        }
        return PendingLogin(phone, deviceId, response.session, response.key.take(24))
    }

    private suspend fun postEncrypted(url: String, login: PendingLogin, request: Any): LoginResponse {
        val requestJson = when (request) {
            is SmsRequest -> json.encodeToString(request)
            is SmsLoginRequest -> json.encodeToString(request)
            else -> error("Unsupported request")
        }
        val payload = EncryptedRequest(login.sessionId, perfectCampusTripleDesEncrypt(requestJson, login.appKey))
        val body = json.encodeToString(payload)
        return client.post(url) {
            contentType(ContentType.Application.Json)
            header("campusSign", body.sha256())
            setBody(body)
        }.body()
    }

    private data class PendingLogin(val phone: String, val deviceId: String, val sessionId: String, val appKey: String)
}

internal expect fun perfectCampusTripleDesEncrypt(plainText: String, key: String): String

internal fun buildPerfectCampusAuthorizationUrl(token: String): String = URLBuilder(AUTHORIZE_URL).apply {
    parameters.append("client_id", "96aacfe177204f1ca5a4ab348c18a3ee")
    parameters.append("customerId", "651")
    parameters.append("redirect_uri", "https://ecard.xhu.edu.cn/homedwapp/openHomePage")
    parameters.append("response_type", "code")
    parameters.append("state", "waterpage")
    parameters.append("systemType", "IOS")
    parameters.append("UAinfo", "wanxiao")
    parameters.append("versioncode", "10589102")
    parameters.append("versionnum", "1050834102")
    parameters.append("token", token)
}.buildString()

@Serializable private data class ExchangeRequest(val key: String)
@Serializable private data class ExchangeResponse(val session: String = "", val key: String = "")
@Serializable private data class EncryptedRequest(val session: String, val data: String)
@Serializable private data class LoginResponse(
    @SerialName("result_") val result: Boolean = false,
    @SerialName("message_") val message: String = "",
)
@Serializable private data class SmsRequest(
    val action: String = "registAndLogin",
    val deviceId: String,
    val mobile: String,
    val requestMethod: String = "cam_iface46/gainMatrixCaptcha.action",
    val type: String = "sms",
)
@Serializable private data class SmsLoginRequest(
    val appCode: String = "M002",
    val deviceId: String,
    val netWork: String = "wifi",
    val qudao: String = "guanwang",
    val requestMethod: String = "cam_iface46/registerUsersByTelAndLoginNew.action",
    val shebeixinghao: String = "iPhone",
    val sms: String,
    val systemType: String = "iphone",
    val telephoneInfo: String = "ios",
    val telephoneModel: String = "iPhone",
    val mobile: String,
    val type: String = "2",
    val wanxiaoVersion: Int = 10589102,
)

class PerfectCampusException(message: String) : RuntimeException(message)

private const val EXCHANGE_URL = "https://app.17wanxiao.com/campus/cam_iface46/exchangeSecretkey.action"
private const val SMS_URL = "https://app.17wanxiao.com/campus/cam_iface46/gainMatrixCaptcha.action"
private const val SMS_LOGIN_URL = "https://app.17wanxiao.com/campus/cam_iface46/registerUsersByTelAndLoginNew.action"
private const val AUTHORIZE_URL = "https://open.17wanxiao.com/api/authorize"
