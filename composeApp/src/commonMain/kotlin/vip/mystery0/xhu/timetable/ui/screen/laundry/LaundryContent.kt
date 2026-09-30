package vip.mystery0.xhu.timetable.ui.screen.laundry

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.LocalLaundryService
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import vip.mystery0.xhu.timetable.model.laundry.*

data class LaundryActions(
    val back: () -> Unit,
    val scan: () -> Unit,
    val orders: () -> Unit,
    val refresh: () -> Unit,
    val selectProgram: (String) -> Unit,
    val pay: (String) -> Unit,
    val resumePayment: () -> Unit,
    val acknowledgePayment: () -> Unit,
    val relogin: () -> Unit = {},
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LaundryContent(state: LaundryUiState, actions: LaundryActions) {
    var confirmAmount by rememberSaveable { mutableStateOf<String?>(null) }
    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(when (state.page) {
                    LaundryPage.Programs -> "洗衣下单"
                    LaundryPage.Payment -> "订单付款"
                    LaundryPage.Orders -> "洗衣订单"
                    else -> "洗衣服务"
                }) },
                navigationIcon = {
                    IconButton(onClick = actions.back) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回")
                    }
                },
                actions = {
                    if (state.page == LaundryPage.Home || state.page == LaundryPage.Programs) {
                        TextButton(onClick = actions.orders, enabled = !state.busy) { Text("订单") }
                    }
                },
            )
        },
        bottomBar = {
            if (state.page == LaundryPage.Programs) {
                PaymentBar(state) { confirmAmount = state.quote?.pay }
            }
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(if (state.page == LaundryPage.Programs) 10.dp else 16.dp),
        ) {
            state.error?.let { message ->
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                    Column(Modifier.fillMaxWidth().padding(16.dp)) {
                        Text(message, color = MaterialTheme.colorScheme.onErrorContainer)
                        TextButton(onClick = actions.refresh, enabled = !state.busy && !state.quoteLoading) {
                            Text("重试")
                        }
                    }
                }
            }
            when (state.page) {
                LaundryPage.Loading -> {
                    if (state.busy) CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
                    Text(if (state.error == null) "正在加载…" else "暂时无法加载洗衣服务",
                        Modifier.align(Alignment.CenterHorizontally))
                }
                LaundryPage.Home -> HomeContent(state, actions)
                LaundryPage.Programs -> ProgramsContent(state, actions)
                LaundryPage.Payment -> PaymentContent(state, actions)
                LaundryPage.Orders -> OrdersContent(state, actions)
            }
        }
    }
    confirmAmount?.let { amount ->
        Dialog(onDismissRequest = { confirmAmount = null }) {
            Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                Column(Modifier.widthIn(max = 360.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("确认支付", style = MaterialTheme.typography.titleMedium)
                    Surface(shape = RoundedCornerShape(12.dp), color = MaterialTheme.colorScheme.surface) {
                        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(state.device?.programs?.firstOrNull { it.key == state.selectedProgram }?.name.orEmpty(),
                                Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            Text("¥$amount", style = MaterialTheme.typography.titleLarge,
                                color = MaterialTheme.colorScheme.primary)
                        }
                    }
                    Text("请放好衣物、关好机门。\n支付成功后设备可能立即运行。",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                        TextButton(onClick = { confirmAmount = null }) { Text("返回") }
                        Button(onClick = { confirmAmount = null; actions.pay(amount) },
                            enabled = !state.busy && !state.quoteLoading && state.quote?.pay == amount) {
                            Text("确认支付")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ColumnScope.HomeContent(state: LaundryUiState, actions: LaundryActions) {
    state.payment?.let { payment ->
        if (payment.status == LaundryPaymentStatus.Success) {
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("付款成功", Modifier.weight(1f), color = MaterialTheme.colorScheme.primary)
                    TextButton(onClick = actions.acknowledgePayment, enabled = !state.busy) { Text("知道了") }
                }
            }
        } else PaymentCard(payment, state.busy, actions)
    }
    val running = state.orders.filter { it.running }
    val waiting = state.orders.filter { it.waitingForDevice }
    val awaiting = (state.payment?.takeIf { it.status == LaundryPaymentStatus.Success }
        ?: state.acknowledgedPaidOrder)?.takeIf { paid -> state.orders.none { it.reference == paid.reference } }
    waiting.forEach { order ->
        ActiveOrderCard(order, state.stale)
    }
    if (awaiting != null) {
        ActiveOrderCard(LaundryOrder(awaiting.device, awaiting.program, awaiting.location,
            "已付款，等待设备运行", waitingForDevice = true), state.stale)
    }
    if (running.isEmpty() && waiting.isEmpty() && awaiting == null && state.payment == null) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.fillMaxWidth().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Icon(Icons.Default.LocalLaundryService, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
                Text("扫码洗衣", style = MaterialTheme.typography.headlineSmall)
                Text("扫描洗衣机二维码，选择适合的洗衣程序", color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button(onClick = actions.scan, enabled = !state.busy) {
                    Icon(Icons.Default.QrCodeScanner, null, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("扫码洗衣")
                }
            }
        }
    }
    if (running.isNotEmpty()) {
        SectionHeading("洗衣进行中", running.size)
        running.forEach { ActiveOrderCard(it, state.stale) }
    }
    if (running.isNotEmpty() || waiting.isNotEmpty() || awaiting != null) {
        OutlinedButton(onClick = actions.scan, enabled = !state.busy && state.payment == null,
            modifier = Modifier.fillMaxWidth()) { Text("扫描其他洗衣机") }
    }
    if (state.stale) Text("当前显示上次结果，请刷新确认。", color = MaterialTheme.colorScheme.error)
    TextButton(onClick = actions.refresh, enabled = !state.busy && !state.ordersLoading,
        modifier = Modifier.align(Alignment.CenterHorizontally)) {
        Text(if (state.ordersLoading) "正在刷新…" else "刷新状态")
    }
}

@Composable
private fun ProgramsContent(state: LaundryUiState, actions: LaundryActions) {
    val device = state.device ?: return
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            LaundryIcon()
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(device.name, style = MaterialTheme.typography.titleSmall)
                if (device.location.isNotBlank()) Text(device.location, style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            StatusPill(device.status.ifBlank { if (device.canUse) "可用" else "不可用" },
                if (device.canUse) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
        }
    }
    Text("选择程序", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (device.programs.isEmpty()) Text("暂未取得可用程序，请重试或扫描其他设备。")
    val featured = device.programs.firstOrNull { it.name == "标准洗" } ?: device.programs.firstOrNull()
    featured?.let { program ->
        ProgramCard(program, state.selectedProgram == program.key, device.canUse && !state.busy,
            featured = true, modifier = Modifier.fillMaxWidth()) { actions.selectProgram(program.key) }
    }
    device.programs.filter { it.key != featured?.key }.chunked(2).forEach { row ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            row.forEach { program ->
                ProgramCard(program, state.selectedProgram == program.key, device.canUse && !state.busy,
                    featured = false, modifier = Modifier.weight(1f)) { actions.selectProgram(program.key) }
            }
            if (row.size == 1) Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun ProgramCard(program: LaundryProgram, selected: Boolean, enabled: Boolean,
    featured: Boolean, modifier: Modifier, onClick: () -> Unit) {
    OutlinedCard(onClick = onClick, enabled = enabled, modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(if (selected) 1.5.dp else 1.dp,
            if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant),
        colors = CardDefaults.outlinedCardColors(containerColor = if (selected)
            MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.fillMaxWidth().heightIn(min = if (featured) 76.dp else 100.dp).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(program.name, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                if (featured && program.price.isNotBlank()) Text("¥${program.price}",
                    style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                if (selected) Icon(Icons.Default.CheckCircle, "已选择", Modifier.size(18.dp),
                    tint = MaterialTheme.colorScheme.primary)
            }
            if (!featured && program.price.isNotBlank()) Text("¥${program.price}", style = MaterialTheme.typography.titleSmall)
            if (program.details.isNotBlank()) Text(program.details, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun PaymentBar(state: LaundryUiState, confirm: () -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    Surface(shadowElevation = 4.dp, color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val quote = state.quote
            if (expanded && quote != null) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("原价 ¥${quote.total}", style = MaterialTheme.typography.bodySmall)
                    Text("优惠 ¥${quote.discount}", style = MaterialTheme.typography.bodySmall)
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
            val amount: @Composable () -> Unit = {
                Column(Modifier.clickable(enabled = quote != null) { expanded = !expanded }) {
                    Text("应付金额", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(if (state.quoteLoading) "获取报价中…" else quote?.let { "¥${it.pay}" } ?: "暂无报价",
                            style = if (quote != null) MaterialTheme.typography.titleLarge else MaterialTheme.typography.bodyMedium)
                        if (quote != null) Icon(if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                            "金额明细", Modifier.size(20.dp))
                    }
                    if (quote != null && quote.discount.toDoubleOrNull()?.let { it > 0 } == true) {
                        Text("已优惠 ¥${quote.discount}", color = MaterialTheme.colorScheme.primary,
                            style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            val pay: @Composable (Modifier) -> Unit = { modifier ->
                Button(onClick = confirm, modifier = modifier.heightIn(min = 48.dp),
                    enabled = quote != null && !state.quoteLoading && !state.busy && state.device?.canUse == true) {
                    if (state.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("去支付")
                }
            }
            val largeFont = LocalDensity.current.fontScale > 1.3f
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                if (largeFont || maxWidth < 280.dp) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { amount(); pay(Modifier.fillMaxWidth()) }
                } else {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Box(Modifier.weight(1f)) { amount() }
                        pay(Modifier.widthIn(min = 112.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun ColumnScope.PaymentContent(state: LaundryUiState, actions: LaundryActions) {
    state.payment?.let { PaymentCard(it, state.busy, actions) }
    if (state.payment == null) Text("没有未完成的付款。")
    if (state.busy) CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally))
}

@Composable
private fun PaymentCard(payment: LaundryPayment, busy: Boolean, actions: LaundryActions) {
    OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.3f)),
        colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(payment.device.ifBlank { "洗衣订单" }, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                StatusPill(when (payment.status) {
                    LaundryPaymentStatus.Success -> "已付款"
                    LaundryPaymentStatus.Closed -> "已关闭"
                    LaundryPaymentStatus.Unpaid -> "待付款"
                    LaundryPaymentStatus.Paying -> "处理中"
                    LaundryPaymentStatus.Unknown -> "待核验"
                })
            }
            if (payment.location.isNotBlank()) Text(payment.location, style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (payment.program.isNotBlank()) Text("${payment.program} · ¥${payment.amount}", style = MaterialTheme.typography.bodyMedium)
            if (payment.status == LaundryPaymentStatus.Unknown || payment.status == LaundryPaymentStatus.Paying) {
                Text(if (payment.status == LaundryPaymentStatus.Paying) "支付处理中，请稍后核验" else "请先核验付款结果，避免重复下单",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                if (payment.accountMismatch) {
                    OutlinedButton(onClick = actions.relogin, enabled = !busy) { Text("使用原账号登录") }
                } else when (payment.status) {
                    LaundryPaymentStatus.Success, LaundryPaymentStatus.Closed ->
                        TextButton(onClick = actions.acknowledgePayment, enabled = !busy) { Text("知道了") }
                    LaundryPaymentStatus.Unpaid ->
                        Button(onClick = actions.resumePayment, enabled = !busy) { Text("继续微信付款") }
                    else -> OutlinedButton(onClick = actions.refresh, enabled = !busy) { Text("核验付款结果") }
                }
            }
        }
    }
}

@Composable
private fun OrdersContent(state: LaundryUiState, actions: LaundryActions) {
    val pending = state.orders.filter { state.payment == null || state.payment.status == LaundryPaymentStatus.Success ||
        it.reference.isBlank() || it.reference != state.payment.reference }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeading("待处理", pending.size + if (state.payment != null) 1 else 0, "付款核验与当前洗衣状态")
        state.payment?.let { PaymentCard(it, state.busy, actions) }
        if (pending.isEmpty() && state.payment == null) EmptyOrderSection(if (state.ordersLoading) "正在加载订单…" else "暂无待处理订单")
        pending.forEach { if (it.running || it.waitingForDevice) ActiveOrderCard(it, state.stale) else OrderGroup(listOf(it)) }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeading("最近订单", state.history.size, "最近 10 笔记录")
        if (state.history.isEmpty()) EmptyOrderSection(if (state.ordersLoading) "正在加载记录…" else "暂无最近订单")
        else OrderGroup(state.history)
    }
    TextButton(onClick = actions.refresh, enabled = !state.ordersLoading && !state.busy) { Text("刷新订单") }
}

@Composable
private fun ActiveOrderCard(order: LaundryOrder, stale: Boolean) {
    OutlinedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.25f)),
        colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                LaundryIcon()
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(order.name, style = MaterialTheme.typography.titleSmall)
                    if (order.location.isNotBlank()) Text(order.location, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                StatusPill(if (order.running) "运行中" else "待运行")
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            val timer: @Composable () -> Unit = {
                val seconds = order.seconds
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    if (order.running && !stale && seconds != null && seconds > 0) {
                        Text("${(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}",
                            style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.primary)
                        Text("预计剩余时间", style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else Text(when {
                        stale -> "状态待更新"
                        !order.running -> "已付款，等待设备运行"
                        seconds == 0L -> "等待完成确认"
                        else -> "等待剩余时间"
                    }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                }
            }
            if (LocalDensity.current.fontScale > 1.3f) {
                if (order.program.isNotBlank()) Text(order.program, style = MaterialTheme.typography.bodyMedium)
                timer()
            } else Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("洗衣程序", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(order.program.ifBlank { "洗衣中" }, style = MaterialTheme.typography.bodyMedium)
                }
                timer()
            }
        }
    }
}

@Composable
private fun SectionHeading(title: String, count: Int, caption: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            StatusPill(count.toString(), MaterialTheme.colorScheme.onSurfaceVariant)
        }
        caption?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun EmptyOrderSection(message: String) {
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Default.CheckCircle, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.outline)
            Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun OrderGroup(orders: List<LaundryOrder>) {
    Surface(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column {
            orders.forEachIndexed { index, order ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    LaundryIcon(muted = true)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(order.name, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                            StatusPill(when {
                                order.completed || order.status.contains("洗衣完成") -> "已完成"
                                order.status.contains("关闭") -> "已关闭"
                                order.running -> "运行中"
                                order.waitingForDevice -> "待运行"
                                else -> order.status
                            }, if (order.running || order.waitingForDevice) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        val description = listOf(order.program, order.location).filter { it.isNotBlank() }.joinToString(" · ")
                        if (description.isNotBlank()) Text(description, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (index < orders.lastIndex) HorizontalDivider(Modifier.padding(start = 56.dp, end = 14.dp),
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            }
        }
    }
}

@Composable
private fun LaundryIcon(muted: Boolean = false) {
    Surface(shape = RoundedCornerShape(10.dp), color = if (muted) MaterialTheme.colorScheme.surfaceContainerHighest
        else MaterialTheme.colorScheme.primaryContainer) {
        Icon(Icons.Default.LocalLaundryService, null, Modifier.padding(8.dp).size(20.dp),
            tint = if (muted) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary)
    }
}

@Composable
private fun StatusPill(text: String, color: Color = MaterialTheme.colorScheme.primary) {
    Surface(shape = RoundedCornerShape(50), color = color.copy(alpha = 0.1f)) {
        Text(text, Modifier.widthIn(max = 120.dp).padding(horizontal = 8.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelSmall, color = color, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LaundryUnavailableContent(onBack: () -> Unit, onComponentCheck: (() -> Unit)? = null) {
    Scaffold(topBar = {
        CenterAlignedTopAppBar(title = { Text("洗衣服务") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") }
        })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Spacer(Modifier.height(24.dp))
            Icon(Icons.Default.LocalLaundryService, null, Modifier.size(64.dp),
                tint = MaterialTheme.colorScheme.primary)
            Text("iOS 洗衣服务暂未开放", style = MaterialTheme.typography.titleLarge)
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
                Text("校园登录和订单服务正在接入。当前版本暂不能登录、扫码下单或付款。",
                    Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Button(onClick = onBack) { Text("返回课表") }
            onComponentCheck?.let { check -> OutlinedButton(onClick = check) { Text("组件检查") } }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LaundryLoginContent(busy: Boolean, error: String?, onBack: () -> Unit, onLogin: () -> Unit,
    webVisible: Boolean, webContent: @Composable () -> Unit) {
    Scaffold(topBar = {
        CenterAlignedTopAppBar(title = { Text("校园洗衣登录") }, navigationIcon = {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") }
        })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            if (webVisible) {
                Box(Modifier.weight(1f).fillMaxWidth()) { webContent() }
                TextButton(onClick = onLogin, enabled = !busy, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                    Text("重新加载登录页")
                }
            } else {
                Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Icon(Icons.Default.LocalLaundryService, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.height(24.dp))
                    Text("登录校园洗衣", style = MaterialTheme.typography.headlineSmall)
                    Spacer(Modifier.height(12.dp))
                    Text("使用手机号验证码登录", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    error?.let { Text(it, Modifier.padding(top = 16.dp), color = MaterialTheme.colorScheme.error) }
                    Spacer(Modifier.height(24.dp))
                    Button(onClick = onLogin, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("手机号验证码登录") }
                }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}
