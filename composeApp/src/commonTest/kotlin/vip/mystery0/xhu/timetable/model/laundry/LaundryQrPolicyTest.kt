package vip.mystery0.xhu.timetable.model.laundry

import io.ktor.http.encodeURLParameter
import kotlin.test.*

class LaundryQrPolicyTest {
    private val valid = "https://share.confong.cn/cf?biz=mock&isv=mock&id=mock-device_1"
    @Test fun acceptsDeviceNumberAndDecodesOneOfficialWrapper() {
        assertEquals("mock-device_1", LaundryQrPolicy.deviceNumber(valid))
        assertEquals("mock-device_1", LaundryQrPolicy.deviceNumber(
            "https://share.confong.cn/app/tmall-xiaoyuan/tmxy-m-share/laundry/deviceDetail?result=${valid.encodeURLParameter()}"))
    }
    @Test fun rejectsOtherOriginsAndNonHttps() {
        listOf(valid.replace("https", "http"), valid.replace("share.confong.cn", "example.invalid"),
            valid.replace("share.confong.cn", "share.confong.cn.example.invalid"), "weixin://mock").forEach {
            assertNull(LaundryQrPolicy.deviceNumber(it))
        }
    }
    @Test fun rejectsMissingContextUnsafeIdsAndOversizedQr() {
        listOf(valid.replace("biz=mock&", ""), valid.replace("isv=mock&", ""),
            valid.replace("mock-device_1", ""), valid.replace("mock-device_1", "../mock"),
            valid.replace("mock-device_1", "x".repeat(129)), valid + "&extra=" + "x".repeat(2048)).forEach {
            assertNull(LaundryQrPolicy.deviceNumber(it))
        }
    }
    @Test fun wrapperCannotBypassOriginOrNestTwice() {
        val wrapper = "https://share.confong.cn/app/tmall-xiaoyuan/tmxy-m-share/laundry/deviceDetail?result="
        assertNull(LaundryQrPolicy.deviceNumber(wrapper + valid.replace("share.confong.cn", "example.invalid").encodeURLParameter()))
        assertNull(LaundryQrPolicy.deviceNumber(wrapper + (wrapper + valid.encodeURLParameter()).encodeURLParameter()))
    }
}
