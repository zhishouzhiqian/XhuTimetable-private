package vip.mystery0.xhu.timetable.ui.screen

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import vip.mystery0.xhu.timetable.androidDebugGuestEnabled
import vip.mystery0.xhu.timetable.ui.theme.Theme

@Composable
internal actual fun LaundryServiceHost(scanImmediately: Boolean, onExit: () -> Unit) {
    val context = LocalContext.current
    val currentExit by rememberUpdatedState(onExit)
    val nightMode by Theme.nightMode.collectAsState()
    var launched by rememberSaveable { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        currentExit()
    }
    LaunchedEffect(Unit) {
        if (!launched) {
            launched = true
            if (!androidDebugGuestEnabled) {
                currentExit()
                return@LaunchedEffect
            }
            try {
                launcher.launch(Intent().setClassName(context.packageName,
                    "vip.mystery0.xhu.timetable.laundry.CampusLaundryActivity")
                    .putExtra("scan_immediately", scanImmediately)
                    .putExtra("night_mode", nightMode.name))
            } catch (_: android.content.ActivityNotFoundException) {
                currentExit()
            }
        }
    }
}