package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.runtime.Composable
import vip.mystery0.xhu.timetable.ui.navigation.LocalNavController

/** 主路由只负责导航；平台宿主负责校园组件与页面生命周期。 */
@Composable
fun LaundryScreen(scanImmediately: Boolean = false) {
    val navController = LocalNavController.current
    LaundryServiceHost(scanImmediately) { navController.popBackStack() }
}

@Composable
internal expect fun LaundryServiceHost(scanImmediately: Boolean, onExit: () -> Unit)
