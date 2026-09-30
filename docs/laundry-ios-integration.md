# iOS 洗衣接入状态

## 当前可用范围

iOS 的课表左上角和个人页显示洗衣入口。校园客户端尚未就绪时，进入主题一致的“暂未开放”页面，明确说明不能登录、扫码下单或付款；不再隐藏入口，也不显示可点击但无效的手机号登录按钮。

原生宿主在启动时安装 `LaundryNativeUi`，通过 `IosLaundryNativeBridge` 接收当前操作编号。授权页使用独立、临时的 WKWebView Cookie 容器；只接受 HTTPS 官方域名、主框架的精确回调路径、唯一的 action/授权码。加载失败可重试，授权码不通过路由、日志或持久化传递。相机沿用 AVFoundation 与共享二维码校验。微信只接受既有收银台的小程序路由，返回前台后交给共享 ViewModel 查询服务端；打开微信或返回都不代表付款成功。取消、重复结果和晚到回调按操作编号隔离。

以上原生页面在已核验校园客户端安装后才由真实业务调用。当前不注册假网关，不复用抓包会话、签名或预支付参数，不自动创建订单。

## 仍缺的校园客户端

`IosLaundryLoginGateway` 是接口，目前没有真实实现，也没有调用 `IosLaundryRuntime.installClient`。因此当前版本仍无法完成 iOS 校园登录和下单；入口可见不代表服务可用。

客户端必须实现：当次授权 URL、授权码转换、本人资料和订单核验、设备与程序查询、实时报价、账号绑定的 Keychain 付款意图、至多一次创建、有限范围恢复、微信付款 URI、终态再次核验及运行订单采样。共享 `LaundryViewModel` 的报价竞态、付款恢复、倒计时和后台停止轮询继续复用。

当前材料包含加密的天猫校园 5.7.2 IPA，以及[淘宝官方公开 iOS 百川旗舰版 5.0.0.18 SDK](https://developer.alibaba.com/docs/doc.htm?articleId=106383&docType=1&treeId=129)。公开包的 885 个非资源分叉头文件没有 Android `getUnifiedSign` 接口；MTOP 配置声明 appKey、authCode、appkeyIndex 和内外实例类型。这个离线检查不能证明所有二进制能力不存在，也不能证明校园 API 权限、二方签名、安全字段和本应用 bundle 环境兼容。没有可验证的 iOS 校园请求样本或适配组件，不能把安卓配置及安全资源直接接入后声称成功。

下一阶段需要针对当前 iOS bundle 的可验证校园 SDK/签名适配与配置，先验证新设备注册、当次安全字段、会话转换和只读订单查询，再开放创建与付款。现有 IPA 主程序声明加密，没有可直接链接的校园 SDK；重新签名西瓜课表 IPA 不会补齐这些能力。

## 本轮验证

- `composeApp:testAndroidHostTest`：71 项通过，包含新增授权回调、跳转来源、微信路由、重复/取消回调测试。
- `androidApp:assembleDebug`：standard/store debug 均成功；安卓仍本地构建。
- iOS Kotlin 与 Swift：待 Codemagic 构建确认。
- 真机授权、相机权限/取消、微信返回和完整洗衣流程：未验证。当前不可用页面的入口显示也需新版 IPA 安装后确认。
