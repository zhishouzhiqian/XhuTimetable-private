package vip.mystery0.xhu.timetable.repository

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreCrypto.CCCrypt
import platform.CoreCrypto.kCCAlgorithm3DES
import platform.CoreCrypto.kCCBlockSize3DES
import platform.CoreCrypto.kCCEncrypt
import platform.CoreCrypto.kCCOptionPKCS7Padding
import platform.CoreCrypto.kCCSuccess
import platform.posix.size_tVar
import kotlin.io.encoding.Base64

@OptIn(ExperimentalForeignApi::class)
internal actual fun perfectCampusTripleDesEncrypt(plainText: String, key: String): String {
    val input = plainText.encodeToByteArray()
    val keyBytes = key.encodeToByteArray()
    val iv = "66666666".encodeToByteArray()
    val output = ByteArray(input.size + kCCBlockSize3DES.toInt())
    val moved = memScoped {
        val count = alloc<size_tVar>()
        val status = input.usePinned { inputPin ->
            keyBytes.usePinned { keyPin ->
                iv.usePinned { ivPin ->
                    output.usePinned { outputPin ->
                        CCCrypt(
                            kCCEncrypt,
                            kCCAlgorithm3DES,
                            kCCOptionPKCS7Padding,
                            keyPin.addressOf(0), keyBytes.size.convert(),
                            ivPin.addressOf(0),
                            inputPin.addressOf(0), input.size.convert(),
                            outputPin.addressOf(0), output.size.convert(),
                            count.ptr,
                        )
                    }
                }
            }
        }
        check(status == kCCSuccess) { "完美校园请求加密失败" }
        count.value.toInt()
    }
    return Base64.encode(output.copyOf(moved))
}
