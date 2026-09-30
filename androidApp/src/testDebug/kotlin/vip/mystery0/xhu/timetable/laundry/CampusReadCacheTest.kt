package vip.mystery0.xhu.timetable.laundry

import org.json.JSONArray
import org.json.JSONObject
import kotlin.test.*

class CampusReadCacheTest {
    private fun cache() = CampusReadCache().apply { session("mock-user", "mock-session") }
    private fun rows() = JSONArray().put(JSONObject().put("remainSeconds", 119))

    @Test fun loginHandoffIsOneShotAndKeepsOriginalSamplingTime() {
        val cache = cache()
        val rows = rows()
        cache.verified(rows, 1000, 2000)
        cache.allowLoginHandoff()
        rows.getJSONObject(0).put("remainSeconds", 1)
        assertTrue(cache.takeLoginHandoff(3000))
        assertFalse(cache.takeLoginHandoff(3000))
        val snapshot = cache.takeUrgent(3000)!!
        assertEquals(1000L, snapshot.observedAt)
        assertEquals(119, snapshot.orders.getJSONObject(0).getInt("remainSeconds"))
        assertNull(cache.takeUrgent(3000))
    }
    @Test fun expiredOrFutureVerificationNeverReusesOrders() {
        val cache = cache()
        cache.verified(rows(), 1000, 2000)
        cache.allowLoginHandoff()
        assertFalse(cache.takeLoginHandoff(32001))
        assertNull(cache.takeUrgent(32001))
        cache.verified(rows(), 5000, 5000)
        cache.allowLoginHandoff()
        assertFalse(cache.takeLoginHandoff(4000))
        assertNull(cache.takeUrgent(4000))
    }
    @Test fun sessionChangeDropsHandoffAndAllDeviceMappings() {
        val cache = cache()
        cache.rememberDevice("mock-device", "mock-id")
        cache.verified(rows(), 1000, 1000)
        cache.allowLoginHandoff()
        assertTrue(cache.session("other-user", "other-session"))
        assertNull(cache.device("mock-device"))
        assertFalse(cache.takeLoginHandoff(2000))
        assertNull(cache.takeUrgent(2000))
    }
    @Test fun sameAccountWithChangedSessionAlsoInvalidatesMappings() {
        val cache = cache()
        cache.rememberDevice("mock-device", "mock-id")
        assertFalse(cache.session("mock-user", "mock-session"))
        assertEquals("mock-id", cache.device("mock-device"))
        assertTrue(cache.session("mock-user", "renewed-session"))
        assertNull(cache.device("mock-device"))
    }
    @Test fun deviceMappingsUseBoundedLruAndCanBeRejectedIndividually() {
        val cache = cache()
        repeat(16) { cache.rememberDevice("res-$it", "id-$it") }
        assertEquals("id-0", cache.device("res-0"))
        cache.rememberDevice("res-16", "id-16")
        assertNull(cache.device("res-1"))
        assertEquals("id-0", cache.device("res-0"))
        cache.forgetDevice("res-0")
        assertNull(cache.device("res-0"))
        assertEquals("id-16", cache.device("res-16"))
    }
    @Test fun freshQueryDiscardsVerificationAndRequiresNewServerData() {
        val cache = cache()
        cache.verified(rows(), 1000, 1000)
        cache.allowLoginHandoff()
        cache.discardUrgent()
        assertFalse(cache.takeLoginHandoff(2000))
        assertNull(cache.takeUrgent(2000))
    }
}
