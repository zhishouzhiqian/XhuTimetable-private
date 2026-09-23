package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import vip.mystery0.xhu.timetable.laundry.LaundryServiceController

actual val isLaundryServiceSupported: Boolean = false

@Composable
internal actual fun LaundryWebSessionView(
    modifier: Modifier,
    controller: LaundryServiceController,
    loginMode: Boolean,
    foreground: Boolean,
) = Unit

@Composable
internal actual fun LaundryQrScanner(
    modifier: Modifier,
    onResult: (String) -> Unit,
    onCancel: () -> Unit,
) {
    LaunchedEffect(Unit) { onCancel() }
}
