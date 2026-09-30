package vip.mystery0.xhu.timetable.laundry

import vip.mystery0.xhu.timetable.repository.LaundryGateway
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class IosLaundryScanResult(val contents: String?, val error: String? = null)

/** 原生页面返回时才恢复轮询；微信回到前台不代表付款成功。 */
interface IosLaundryPresenter {
    suspend fun login(forceLogin: Boolean): Boolean
    suspend fun scan(): IosLaundryScanResult
    suspend fun openWechat(uri: String): String?
}

/** 在主线程、Compose 启动前安装已验证的 iOS 客户端；不加载 Android 安全组件。 */
object IosLaundryRuntime {
    private val ready = MutableStateFlow(false)
    val availability: StateFlow<Boolean> = ready
    internal var gateway: LaundryGateway? = null
        private set
    internal var presenter: IosLaundryPresenter? = null
        private set
    val available: Boolean get() = gateway != null && presenter != null

    fun installClient(gateway: IosLaundryLoginGateway) {
        install(gateway, IosCampusLaundryPresenter(gateway))
    }

    fun install(gateway: LaundryGateway, presenter: IosLaundryPresenter) {
        check(!available) { "校园客户端只能初始化一次" }
        this.gateway = gateway
        this.presenter = presenter
        ready.value = true
    }
}
