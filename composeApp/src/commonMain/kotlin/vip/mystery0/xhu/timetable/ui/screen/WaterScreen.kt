package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import org.koin.compose.viewmodel.koinViewModel
import vip.mystery0.xhu.timetable.base.HandleErrorMessage
import vip.mystery0.xhu.timetable.Platform
import vip.mystery0.xhu.timetable.platform
import vip.mystery0.xhu.timetable.model.water.PerfectCampusLoginState
import vip.mystery0.xhu.timetable.model.water.WaterAuthenticationRequest
import vip.mystery0.xhu.timetable.model.water.WaterAuthenticationSource
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterDevice
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.model.water.WaterUseRecord
import vip.mystery0.xhu.timetable.model.water.formatWaterCents
import vip.mystery0.xhu.timetable.ui.navigation.LocalNavController
import vip.mystery0.xhu.timetable.ui.theme.XhuIcons
import vip.mystery0.xhu.timetable.viewmodel.WaterViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WaterScreen() {
    val viewModel = koinViewModel<WaterViewModel>()
    val navController = LocalNavController.current
    val uiState by viewModel.uiState.collectAsState()
    val credentials by viewModel.credentials.collectAsState()
    val availableDevices by viewModel.availableDevices.collectAsState()
    val lastKnownRunning by viewModel.lastKnownRunning.collectAsState()
    val balanceCents by viewModel.balanceCents.collectAsState()
    val records by viewModel.records.collectAsState()
    val lastCostCents by viewModel.lastCostCents.collectAsState()
    val startConfirmation by viewModel.startConfirmation.collectAsState()
    val authenticationRequest by viewModel.authenticationRequest.collectAsState()
    val perfectCampusLoginState by viewModel.perfectCampusLoginState.collectAsState()

    var editing by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        viewModel.init()
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("宿舍用水") },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(XhuIcons.back, contentDescription = "返回")
                    }
                },
                actions = {
                    if (credentials != null && !editing) {
                        TextButton(onClick = { editing = true }) {
                            Text("更新凭据")
                        }
                    }
                },
            )
        },
    ) { paddingValues ->
        if (uiState == WaterUiState.Authenticating ||
            uiState == WaterUiState.RecoveringAuthentication
        ) {
            val automaticRecovery = uiState == WaterUiState.RecoveringAuthentication
            authenticationRequest?.let { request ->
                WaterAuthenticationContent(
                    modifier = Modifier
                        .padding(paddingValues)
                        .fillMaxSize(),
                    request = request,
                    onAuthenticated = viewModel::completeAuthentication,
                    automaticRecovery = automaticRecovery,
                    onCancel = if (automaticRecovery) {
                        viewModel::failAuthenticationRecovery
                    } else {
                        viewModel::cancelAuthentication
                    },
                    onError = if (automaticRecovery) {
                        { viewModel.failAuthenticationRecovery() }
                    } else {
                        viewModel::failAuthentication
                    },
                )
            } ?: CircularProgressIndicator(
                modifier = Modifier.padding(paddingValues).padding(32.dp),
            )
        } else {
            Column(
                modifier = Modifier
                    .padding(paddingValues)
                    .padding(horizontal = 20.dp)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Spacer(Modifier.height(24.dp))
                if (editing ||
                    credentials?.authenticated != true ||
                    credentials?.bound != true ||
                    uiState == WaterUiState.AuthExpired
                ) {
                    WaterCredentialsForm(
                        credentials = credentials,
                        availableDevices = availableDevices,
                        uiState = uiState,
                        onSave = { openId, sessionId, posCode, orgId ->
                            if (viewModel.saveCredentials(openId, sessionId, posCode, orgId)) {
                                editing = false
                            }
                        },
                        onAuthenticate = viewModel::startAuthentication,
                        perfectCampusLoginState = perfectCampusLoginState,
                        onRequestPerfectCampusSms = viewModel::requestPerfectCampusSms,
                        onCompletePerfectCampusSms = viewModel::completePerfectCampusSms,
                        onCancelPerfectCampusLogin = viewModel::cancelPerfectCampusLogin,
                        onCancel = if (credentials == null) null else ({ editing = false }),
                        onClear = if (credentials == null) null else ({ viewModel.clearCredentials() }),
                        onRefreshDevices = viewModel::refreshDevices,
                        onSelectDevice = {
                            viewModel.selectDevice(it)
                            editing = false
                        },
                    )
                } else {
                    WaterControl(
                        uiState = uiState,
                        running = lastKnownRunning,
                        onCheckedChange = { running ->
                            if (running) viewModel.startWater() else viewModel.stopWater()
                        },
                        onUpdateCredentials = { editing = true },
                    )
                    Spacer(Modifier.height(20.dp))
                    WaterAccountSummary(
                        balanceCents = balanceCents,
                        lastCostCents = lastCostCents,
                        records = records,
                        loading = uiState == WaterUiState.Loading,
                        onRefresh = viewModel::refreshOverview,
                    )
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }

    startConfirmation?.let { confirmation ->
        AlertDialog(
            onDismissRequest = viewModel::dismissStartConfirmation,
            title = {
                Text(
                    if (confirmation is WaterStartDecision.LowBalance) "校园卡余额较低"
                    else "无法读取校园卡余额",
                )
            },
            text = {
                Text(
                    when (confirmation) {
                        is WaterStartDecision.LowBalance ->
                            "当前余额 ¥${formatWaterCents(confirmation.balanceCents)}，低于 ¥2.00。仍要开水吗？"
                        WaterStartDecision.BalanceUnavailable ->
                            "完美校园登录未提供微信 openid，无法执行开水前余额检查。请确认校园卡余额充足后再继续。"
                        is WaterStartDecision.Ready -> "确认开水吗？"
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = viewModel::confirmStart) { Text("确认开水") }
            },
            dismissButton = {
                TextButton(onClick = viewModel::dismissStartConfirmation) { Text("取消") }
            },
        )
    }

    HandleErrorMessage(flow = viewModel.errorMessage)
}

@Composable
private fun WaterAccountSummary(
    balanceCents: Long?,
    lastCostCents: Long?,
    records: List<WaterUseRecord>,
    loading: Boolean,
    onRefresh: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text("校园卡余额", style = MaterialTheme.typography.titleMedium)
                    Text(
                        balanceCents?.let { "¥${formatWaterCents(it)}" } ?: "暂未取得",
                        style = MaterialTheme.typography.headlineSmall,
                        color = if (balanceCents != null && balanceCents < 200) {
                            MaterialTheme.colorScheme.error
                        } else MaterialTheme.colorScheme.primary,
                    )
                }
                IconButton(onClick = onRefresh, enabled = !loading) {
                    if (loading) CircularProgressIndicator(modifier = Modifier.size(24.dp))
                    else Icon(XhuIcons.Action.sync, contentDescription = "刷新")
                }
            }
            lastCostCents?.let {
                Text(
                    "本次金额：¥${formatWaterCents(it)}",
                    color = MaterialTheme.colorScheme.outline,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
    Spacer(Modifier.height(20.dp))
    Text("用水记录", style = MaterialTheme.typography.titleLarge, modifier = Modifier.fillMaxWidth())
    Spacer(Modifier.height(8.dp))
    if (records.isEmpty()) {
        Text(
            if (loading) "正在加载记录…" else "暂无用水记录",
            modifier = Modifier.padding(vertical = 20.dp),
            color = MaterialTheme.colorScheme.outline,
        )
    } else {
        records.forEach { record ->
            Card(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Text(record.beginTime.ifBlank { "时间未知" }, style = MaterialTheme.typography.titleSmall)
                    Text(
                        "设备 ${record.posCode.ifBlank { "未知" }} · 金额 ${record.amountFen?.let { "¥${formatWaterCents(it)}" } ?: "待同步"}",
                    )
                    val details = buildList {
                        record.durationSeconds?.takeIf { it >= 0 }?.let { add("时长 ${it / 60}分${it % 60}秒") }
                        record.waterUsage.takeIf(String::isNotBlank)?.let { add("用量 $it") }
                    }.joinToString(" · ")
                    if (details.isNotBlank()) {
                        Text(details, color = MaterialTheme.colorScheme.outline, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun WaterCredentialsForm(
    credentials: WaterCredentials?,
    availableDevices: List<WaterDevice>,
    uiState: WaterUiState,
    onSave: (String, String, String, String) -> Unit,
    onAuthenticate: () -> Unit,
    perfectCampusLoginState: PerfectCampusLoginState,
    onRequestPerfectCampusSms: (String) -> Unit,
    onCompletePerfectCampusSms: (String) -> Unit,
    onCancelPerfectCampusLogin: () -> Unit,
    onCancel: (() -> Unit)?,
    onClear: (() -> Unit)?,
    onRefreshDevices: () -> Unit,
    onSelectDevice: (WaterDevice) -> Unit,
) {
    var openId by remember(credentials) { mutableStateOf(credentials?.openId.orEmpty()) }
    var sessionId by remember(credentials) { mutableStateOf(credentials?.sessionId.orEmpty()) }
    var posCode by remember(credentials) { mutableStateOf(credentials?.posCode.orEmpty()) }
    var orgId by remember(credentials) { mutableStateOf(credentials?.orgId ?: "2") }
    var perfectCampusExpanded by remember { mutableStateOf(false) }
    var perfectCampusPhone by remember { mutableStateOf("") }
    var perfectCampusSms by remember { mutableStateOf("") }

    DisposableEffect(Unit) {
        onDispose { onCancelPerfectCampusLogin() }
    }

    Icon(
        painter = XhuIcons.Action.switch,
        contentDescription = null,
        modifier = Modifier.padding(16.dp),
        tint = MaterialTheme.colorScheme.primary,
    )
    Text(
        text = if (credentials?.authenticated == true) "配置用水设备" else "配置用水服务",
        style = MaterialTheme.typography.headlineSmall,
    )
    Text(
        text = "可通过学校官方页面获取 JSESSIONID；iOS 也可使用完美校园短信登录，保存可用于续登的会话。手动导入仍作为兜底。",
        modifier = Modifier.padding(vertical = 12.dp),
        color = MaterialTheme.colorScheme.outline,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodySmall,
    )
    when (uiState) {
        WaterUiState.AuthExpired -> Text(
            text = "认证已失效且自动续登未成功，旧的 openid 与 JSESSIONID 已清除；设备信息仍保留。请重新使用学校页面或完美校园短信登录。",
            modifier = Modifier.padding(bottom = 12.dp),
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodySmall,
        )

        is WaterUiState.Error -> Text(
            text = uiState.message,
            modifier = Modifier.padding(bottom = 12.dp),
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodySmall,
        )

        else -> Unit
    }
    OutlinedTextField(
        value = openId,
        onValueChange = { openId = it.trim() },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("openid") },
        supportingText = { Text("微信认证需要 64 位 openid；完美校园模式可留空") },
        visualTransformation = PasswordVisualTransformation(),
        singleLine = true,
    )
    Spacer(Modifier.height(12.dp))
    OutlinedTextField(
        value = sessionId,
        onValueChange = { sessionId = it.trim() },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("JSESSIONID") },
        supportingText = { Text("可直接粘贴值或 JSESSIONID=值") },
        visualTransformation = PasswordVisualTransformation(),
        singleLine = true,
    )
    Spacer(Modifier.height(12.dp))
    OutlinedTextField(
        value = posCode,
        onValueChange = { value ->
            posCode = value.filter(Char::isDigit).take(6)
        },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("6 位设备号") },
        supportingText = { Text("可留空，保存认证信息后自动获取常用设备") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true,
    )
    Spacer(Modifier.height(12.dp))
    OutlinedTextField(
        value = orgId,
        onValueChange = { orgId = it.filter(Char::isDigit) },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("组织编号") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true,
    )
    Spacer(Modifier.height(20.dp))
    Button(
        onClick = onAuthenticate,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
    ) {
        Text("使用官方页面认证")
    }
    if (platform() == Platform.IOS) {
        Spacer(Modifier.height(8.dp))
        OutlinedButton(
            onClick = {
                perfectCampusExpanded = !perfectCampusExpanded
                if (!perfectCampusExpanded) onCancelPerfectCampusLogin()
            },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(24.dp),
        ) {
            Text(if (perfectCampusExpanded) "收起完美校园登录" else "使用完美校园短信登录")
        }
        if (perfectCampusExpanded) {
            Spacer(Modifier.height(8.dp))
            Text(
                "手机号和验证码仅用于本次登录，不会保存；登录会话保存在 iOS Keychain。",
                color = MaterialTheme.colorScheme.outline,
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = perfectCampusPhone,
                onValueChange = { perfectCampusPhone = it.filter(Char::isDigit).take(11) },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("完美校园手机号") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                singleLine = true,
            )
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = { onRequestPerfectCampusSms(perfectCampusPhone) },
                enabled = perfectCampusLoginState != PerfectCampusLoginState.SendingSms &&
                        perfectCampusLoginState != PerfectCampusLoginState.Verifying,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (perfectCampusLoginState == PerfectCampusLoginState.SendingSms) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp))
                } else {
                    Text("发送短信验证码")
                }
            }
            if (perfectCampusLoginState == PerfectCampusLoginState.SmsSent ||
                (perfectCampusLoginState is PerfectCampusLoginState.Error &&
                        perfectCampusLoginState.canSubmitCode)
            ) {
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = perfectCampusSms,
                    onValueChange = { perfectCampusSms = it.filter(Char::isDigit).take(8) },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("短信验证码") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = { onCompletePerfectCampusSms(perfectCampusSms) },
                    enabled = perfectCampusLoginState != PerfectCampusLoginState.Verifying,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("登录并建立用水会话")
                }
            }
            when (perfectCampusLoginState) {
                PerfectCampusLoginState.SmsSent -> Text(
                    "验证码已发送",
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.bodySmall,
                )
                is PerfectCampusLoginState.Error -> Text(
                    perfectCampusLoginState.message,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
                else -> Unit
            }
        }
    }
    Spacer(Modifier.height(8.dp))
    Button(
        onClick = { onSave(openId, sessionId, posCode, orgId) },
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
    ) {
        Text(if (posCode.isBlank()) "保存并自动获取设备" else "保存配置")
    }
    if (credentials?.authenticated == true && credentials.orgId.isNotBlank()) {
        OutlinedButton(
            onClick = onRefreshDevices,
            modifier = Modifier.fillMaxWidth(),
            enabled = uiState != WaterUiState.Loading,
            shape = RoundedCornerShape(24.dp),
        ) {
            if (uiState == WaterUiState.Loading) {
                CircularProgressIndicator(modifier = Modifier.padding(4.dp))
            } else {
                Text("自动刷新常用设备")
            }
        }
    }
    if (availableDevices.size > 1) {
        Text(
            text = "找到多个常用设备，请确认后选择：",
            modifier = Modifier.padding(top = 16.dp),
            style = MaterialTheme.typography.bodySmall,
        )
        availableDevices.forEach { device ->
            TextButton(
                onClick = { onSelectDevice(device) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(device.name.ifBlank { "设备 ${device.posCode}" })
            }
        }
    }
    onCancel?.let {
        TextButton(onClick = it, modifier = Modifier.fillMaxWidth()) {
            Text("取消")
        }
    }
    onClear?.let {
        TextButton(onClick = it, modifier = Modifier.fillMaxWidth()) {
            Text("清除本地凭据", color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun WaterAuthenticationContent(
    modifier: Modifier,
    request: WaterAuthenticationRequest,
    onAuthenticated: (String, String) -> Unit,
    automaticRecovery: Boolean,
    onCancel: () -> Unit,
    onError: (String) -> Unit,
) {
    Column(
        modifier = modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = if (automaticRecovery) {
                if (request.source == WaterAuthenticationSource.PerfectCampus) {
                    "正在使用 Keychain 中保留的完美校园会话重新建立 JSESSIONID。只会自动重试一次。"
                } else {
                    "正在使用 iOS 中保留的学校登录状态自动续登。若登录中心要求交互，将停止恢复。"
                }
            } else {
                if (request.source == WaterAuthenticationSource.PerfectCampus) {
                    "正在通过完美校园授权建立用水会话，完成后会自动保存 JSESSIONID。"
                } else {
                    "请在学校官方页面完成认证。若出现二维码，可截图后在微信扫一扫中从相册识别，再返回本页面。"
                }
            },
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 8.dp),
            color = MaterialTheme.colorScheme.outline,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodySmall,
        )
        WaterAuthenticationView(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1F),
            request = request,
            onAuthenticated = onAuthenticated,
            onError = onError,
        )
        TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
            Text(if (automaticRecovery) "停止自动续登" else "取消认证")
        }
    }
}

@Composable
private fun WaterControl(
    uiState: WaterUiState,
    running: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    onUpdateCredentials: () -> Unit,
) {
    val busy = uiState == WaterUiState.Loading ||
            uiState == WaterUiState.Authenticating ||
            uiState == WaterUiState.RecoveringAuthentication ||
            uiState == WaterUiState.Starting ||
            uiState == WaterUiState.Stopping
    val authExpired = uiState == WaterUiState.AuthExpired
    val status = when (uiState) {
        WaterUiState.Loading -> "正在读取配置"
        WaterUiState.NotAuthenticated -> "尚未认证"
        WaterUiState.Authenticating -> "正在认证"
        WaterUiState.RecoveringAuthentication -> "正在自动续登"
        WaterUiState.NotBound -> "尚未绑定设备"
        WaterUiState.Ready -> "已就绪"
        WaterUiState.Starting -> "正在开水"
        is WaterUiState.Running -> uiState.message
        WaterUiState.Stopping -> "正在关水"
        WaterUiState.AuthExpired -> "登录状态已失效"
        is WaterUiState.Error -> uiState.message
    }

    Icon(
        painter = XhuIcons.Action.switch,
        contentDescription = null,
        modifier = Modifier.padding(24.dp),
        tint = if (running) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
    )
    Text("用水开关", style = MaterialTheme.typography.headlineMedium)
    Text(
        text = status,
        modifier = Modifier.padding(top = 8.dp, bottom = 24.dp),
        color = when (uiState) {
            WaterUiState.AuthExpired,
            WaterUiState.NotAuthenticated,
            is WaterUiState.Error -> MaterialTheme.colorScheme.error
            else -> MaterialTheme.colorScheme.outline
        },
    )
    Card(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(modifier = Modifier.weight(1F)) {
                Text(if (running) "水阀已开启" else "水阀已关闭")
                Text(
                    text = "状态来自服务端未关阀记录",
                    color = MaterialTheme.colorScheme.outline,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            if (busy) {
                CircularProgressIndicator(modifier = Modifier.padding(8.dp))
            } else {
                Switch(
                    checked = running,
                    enabled = !authExpired &&
                            uiState != WaterUiState.Loading &&
                            uiState != WaterUiState.Authenticating &&
                            uiState != WaterUiState.RecoveringAuthentication &&
                            uiState != WaterUiState.NotAuthenticated &&
                            uiState != WaterUiState.NotBound,
                    onCheckedChange = onCheckedChange,
                )
            }
        }
    }
    if (authExpired) {
        Button(
            onClick = onUpdateCredentials,
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 20.dp),
        ) {
            Text("重新导入认证信息")
        }
    }
    Text(
        text = "请只对本人有权使用的设备操作。",
        modifier = Modifier.padding(top = 20.dp),
        color = MaterialTheme.colorScheme.outline,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodySmall,
    )
}
