package vip.mystery0.xhu.timetable.laundry

import android.view.Window
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.luminance
import androidx.core.view.WindowCompat

/** 跟随应用实际配色，兼容应用强制深色而系统仍为浅色的情况。 */
@Composable
internal fun LaundrySystemBars(window: Window) {
    val light = MaterialTheme.colorScheme.surface.luminance() > 0.5f
    SideEffect {
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = light
            isAppearanceLightNavigationBars = light
        }
    }
}
