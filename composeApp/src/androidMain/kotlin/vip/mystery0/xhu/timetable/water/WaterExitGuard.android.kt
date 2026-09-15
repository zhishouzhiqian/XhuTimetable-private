package vip.mystery0.xhu.timetable.water

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import org.koin.core.component.KoinComponent
import org.koin.core.component.inject
import org.koin.mp.KoinPlatform
import vip.mystery0.xhu.timetable.repository.WaterNetworkException

actual fun platformSetWaterRunning(running: Boolean) {
    val context = KoinPlatform.getKoin().get<Context>()
    val intent = Intent(context, WaterExitGuardService::class.java)
    runCatching {
        if (running) context.startService(intent) else context.stopService(intent)
    }
}

class WaterExitGuardService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        WaterStopWorker.enqueue(applicationContext)
        stopSelf()
    }
}

class WaterStopWorker(
    appContext: Context,
    workerParams: WorkerParameters,
) : CoroutineWorker(appContext, workerParams), KoinComponent {
    private val controller: WaterServiceController by inject()

    override suspend fun doWork(): Result = try {
        if (controller.bestEffortStopAfterExit()) Result.success() else Result.failure()
    } catch (_: WaterNetworkException) {
        Result.retry()
    } catch (_: Throwable) {
        Result.failure()
    }

    companion object {
        private const val UNIQUE_NAME = "water-exit-stop"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<WaterStopWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                UNIQUE_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }
    }
}
