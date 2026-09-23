package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import vip.mystery0.xhu.timetable.laundry.LaundryServiceController

expect val isLaundryServiceSupported: Boolean

@Composable
internal expect fun LaundryWebSessionView(
    modifier: Modifier,
    controller: LaundryServiceController,
    loginMode: Boolean,
    foreground: Boolean,
)

@Composable
internal expect fun LaundryQrScanner(
    modifier: Modifier,
    onResult: (String) -> Unit,
    onCancel: () -> Unit,
)
