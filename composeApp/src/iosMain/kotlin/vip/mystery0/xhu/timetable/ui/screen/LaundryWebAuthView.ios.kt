package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.runtime.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CancellationException
import platform.Foundation.NSProcessInfo
import vip.mystery0.xhu.timetable.laundry.IosLaundryRuntime
import vip.mystery0.xhu.timetable.model.laundry.*
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryActions
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryContent
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryLoginContent
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryUnavailableContent
import vip.mystery0.xhu.timetable.viewmodel.LaundryViewModel

@Composable
@OptIn(ExperimentalForeignApi::class)
internal actual fun LaundryServiceHost(scanImmediately: Boolean, onExit: () -> Unit) {
    val available by IosLaundryRuntime.availability.collectAsState()
    val gateway = IosLaundryRuntime.gateway
    val presenter = IosLaundryRuntime.presenter
    if (!available || gateway == null || presenter == null) {
        LaundryUnavailableContent(onExit)
        return
    }
    val scope = rememberCoroutineScope()
    val model = remember(gateway) {
        LaundryViewModel(gateway, scanImmediately, scope = scope,
            elapsedRealtime = { (NSProcessInfo.processInfo.systemUptime * 1000).toLong() })
    }
    val state by model.state.collectAsState()
    val currentExit by rememberUpdatedState(onExit)
    var loginError by remember { mutableStateOf<String?>(null) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(model, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> model.foreground(true)
                Lifecycle.Event.ON_STOP -> model.foreground(false)
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        model.foreground(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        onDispose { lifecycle.removeObserver(observer); model.foreground(false) }
    }
    LaunchedEffect(model, presenter) {
        model.command.collect { command ->
            if (command == null) return@collect
            model.consumeCommand()
            try {
                when (command.type) {
                    LaundryCommandType.Login -> {
                        val success = presenter.login(command.uri == "force_login")
                        model.loginReturned(success)
                        if (!success) currentExit()
                    }
                    LaundryCommandType.Scan -> {
                        val result = presenter.scan()
                        val number = result.contents?.let(LaundryQrPolicy::deviceNumber)
                        model.scanReturned(number, result.error ?: if (result.contents != null && number == null)
                            "请扫描校园洗衣机二维码。" else null)
                    }
                    LaundryCommandType.Wechat -> model.wechatReturned(presenter.openWechat(command.uri))
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                when (command.type) {
                    LaundryCommandType.Login -> {
                        model.loginReturned(false)
                        loginError = "登录暂未完成，请检查网络后重试。"
                    }
                    LaundryCommandType.Scan -> model.scanReturned(null, "暂时无法打开相机，请重试。")
                    LaundryCommandType.Wechat -> model.wechatReturned("无法打开微信，订单已保留。")
                }
            }
        }
    }
    if (loginError != null) {
        LaundryLoginContent(false, loginError, currentExit,
            { loginError = null; model.relogin() }, false) {}
    } else {
        LaundryContent(state, LaundryActions({ if (!model.back()) currentExit() }, model::scan,
            model::orders, model::refresh, model::selectProgram, model::createPayment,
            model::resumePayment, model::acknowledgePayment, model::relogin))
    }
}
