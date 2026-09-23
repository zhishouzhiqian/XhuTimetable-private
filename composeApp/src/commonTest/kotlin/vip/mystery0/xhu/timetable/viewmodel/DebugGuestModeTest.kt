package vip.mystery0.xhu.timetable.viewmodel

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DebugGuestModeTest {
    @Test
    fun debugBuildCanEnterWithoutSchoolAccount() {
        assertTrue(canEnterHome(isLoggedIn = false, debugBuild = true))
    }

    @Test
    fun releaseBuildStillRequiresSchoolAccount() {
        assertFalse(canEnterHome(isLoggedIn = false, debugBuild = false))
        assertTrue(canEnterHome(isLoggedIn = true, debugBuild = false))
    }
}
