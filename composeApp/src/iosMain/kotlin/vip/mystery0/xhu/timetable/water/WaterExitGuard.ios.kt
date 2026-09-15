package vip.mystery0.xhu.timetable.water

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.koin.mp.KoinPlatform

actual fun platformSetWaterRunning(running: Boolean) = Unit

object IosWaterExitBridge {
    fun stopIfRunning() {
        runBlocking(Dispatchers.Default) {
            withTimeoutOrNull(4_000) {
                KoinPlatform.getKoin().get<WaterServiceController>().bestEffortStopAfterExit()
            }
        }
    }
}
