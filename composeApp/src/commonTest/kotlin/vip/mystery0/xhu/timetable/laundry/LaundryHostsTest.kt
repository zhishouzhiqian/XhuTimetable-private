package vip.mystery0.xhu.timetable.laundry

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LaundryHostsTest {
    @Test
    fun allowsOnlyListedDomainFamilies() {
        assertTrue(isAllowedLaundryHost("share.confong.cn"))
        assertTrue(isAllowedLaundryHost("login.m.taobao.com"))
        assertFalse(isAllowedLaundryHost("evilconfong.cn"))
        assertFalse(isAllowedLaundryHost("confong.cn.evil.example"))
        assertFalse(isAllowedLaundryHost(null))
    }
}
