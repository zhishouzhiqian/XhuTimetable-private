package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.twotone.LocalLaundryService
import androidx.compose.material.icons.twotone.QrCodeScanner
import androidx.compose.material.icons.twotone.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import org.koin.compose.viewmodel.koinViewModel
import vip.mystery0.xhu.timetable.model.laundry.LaundryOrderSummary
import vip.mystery0.xhu.timetable.model.laundry.LaundryPhase
import vip.mystery0.xhu.timetable.ui.navigation.LocalNavController
import vip.mystery0.xhu.timetable.ui.theme.XhuIcons
import vip.mystery0.xhu.timetable.utils.asLocalDateTime
import vip.mystery0.xhu.timetable.viewmodel.LaundryViewModel
import kotlin.time.Clock
import kotlin.time.Instant

@Composable
fun LaundryScreen() {
    val navController = LocalNavController.current
    val viewModel = koinViewModel<LaundryViewModel>()
    val state by viewModel.uiState.collectAsState()
    LaunchedEffect(Unit) { viewModel.init() }
    var autoLoginAttempted by remember { mutableStateOf(false) }
    LaunchedEffect(state.phase) {
        if (state.phase == LaundryPhase.NeedsLogin && !autoLoginAttempted) {
            autoLoginAttempted = true
            viewModel.login()
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("洗衣服务") },
                navigationIcon = {
                    IconButton(onClick = { navController.navigateUp() }) {
                        Icon(XhuIcons.back, contentDescription = "返回")
                    }
                },
                actions = {
                    if (state.phase !in setOf(
                            LaundryPhase.LoggingIn,
                            LaundryPhase.Scanning,
                            LaundryPhase.CheckingSession,
                            LaundryPhase.CheckingOrders,
                        )
                    ) {
                        IconButton(onClick = viewModel::refresh) {
                            Icon(Icons.TwoTone.Refresh, contentDescription = "刷新")
                        }
                    }
                },
            )
        },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize().padding(padding)) {
            val showLogin = state.phase == LaundryPhase.LoggingIn
            LaundryWebSessionView(
                modifier = if (showLogin) Modifier.fillMaxSize()
                else Modifier.size(1.dp).alpha(0f),
                controller = viewModel.controller,
                loginMode = showLogin,
                foreground = true,
            )
            if (!showLogin) {
                LaundryContent(
                    state = state,
                    onScan = viewModel::beginScan,
                    onScanResult = viewModel::scanned,
                    onCancelScan = viewModel::cancelScan,
                    onExpectedEnd = viewModel::refreshAtExpectedEnd,
                    onRetry = {
                        if (state.phase == LaundryPhase.NeedsLogin || state.phase == LaundryPhase.Expired) {
                            viewModel.login()
                        }
                        else viewModel.refresh()
                    },
                )
            }
        }
    }
}

@Composable
private fun LaundryContent(
    state: vip.mystery0.xhu.timetable.model.laundry.LaundryUiState,
    onScan: () -> Unit,
    onScanResult: (String) -> Unit,
    onCancelScan: () -> Unit,
    onExpectedEnd: (LaundryOrderSummary) -> Unit,
    onRetry: () -> Unit,
) {
    when (state.phase) {
        LaundryPhase.Scanning -> LaundryQrScanner(
            modifier = Modifier.fillMaxSize(),
            onResult = onScanResult,
            onCancel = onCancelScan,
        )

        LaundryPhase.CheckingSession,
        LaundryPhase.CheckingOrders -> LoadingLaundryContent(
            if (state.phase == LaundryPhase.CheckingSession) "正在检查天猫校园登录" else "正在查询洗衣状态"
        )

        LaundryPhase.Idle -> EmptyLaundryContent(state.message, onScan)
        LaundryPhase.Running -> RunningLaundryContent(state, onScan, onExpectedEnd)
        LaundryPhase.NeedsLogin,
        LaundryPhase.Expired,
        LaundryPhase.Error -> ErrorLaundryContent(
            state.message,
            if (state.phase == LaundryPhase.NeedsLogin || state.phase == LaundryPhase.Expired) "重新登录" else "重试",
            onRetry,
        )
        LaundryPhase.LoggingIn -> Unit
    }
}

