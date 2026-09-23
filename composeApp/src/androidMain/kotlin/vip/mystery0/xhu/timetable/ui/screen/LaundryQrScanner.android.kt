package vip.mystery0.xhu.timetable.ui.screen

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.camera.core.CameraSelector
import androidx.camera.mlkit.vision.MlKitAnalyzer
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import com.google.accompanist.permissions.shouldShowRationale
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode

@OptIn(ExperimentalPermissionsApi::class)
@Composable
internal actual fun LaundryQrScanner(
    modifier: Modifier,
    onResult: (String) -> Unit,
    onCancel: () -> Unit,
) {
    val permission = rememberPermissionState(Manifest.permission.CAMERA)
    var requested by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        requested = true
        if (!permission.status.isGranted) permission.launchPermissionRequest()
    }
    if (permission.status.isGranted) {
        LaundryCameraPreview(modifier, onResult, onCancel)
        return
    }
    val context = LocalContext.current
    Column(
        modifier = modifier.padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("扫描洗衣机二维码需要相机权限。相机画面只在本机用于识别二维码。")
        if (!requested || permission.status.shouldShowRationale) {
            Button(onClick = permission::launchPermissionRequest) { Text("授予相机权限") }
        } else {
            Button(onClick = {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${context.packageName}")
                })
            }) { Text("前往系统设置") }
        }
        OutlinedButton(onClick = onCancel) { Text("取消扫码") }
    }
}

@Composable
private fun LaundryCameraPreview(
    modifier: Modifier,
    onResult: (String) -> Unit,
    onCancel: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnResult by rememberUpdatedState(onResult)
    var delivered by remember { mutableStateOf(false) }
    val scanner: BarcodeScanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build()
        )
    }
    val controller = remember {
        LifecycleCameraController(context).apply {
            cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
            setEnabledUseCases(CameraController.IMAGE_ANALYSIS)
        }
    }
    DisposableEffect(lifecycleOwner, controller, scanner) {
        val executor = ContextCompat.getMainExecutor(context)
        controller.setImageAnalysisAnalyzer(
            executor,
            MlKitAnalyzer(
                listOf(scanner),
                CameraController.COORDINATE_SYSTEM_VIEW_REFERENCED,
                executor,
            ) { result ->
                if (delivered) return@MlKitAnalyzer
                val value = result?.getValue(scanner)
                    ?.firstOrNull()
                    ?.rawValue
                    ?.takeIf(String::isNotBlank)
                    ?: return@MlKitAnalyzer
                delivered = true
                currentOnResult(value)
            },
        )
        controller.bindToLifecycle(lifecycleOwner)
        onDispose {
            controller.clearImageAnalysisAnalyzer()
            controller.unbind()
            scanner.close()
        }
    }
    Box(modifier = modifier) {
        AndroidView(
            factory = { PreviewView(it).apply { this.controller = controller } },
            modifier = Modifier.fillMaxSize(),
            onRelease = { it.controller = null },
        )
        OutlinedButton(
            onClick = onCancel,
            modifier = Modifier.align(Alignment.BottomCenter).padding(24.dp),
        ) { Text("取消扫码") }
    }
}
