package vip.mystery0.xhu.timetable.ui.activity

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import dalvik.system.DexClassLoader
import java.lang.reflect.InvocationTargetException

/** 仅用于验证官方 SDK 能否在本应用进程中初始化；不生成业务请求。 */
class TmallSignerProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val label = TextView(this).also {
            it.text = "正在检查签名组件"
            setContentView(it)
        }
        val useSourceContext = intent.getBooleanExtra(EXTRA_SOURCE_CONTEXT, false)
        Thread {
            val outcome = probe(useSourceContext)
            Log.i(TAG, outcome)
            runOnUiThread { label.text = outcome }
        }.start()
    }

    private fun probe(useSourceContext: Boolean): String {
        val mode = if (useSourceContext) "source" else "own"
        return try {
            val info = campusApplicationInfo()
            val loader = DexClassLoader(
                info.sourceDir,
                codeCacheDir.absolutePath,
                info.nativeLibraryDir,
                classLoader,
            )
            val context = if (useSourceContext) {
                createPackageContext(CAMPUS_PACKAGE, Context.CONTEXT_INCLUDE_CODE)
            } else {
                applicationContext
            }
            val managerClass = loader.loadClass(SECURITY_GUARD_MANAGER)
            val manager = managerClass.getMethod("getInstance", Context::class.java)
                .invoke(null, context)
            val signature = managerClass.getMethod("getSecureSignatureComp")
                .invoke(manager)
            "$mode:${if (signature == null) "component_missing" else "component_ready"}"
        } catch (error: Throwable) {
            val cause = (error as? InvocationTargetException)?.targetException ?: error
            "$mode:failed:${cause.javaClass.simpleName}"
        }
    }

    private fun campusApplicationInfo(): ApplicationInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getApplicationInfo(
                CAMPUS_PACKAGE,
                PackageManager.ApplicationInfoFlags.of(0),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getApplicationInfo(CAMPUS_PACKAGE, 0)
        }

    private companion object {
        const val TAG = "TmallSignerProbe"
        const val EXTRA_SOURCE_CONTEXT = "source_context"
        const val CAMPUS_PACKAGE = "com.tmall.campus.and"
        const val SECURITY_GUARD_MANAGER = "com.alibaba.wireless.security.open.SecurityGuardManager"
    }
}
