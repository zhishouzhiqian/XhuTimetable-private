package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.contentColorFor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.maxkeppeker.sheets.core.models.base.Header
import com.maxkeppeker.sheets.core.models.base.rememberUseCaseState
import com.maxkeppeler.sheets.info.InfoDialog
import com.maxkeppeler.sheets.info.models.InfoBody
import com.maxkeppeler.sheets.info.models.InfoSelection
import io.github.vinceglb.filekit.absolutePath
import kotlinx.datetime.LocalDate
import kotlinx.datetime.format
import org.jetbrains.compose.resources.painterResource
import org.koin.compose.viewmodel.koinViewModel
import vip.mystery0.xhu.timetable.base.HandleErrorMessage
import vip.mystery0.xhu.timetable.killCurrentProcess
import vip.mystery0.xhu.timetable.module.PRIVACY_URL
import vip.mystery0.xhu.timetable.ui.navigation.LocalNavController
import vip.mystery0.xhu.timetable.ui.navigation.RouteInit
import vip.mystery0.xhu.timetable.ui.navigation.RouteLogin
import vip.mystery0.xhu.timetable.ui.navigation.RouteMain
import vip.mystery0.xhu.timetable.ui.navigation.RouteSplashImage
import vip.mystery0.xhu.timetable.ui.navigation.replaceTo
import vip.mystery0.xhu.timetable.utils.dateFormatter
import vip.mystery0.xhu.timetable.utils.formatWeekString
import vip.mystery0.xhu.timetable.viewmodel.StarterViewModel
import xhutimetable.composeapp.generated.resources.Res
import xhutimetable.composeapp.generated.resources.ic_app_icon_o

@Composable
fun InitScreen() {
    val viewModel = koinViewModel<StarterViewModel>()
    val navController = LocalNavController.current

    val allowPrivacy by viewModel.allowPrivacy.collectAsState()
    val readyState by viewModel.readyState.collectAsState()

    val useCaseState = rememberUseCaseState(
        visible = false,
        onCloseRequest = {}
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF2196F3))
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.align(Alignment.Center),
        ) {
            Image(
                painter = painterResource(Res.drawable.ic_app_icon_o),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(120.dp)
                    .clip(CircleShape)
            )
            Spacer(modifier = Modifier.height(64.dp))
            LoadingIndicator()
            Spacer(modifier = Modifier.height(32.dp))
            Text("应用加载中...", color = contentColorFor(Color(0xFF2196F3)))
        }
        InfoDialog(
            state = useCaseState,
            properties = DialogProperties(
                dismissOnBackPress = false,
                dismissOnClickOutside = false,
            ),
            header = Header.Default(
                title = "隐私政策",
            ),
            body = InfoBody.Custom {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(buildAnnotatedString {
                        append("本应用尊重并保护所有用户的个人隐私权。")
                        append("为了给您提供更准确、更有人性化的服务，本应用会按照隐私政策的规定使用您的个人信息。")
                        append("可阅读 ")
                        withLink(LinkAnnotation.Url(PRIVACY_URL)) {
                            append("隐私政策")
                        }
                        append(" 。")
                    })
                    Spacer(modifier = Modifier.height(36.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            modifier = Modifier.fillMaxWidth(),
                            onClick = {
                                viewModel.allowPrivacy()
                            }) {
                            Text("同意")
                        }
                        Button(
                            modifier = Modifier.fillMaxWidth(),
                            onClick = {
                                killCurrentProcess()
                            }) {
                            Text("不同意并退出APP")
                        }
                    }
                }
            },
            selection = InfoSelection(withButtonView = false),
        )
    }
    HandleErrorMessage(errorMessage = readyState.errorMessage) {}

    LaunchedEffect(allowPrivacy) {
        if (allowPrivacy) {
            viewModel.doInitAndReady()
        } else {
            useCaseState.show()
        }
    }
    readyState.termStartChangeAlert?.let { alert ->
        fun formatTermDate(date: LocalDate): String =
            "${date.format(dateFormatter)}（${date.dayOfWeek.formatWeekString()}）"

        AlertDialog(
            onDismissRequest = {},
            properties = DialogProperties(
                dismissOnBackPress = false,
                dismissOnClickOutside = false,
            ),
            title = {
                Text(text = "开学时间已更新")
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(text = "旧云端日期：${formatTermDate(alert.oldServerDate)}")
                    Text(text = "新云端日期：${formatTermDate(alert.newServerDate)}")
                    Text(text = "当前自定义日期：${formatTermDate(alert.customDate)}")
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(text = "选择‘同步’，将清除自定义设置，恢复自动跟随服务端开学时间。选择‘不同步’，将保留当前自定义设置，继续按该日期计算教学周。")
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.syncTermStartDate()
                    }
                ) {
                    Text(text = "同步")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        viewModel.keepCustomTermStartDate()
                    }
                ) {
                    Text(text = "不同步")
                }
            },
        )
    }

    if (readyState.canNavigate) {
        if (!readyState.isLogin) {
            navController.replaceTo<RouteInit>(RouteLogin(false))
            return
        }
        if (readyState.splashFile == null || readyState.splashId == null) {
            navController.replaceTo<RouteInit>(RouteMain)
            return
        }

        val splashFilePath = readyState.splashFile!!.absolutePath()
        navController.replaceTo<RouteInit>(RouteSplashImage(splashFilePath, readyState.splashId!!))
    }
}