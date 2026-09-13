package vip.mystery0.xhu.timetable.widget

import co.touchlab.kermit.Logger
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import platform.Foundation.NSThread
import vip.mystery0.xhu.timetable.config.store.EventBus
import kotlin.time.Clock

/** Swift 在主线程管理前后台生命周期，快照回调也仅在主线程同步执行。 */
@OptIn(ExperimentalForeignApi::class)
object IosWidgetBridge {
    private val logger = Logger.withTag("IosWidgetBridge")
    private var scope: CoroutineScope? = null
    private var callback: ((String) -> Unit)? = null
    private var clearedRevision = 0L

    fun start(onSnapshot: (String) -> Unit) {
        check(NSThread.isMainThread) { "Widget lifecycle must run on the main thread" }
        callback = onSnapshot
        if (scope != null) {
            refresh()
            return
        }
        val activeScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        scope = activeScope
        activeScope.launch {
            // 不消费 SingleEvent，避免干扰主应用已有观察者。
            EventBus.flow.collect {
                it.peekContent()
                WidgetRefreshSignal.request()
            }
        }
        activeScope.launch {
            WidgetRefreshSignal.changes.collectLatest { request ->
                val revision = request.revision
                // 账号或设置变化才清除旧数据；普通前台刷新保留有效快照，避免退后台时留下空白。
                if (request.invalidatedAt > clearedRevision) {
                    publish(WidgetSnapshot.empty("unavailable", Clock.System.now().toEpochMilliseconds()), revision)
                    if (WidgetRefreshSignal.changes.value.revision == revision) {
                        clearedRevision = request.invalidatedAt
                    }
                }
                delay(150)
                val snapshot = try {
                    WidgetSnapshotRepo.generate()
                } catch (exception: CancellationException) {
                    throw exception
                } catch (_: Exception) {
                    logger.w("Failed to generate widget snapshot")
                    WidgetSnapshot.empty("unavailable", Clock.System.now().toEpochMilliseconds())
                }
                currentCoroutineContext().ensureActive()
                publish(snapshot, revision)
            }
        }
    }

    fun refresh() {
        WidgetRefreshSignal.request()
    }

    fun stop() {
        check(NSThread.isMainThread) { "Widget lifecycle must run on the main thread" }
        scope?.cancel()
        scope = null
        callback = null
    }

    private suspend fun publish(snapshot: WidgetSnapshot, revision: Long) {
        currentCoroutineContext().ensureActive()
        if (WidgetRefreshSignal.changes.value.revision != revision) return
        // 编码结束后再次检查版本，避免编码期间的账号写入发布旧结果。
        val json = snapshot.encode()
        currentCoroutineContext().ensureActive()
        if (WidgetRefreshSignal.changes.value.revision == revision) {
            callback?.invoke(json)
        }
    }
}