@Composable
private fun LoadingLaundryContent(label: String) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        CircularProgressIndicator()
        Text(label)
    }
}

@Composable
private fun EmptyLaundryContent(message: String, onScan: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Icon(Icons.TwoTone.LocalLaundryService, null, modifier = Modifier.size(72.dp))
        Text("当前没有进行中的洗衣任务", style = MaterialTheme.typography.titleMedium)
        if (message.isNotBlank()) Text(message, color = MaterialTheme.colorScheme.primary)
        Button(onClick = onScan) {
            Icon(Icons.TwoTone.QrCodeScanner, null)
            Spacer(Modifier.width(8.dp))
            Text("扫描洗衣机")
        }
        Text(
            "首轮版本只识别二维码，不会创建订单、扣款或启动设备。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun RunningLaundryContent(
    state: vip.mystery0.xhu.timetable.model.laundry.LaundryUiState,
    onScan: () -> Unit,
    onRefresh: (LaundryOrderSummary) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (state.stale) {
            item {
                Text(
                    "网络异常，以下为上次查询结果，数据可能已过期。",
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
        if (state.message.isNotBlank()) item { Text(state.message) }
        items(state.orders, key = { it.orderId }) { order ->
            LaundryOrderCard(order, onRefresh)
        }
        item {
            Button(onClick = onScan, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.TwoTone.QrCodeScanner, null)
                Spacer(Modifier.width(8.dp))
                Text("扫描其他洗衣机")
            }
        }
    }
}

@Composable
private fun LaundryOrderCard(order: LaundryOrderSummary, onExpired: (LaundryOrderSummary) -> Unit) {
    var now by remember { mutableLongStateOf(Clock.System.now().toEpochMilliseconds()) }
    LaunchedEffect(order.orderId, order.expectedEndAtEpochMillis) {
        while (true) {
            now = Clock.System.now().toEpochMilliseconds()
            delay(1_000)
        }
    }
    val remaining = order.expectedEndAtEpochMillis?.minus(now)?.coerceAtLeast(0)
    LaunchedEffect(order.orderId, order.expectedEndAtEpochMillis) {
        val wait = order.expectedEndAtEpochMillis?.minus(Clock.System.now().toEpochMilliseconds())
            ?: return@LaunchedEffect
        if (wait > 0) delay(wait)
        onExpired(order)
    }
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.TwoTone.LocalLaundryService, null)
                Spacer(Modifier.width(10.dp))
                Text(order.deviceName, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
            }
            if (order.deviceType.isNotBlank()) Text("设备类型：${order.deviceType}")
            Text("状态：洗衣进行中")
            Text(
                remaining?.let(::formatRemaining) ?: "预计完成时间暂不可用",
                color = MaterialTheme.colorScheme.primary,
                style = MaterialTheme.typography.titleLarge,
            )
            order.expectedEndAtEpochMillis?.let { end ->
                val time = Instant.fromEpochMilliseconds(end).asLocalDateTime()
                Text("预计完成：${time.monthNumber}月${time.dayOfMonth}日 ${time.hour.twoDigits()}:${time.minute.twoDigits()}")
            }
        }
    }
}

private fun formatRemaining(millis: Long): String {
    val totalSeconds = millis / 1_000
    val hours = totalSeconds / 3_600
    val minutes = totalSeconds % 3_600 / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) "剩余 $hours:${minutes.twoDigits()}:${seconds.twoDigits()}"
    else "剩余 ${minutes.twoDigits()}:${seconds.twoDigits()}"
}

private fun Number.twoDigits(): String = toString().padStart(2, '0')

@Composable
private fun ErrorLaundryContent(message: String, buttonLabel: String, onRetry: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Text(message.ifBlank { "暂时无法使用洗衣服务" })
        Button(onClick = onRetry) { Text(buttonLabel) }
    }
}
