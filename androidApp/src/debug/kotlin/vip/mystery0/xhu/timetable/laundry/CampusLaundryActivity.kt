package vip.mystery0.xhu.timetable.laundry

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import androidx.compose.runtime.getValue
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryActions
import vip.mystery0.xhu.timetable.ui.screen.laundry.LaundryContent
import vip.mystery0.xhu.timetable.ui.theme.NightMode
import vip.mystery0.xhu.timetable.ui.theme.XhuTimetableTheme

/** 所有业务页面留在校园进程，主进程仅收到退出结果。 */
class CampusLaundryActivity : ComponentActivity() {
    private lateinit var model: CampusLaundryViewModel
    private var scanPending = false
    private var externalType: String? = null
    private val mode by lazy {
        NightMode.entries.firstOrNull { it.name == intent.getStringExtra("night_mode") } ?: NightMode.AUTO
    }
    private val login = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        externalType = null
        val success = it.resultCode == Activity.RESULT_OK && it.data?.getBooleanExtra("campus_verified", false) == true
        if (success) model.loginReturned(true) else finish()
    }
    private val scanner = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        externalType = null
        val status = it.data?.getStringExtra("laundry_scan_status")
        val resNo = if (it.resultCode == Activity.RESULT_OK && status == "recognized")
            it.data?.getStringExtra("laundry_res_no") else null
        val error = when (status) {
            "camera_denied" -> "请在系统设置中允许使用相机后重试。"
            "unknown" -> "请扫描校园洗衣机的二维码。"
            "cancelled" -> null
            "recognized" -> if (resNo == null) "未能读取设备编号，请重新扫码。" else null
            else -> "无法完成扫码，请重试。"
        }
        model.scanReturned(resNo, error)
    }
    private val wechat = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        externalType = null
        model.wechatReturned()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        scanPending = savedInstanceState?.getBoolean("scan_pending") ?: intent.getBooleanExtra("scan_immediately", false)
        externalType = savedInstanceState?.getString("external_type")
        model = ViewModelProvider(this, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                CampusLaundryViewModel(CampusLaundryClientGateway(applicationContext), scanPending, externalType != null) as T
        })[CampusLaundryViewModel::class.java]
        setContent {
            XhuTimetableTheme(mode) {
                LaundrySystemBars(window)
                val state by model.state.collectAsStateWithLifecycle()
                val back = { if (!model.back()) finish() }
                BackHandler(onBack = back)
                LaundryContent(state, LaundryActions(back, model::scan, model::orders, model::refresh,
                    model::selectProgram, model::createPayment, model::resumePayment, model::acknowledgePayment, model::relogin))
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) { model.command.collect { command ->
                if (command == null) return@collect
                model.consumeCommand()
                externalType = command.type.name
                when (command.type) {
                    LaundryCommandType.Login -> login.launch(Intent(this@CampusLaundryActivity, CampusLoginActivity::class.java)
                        .putExtra("night_mode", mode.name).putExtra("force_login", command.uri == "force_login"))
                    LaundryCommandType.Scan -> {
                        scanPending = false
                        scanner.launch(Intent(this@CampusLaundryActivity, LaundryScanActivity::class.java))
                    }
                    LaundryCommandType.Wechat -> {
                        try {
                            wechat.launch(Intent(Intent.ACTION_VIEW, Uri.parse(command.uri)).setPackage("com.tencent.mm"))
                        } catch (_: android.content.ActivityNotFoundException) {
                            externalType = null
                            model.wechatReturned("无法打开微信，请安装或更新微信。订单已保留。")
                        }
                    }
                }
            } }
        }
    }

    override fun onResume() { super.onResume(); if (::model.isInitialized) model.foreground(true) }
    override fun onPause() { if (::model.isInitialized) model.foreground(false); super.onPause() }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("scan_pending", scanPending && model.autoScanPending)
        outState.putString("external_type", externalType)
        super.onSaveInstanceState(outState)
    }
}
