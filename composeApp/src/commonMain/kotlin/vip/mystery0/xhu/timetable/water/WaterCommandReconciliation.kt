package vip.mystery0.xhu.timetable.water

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import vip.mystery0.xhu.timetable.repository.WaterAuthExpiredException
import vip.mystery0.xhu.timetable.repository.WaterBusinessException
import vip.mystery0.xhu.timetable.repository.WaterMissingParametersException

// 传输失败不代表设备执行失败。仅重查状态，不重发有副作用的命令。
internal suspend fun executeWaterCommandWithReconciliation(
    command: suspend () -> Unit,
    readRunning: suspend () -> Boolean,
    expectedRunning: Boolean,
) {
    try {
        if (withTimeoutOrNull(8_000L) { command(); true } == true) return
    } catch (error: CancellationException) {
        throw error
    } catch (error: WaterAuthExpiredException) {
        throw error
    } catch (error: WaterBusinessException) {
        throw error
    } catch (error: WaterMissingParametersException) {
        throw error
    } catch (_: Exception) {
        // 继续核实；不把服务端的异常响应视为设备未执行。
    }
    val running = withTimeoutOrNull(4_000L) {
        try {
            readRunning()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }
    }
    if (running == expectedRunning) return
    throw WaterCommandUncertainException()
}

internal class WaterCommandUncertainException : RuntimeException(
    "水阀操作结果尚未确认，请刷新状态；如可能正在出水，可直接点击关水",
)
