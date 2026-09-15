package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
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
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import vip.mystery0.xhu.timetable.model.water.WaterCredentials
import vip.mystery0.xhu.timetable.model.water.WaterUiState
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
    val lastKnownRunning by viewModel.lastKnownRunning.collectAsState()

    var editing by remember { mutableStateOf(false) }
    var pendingRunningState by remember { mutableStateOf<Boolean?>(null) }

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
        Column(
            modifier = Modifier
                .padding(paddingValues)
                .padding(horizontal = 20.dp)
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(24.dp))
            if (editing || uiState == WaterUiState.NotBound) {
                WaterCredentialsForm(
                    credentials = credentials,
                    onSave = { openId, sessionId, posCode, orgId ->
                        if (viewModel.saveCredentials(openId, sessionId, posCode, orgId)) {
                            editing = false
                        }
                    },
                    onCancel = if (credentials == null) null else ({ editing = false }),
                    onClear = if (credentials == null) null else ({ viewModel.clearCredentials() }),
                )
            } else {
                WaterControl(
                    uiState = uiState,
                    running = lastKnownRunning,
                    onCheckedChange = { pendingRunningState = it },
                    onUpdateCredentials = { editing = true },
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    pendingRunningState?.let { targetRunning ->
        AlertDialog(
            onDismissRequest = { pendingRunningState = null },
            title = { Text(if (targetRunning) "确认开水" else "确认关水") },
            text = {
                Text(
                    if (targetRunning) {
                        "确认向当前配置的设备发送开水指令？"
                    } else {
                        "确认向当前配置的设备发送关水指令？"
                    }
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingRunningState = null
                        if (targetRunning) viewModel.startWater() else viewModel.stopWater()
                    }
                ) {
                    Text("确认")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRunningState = null }) {
                    Text("取消")
                }
            },
        )
    }

    HandleErrorMessage(flow = viewModel.errorMessage)
}

@Composable
private fun WaterCredentialsForm(
    credentials: WaterCredentials?,
    onSave: (String, String, String, String) -> Unit,
    onCancel: (() -> Unit)?,
    onClear: (() -> Unit)?,
) {
    var openId by remember(credentials) { mutableStateOf(credentials?.openId.orEmpty()) }
    var sessionId by remember(credentials) { mutableStateOf(credentials?.sessionId.orEmpty()) }
    var posCode by remember(credentials) { mutableStateOf(credentials?.posCode.orEmpty()) }
    var orgId by remember(credentials) { mutableStateOf(credentials?.orgId ?: "2") }

    Icon(
        painter = XhuIcons.Action.switch,
        contentDescription = null,
        modifier = Modifier.padding(16.dp),
        tint = MaterialTheme.colorScheme.primary,
    )
    Text(
        text = if (credentials == null) "配置用水服务" else "更新用水服务凭据",
        style = MaterialTheme.typography.headlineSmall,
    )
    Text(
        text = "从你自己的 HTTPS 抓包中填写以下字段。应用不会包含任何预置账号或凭据；JSESSIONID 失效后需要重新填写。",
        modifier = Modifier.padding(vertical = 12.dp),
        color = MaterialTheme.colorScheme.outline,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodySmall,
    )
    OutlinedTextField(
        value = openId,
        onValueChange = { openId = it.trim() },
        modifier = Modifier.fillMaxWidth(),
        label = { Text("openid") },
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
        onClick = { onSave(openId, sessionId, posCode, orgId) },
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
    ) {
        Text("保存配置")
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
private fun WaterControl(
    uiState: WaterUiState,
    running: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    onUpdateCredentials: () -> Unit,
) {
    val busy = uiState == WaterUiState.Starting || uiState == WaterUiState.Stopping
    val authExpired = uiState == WaterUiState.AuthExpired
    val status = when (uiState) {
        WaterUiState.Loading -> "正在读取配置"
        WaterUiState.NotBound -> "尚未配置"
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
            WaterUiState.AuthExpired, is WaterUiState.Error -> MaterialTheme.colorScheme.error
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
                    text = "状态来自本机最近一次成功操作",
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
            Text("更新 JSESSIONID")
        }
    }
    Text(
        text = "请只对本人有权使用的设备操作。离开页面前请确认已经关水。",
        modifier = Modifier.padding(top = 20.dp),
        color = MaterialTheme.colorScheme.outline,
        textAlign = TextAlign.Center,
        style = MaterialTheme.typography.bodySmall,
    )
}
