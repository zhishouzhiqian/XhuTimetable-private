# iOS 洗衣接入状态

## 当前可用范围

iOS 的课表左上角和个人页显示洗衣入口。校园客户端尚未就绪时，进入主题一致的“暂未开放”页面，明确说明不能登录、扫码下单或付款；不再隐藏入口，也不显示可点击但无效的手机号登录按钮。

原生宿主在启动时安装 `LaundryNativeUi`，通过 `IosLaundryNativeBridge` 接收当前操作编号。授权页使用独立、临时的 WKWebView Cookie 容器；只接受 HTTPS 官方域名、主框架的精确回调路径、唯一的 action/授权码。加载失败可重试，授权码不通过路由、日志或持久化传递。相机沿用 AVFoundation 与共享二维码校验。微信只接受既有收银台的小程序路由，返回前台后交给共享 ViewModel 查询服务端；打开微信或返回都不代表付款成功。取消、重复结果和晚到回调按操作编号隔离。

以上原生页面在已核验校园客户端安装后才由真实业务调用。当前不注册假网关，不复用抓包会话、签名或预支付参数，不自动创建订单。

## 仍缺的校园客户端

`IosLaundryLoginGateway` 是接口，目前没有真实实现，也没有调用 `IosLaundryRuntime.installClient`。因此当前版本仍无法完成 iOS 校园登录和下单；入口可见不代表服务可用。

客户端必须实现：当次授权 URL、授权码转换、本人资料和订单核验、设备与程序查询、实时报价、账号绑定的 Keychain 付款意图、至多一次创建、有限范围恢复、微信付款 URI、终态再次核验及运行订单采样。共享 `LaundryViewModel` 的报价竞态、付款恢复、倒计时和后台停止轮询继续复用。

当前材料包含加密的天猫校园 5.7.2 IPA，以及[淘宝官方公开 iOS 百川旗舰版 5.0.0.18 SDK](https://developer.alibaba.com/docs/doc.htm?articleId=106383&docType=1&treeId=129)。公开包的 885 个非资源分叉头文件没有 Android `getUnifiedSign` 接口；MTOP 配置声明 appKey、authCode、appkeyIndex 和内外实例类型。这个离线检查不能证明所有二进制能力不存在，也不能证明校园 API 权限、二方签名、安全字段和本应用 bundle 环境兼容。没有可验证的 iOS 校园请求样本或适配组件，不能把安卓配置及安全资源直接接入后声称成功。

[官方 iOS 5.x 接入文档](https://developer.alibaba.com/docs/doc.htm?articleId=118593&docType=1&treeId=129) 的三方百川接入方案要求使用 V6 安全图片，并明确 Demo 需要替换成申请的安全图片和 Bundle ID；登录能力用于百川电商业务。这是官方三方方案的条件，不能直接推断校园组件兼容路线也必须重新申请。公开 SDK 下载或 IPA 重新签名不能作为校园接口可用的证据。

用户质疑为何 iOS 与安卓的前置条件不同，继续离线检查公开 SDK 二进制发现：MtopSDK 含 `signRequest:`、`x-sign`、`x-mini-wua`、`x-sgext` 字符串标记；SGMain、mtopcoreopen 含 `signRequest:authCode:`；SecurityGuardSDK 含自定义 bundle 路径初始化相关方法。字符串存在只提供定位线索，不证明相应代码已执行或签名兼容。下一步优先验证与安卓相同的组件/安全资源复用路线，不能以公开头文件缺少同名方法断言需要新授权；须在本应用环境生成新请求，并由服务端响应核验。未执行 SDK、未发送登录/订单请求。

下一阶段需要验证当前 iOS bundle 下校园 SDK/签名适配与配置，先验证新设备注册、当次安全字段、会话转换和只读订单查询，再开放创建与付款。现有 IPA 主程序声明加密，没有可直接链接的校园 SDK；重新签名西瓜课表 IPA 不会补齐这些能力。组件复用是否可行仍待验证，不把新权限或安全图片当作已经确定的必要条件。

## 本轮验证

- `composeApp:testAndroidHostTest`：71 项通过，包含新增授权回调、跳转来源、微信路由、重复/取消回调测试。
- `androidApp:assembleDebug`：standard/store debug 均成功；安卓仍本地构建。
- iOS Kotlin 与 Swift：[Codemagic 构建 6abcfd69083ff0a9a53ab319](https://codemagic.io/app/6abcc2cd6c98472e80a8cc91/build/6abcfd69083ff0a9a53ab319) 的共享 iOS 测试成功，设备应用与新增 Swift 原生桥接编译、IPA 打包成功；Artifacts 提供 32.29 MB 的未签名 IPA。仍未安装真实校园网关。
- 真机授权、相机权限/取消、微信返回和完整洗衣流程：未验证。当前不可用页面的入口显示也需新版 IPA 安装后确认。
