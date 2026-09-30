package vip.mystery0.xhu.timetable.laundry

import android.os.SystemClock
import kotlinx.coroutines.*
import vip.mystery0.xhu.timetable.viewmodel.LaundryViewModel

internal typealias LaundryCommandType = vip.mystery0.xhu.timetable.model.laundry.LaundryCommandType
internal typealias LaundryCommand = vip.mystery0.xhu.timetable.model.laundry.LaundryCommand

/** Android 宿主保留原 Factory 和校园串行线程，业务状态由共享层管理。 */
internal class CampusLaundryViewModel(
    client: CampusLaundryGateway,
    autoScan: Boolean,
    externalInFlight: Boolean = false,
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    ioDispatcher: CoroutineDispatcher? = null,
    elapsedRealtime: () -> Long = { SystemClock.elapsedRealtime() },
    quotePause: suspend () -> Unit = { delay(150) },
) : LaundryViewModel(CampusTypedLaundryGateway(client), autoScan, externalInFlight, scope,
    ioDispatcher ?: CampusLaundryRuntime.dispatcher, elapsedRealtime, quotePause)
