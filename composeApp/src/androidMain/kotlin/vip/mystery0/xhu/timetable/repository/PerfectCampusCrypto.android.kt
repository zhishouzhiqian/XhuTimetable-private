package vip.mystery0.xhu.timetable.repository

import java.nio.charset.StandardCharsets
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.io.encoding.Base64

internal actual fun perfectCampusTripleDesEncrypt(plainText: String, key: String): String {
    val cipher = Cipher.getInstance("DESede/CBC/PKCS5Padding")
    cipher.init(
        Cipher.ENCRYPT_MODE,
        SecretKeySpec(key.toByteArray(StandardCharsets.UTF_8), "DESede"),
        IvParameterSpec("66666666".toByteArray(StandardCharsets.UTF_8)),
    )
    return Base64.encode(cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8)))
}
