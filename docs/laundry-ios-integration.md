# iOS 洗衣接入状态

## b8a9642 真机反馈：当前候选 SDK 尚不可用

默认 authCode 模式已在真机运行，资源与接口检查通过，但 AppKey 仍为空、统一签名初始化仍报 `2404`。补路径和改用默认认证参数均未解决当前候选组件的问题；不再要求重复构建或手工填写 AppKey。当前需要进一步核对 SDK 资源加载失败原因或取得兼容的可链接 iOS 组件，没有可用签名，也未接通校园网关。报告及界面提示已纠正，具体证据和下一步条件见 [分析记录](laundry-ios-decrypted-analysis.md#b8a9642-真机复核默认认证参数未解决初始化失败)。

## afdf401 真机反馈及下一项核对

用户已安装并运行 `afdf401` 轻量包：资源读取与完整性通过，SDK 为 `5.6.231002`，AppKey 仍为空，统一初始化显式传入路径后仍返回 `2404`；尚未生成签名或访问服务端。继续静态核对发现，校园内部静态配置实际委托 Open 组件且传 `authCode:nil`，候选 SDK 的无参管理器也采用 `nil`，而当前检查显式传空字符串。下一版统一使用未提供 authCode 的厂商默认模式，并在报告及桩测试中标明；这只是已确认调用差异的修正，不能预先认定能解决 `2404`。详见 [分析记录](laundry-ios-decrypted-analysis.md#afdf401-真机结果与默认认证参数核对)。

## 2026-10-01：破壳样本与检查输入核对

本轮获得新的天猫校园 5.7.2 破壳 IPA，主程序 `cryptid=0`。已确认校园 SecurityGuard 的公开版本常量为 `6.8.260603`，与既有检查使用的 `5.6.231002` 不同；AppKey 由内部 `SecurityGuardManager` 入口读取，不能把 Open 入口空值直接当作校园读取失败。当前样本也再次确认统一签名初始化读取 `customBundelPath`。

检查代码改用已核对的 iOS MTOP 22 字段输入，增加 SDK 与入口对照，并要求四项安全字段齐全且没有 SDK 错误才进入签名比较。新增 7 项元数据审计测试，Python 审计与资源准备共 18 项通过。Objective-C 编译、扩展后的原生桩测试、修正版真机与服务端仍待验证，没有新 IPA 或真实校园客户端。证据、字段顺序、工具命令及验证边界见 [破壳 IPA 分析记录](laundry-ios-decrypted-analysis.md)。

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

## 个人组件检查包

进一步检查候选 SDK 头文件，`SGMiddleTier/ISecurityGuardOpenUnifiedSecurity.h` 提供 `init:error:` 与 `getSecurityFactors:error:`，声明返回 `x-sign`、`x-mini-wua`、`x-umt`、`x-sgext`。与 Android 方法不同名，之前仅搜索 `getUnifiedSign` 的结果不能代表没有统一签名能力。

Codemagic 个人工作流使用固定 SHA-256 校验的公开包，只链接 SecurityGuardSDK、SGMain、SGMiddleTier、SGSecurityBody。检查入口由 `CAMPUS_COMPONENT_PROBE` 开关控制；普通构建不加载候选 SDK。原 IPA 的两个安全资源只提取到本地检查 JSON，用户在 iPhone 文件选择器导入，不提交 Git 或上传 CI。

检查页后台执行 SDK 初始化、读取配置、当次安全字段生成和统一签名字段存在性检查，只显示固定步骤和数值错误码，不展示签名或设备标识。每个进程执行一次，防止 SDK 单例加载后更换资源；关闭页面后仍保留结果，45 秒未返回显示超时。签名入参是唯一当次诊断输入，不是 MTOP 规范串，也不会作为请求发送。

安装步骤：下载本轮 IPA → 自行签名安装 → 个人页“洗衣服务” → “组件检查” → 导入本地 `campus-ios-check-resources.json` → “开始组件检查” → 保存结果截图。重新检查需彻底关闭并重新启动应用，再导入资源。

本地字段生成成功只证明候选组件能执行，不能证明服务器认可、设备注册成功或校园登录可用。下一阶段仍需生成规范新请求并核验只读服务端响应，再接通授权和校园会话；当前检查包不创建或支付订单。

首次检查包在用户真机显示“候选 SDK：失败（错误码 -2）”。此代码来自未启用组件的占位分支，不是厂商 SDK 返回码。根因是 `updateAppleBuildVersion` 重写 `Config.xcconfig`，覆盖了此前追加的 Objective-C 宏和 framework 链接设置；Swift 命令行开关仍保留，所以入口可见但组件没有执行。

修复将配置追加移到版本任务之后、Xcode 编译之前，并让 Swift 检查入口引用仅真实组件分支提供的 C 符号。两侧编译开关不一致时链接直接失败，避免再次交付占位检查包。用户后续真机反馈已确认 SDK 管理器可初始化；服务端验证仍未完成。

Android `CampusClient.request` 每次设置当前 `t`、业务数据及会话信息，并调用 `getUnifiedSign` 生成本次签名。现有安卓功能成功不是“旧抓包签名可以持续重放”的证据；iOS 抓包和接口清单可辅助核对协议，但不能替代新请求的签名与真实响应验证。

## 降低检查构建开销

用户真机最新反馈：SDK 初始化成功，读取应用配置为空。旧检查显示的 `-1` 是工具通用标记，不是 SDK 返回码；公开 `getAppKey:authCode:` 接口返回字符串，没有 NSError 参数，不能从空值推断签名不兼容。

检查代码现增加以下信息，并复用于完整应用和轻量宿主：

- 资源 Bundle 查找、文件可读性及与导入时 SHA-256 的一致性，导入后重启可复用资源。
- MainPlugin、MiddleTierPlugin、SecurityBodyPlugin 的链接状态，SDK 版本和静态配置组件是否可获取。
- AppKey 为空仍检查统一签名初始化，保留真实 SDK 错误码。允许可选输入已知抓包 AppKey，但它不代表对应密钥可用；不展示或保存输入值。
- 条件满足时用两个不同输入检查本地签名是否变化，不发送 MTOP 请求。
- 按阶段实时更新结果，复制脱敏报告，关闭重开页面仍保留状态。超时保留已完成步骤。

新增手动工作流 `ios-component-check`（iOS 洗衣组件轻量检查）：只编译同一套 UIKit / Objective-C 检查代码和候选 SDK，跳过 Gradle、Kotlin/Native、数据库和课表扩展。先执行 4 项使用桩组件的 macOS 原生流程测试，覆盖 AppKey 为空继续检查、提示值驱动新签名、资源损坏阻断和 SDK 错误码保留，再编译 iPhone 检查宿主。桩测试不会执行厂商二进制或访问校园服务器。

产物为 `CampusComponentCheck-unsigned.ipa`，应用名“洗衣组件检查”，使用独立 Bundle ID，可与课表共存。它的成功不能替代西瓜课表实际 Bundle ID 下的验证；组件排查完成后再集中运行完整 `ios-personal-unsigned` 工作流。两个工作流均无自动触发。

本轮本地验证：资源准备工具 5 项测试、Bash 语法和 YAML 配置检查通过。新增 Swift / Objective-C 的编译、4 项原生桩测试和真机表现需云端及设备验证，未把源码检查记为执行通过。

## 检查版本 62 的真机结果与路径修正

用户在独立检查应用 `vip.mystery0.xhu.timetable.CampusComponentCheck` 上反馈：两个资源文件均可通过 Bundle 查找、可读取且导入完整性一致；三个插件已链接；SDK 管理器初始化成功，版本 `5.6.231002`；静态配置组件与统一签名接口可获取。AppKey 索引 0 返回空值，统一签名初始化返回厂商错误码 `2404`。安全字段生成及服务端设备注册未执行。这不能替代完整课表 Bundle ID 下的验证。

为避免仅根据错误码猜测权限问题，本地检查了固定 SHA-256 的公开 SDK 中 arm64 对象所携带的 LLVM bitcode。`SecurityGuardOpenUnifiedSecurity init:error:` 除读取 `authCode`、`flag`，还读取一个路径参数 `customBundelPath`，并作为独立参数传给底层初始化。`Bundel` 的拼写来自该版本实现；公开头文件未列出它。这里只分析接口参数和错误分支，未解密导入的安全资源或提取密钥。

当前检查代码只向 `OpenSecurityGuardManager` 传入自定义路径，统一签名初始化遗漏了自己的路径参数。本轮补充 `customBundelPath`，传入同一份已校验目录；原生桩测试同时检查正确拼写及路径一致性。资源不移入应用包，不更改应用标识，不跳过完整性检查。

本地二进制只能确认底层错误值 `4` 在相关失败分支被映射为 `2404`，没有找到足以解释其含义的官方定义。路径遗漏是已确认的调用缺口；它是否导致本次 `2404`、AppKey 空值是否有相同原因，仍需修正版真机结果证明。手工填 AppKey 不会补上路径参数，也不能直接解决组件初始化失败。

本轮未启动 Codemagic 构建。修改后的原生桩测试执行、iPhone 编译、统一签名初始化和新的安全字段生成均待验证；仍未安装真实校园客户端，未请求登录、下单或付款。后续将其与完成的组件修正合并后优先运行轻量工作流。

用户随后要求进行下一步：本地资源工具 5 项测试、Bash 语法与 `git diff --check` 通过；轻量包报告增加 `CampusProbeRevision` 提交编号，避免浅克隆提交数与本地版本数不一致时无法辨认修正版。原生桩测试增加资源路径传参及报告不得泄漏沙盒路径的检查。本轮计划仅启动轻量工作流；真机结论继续以用户安装后的结果为准。

本地准备工具 5 项测试通过；JDK 21 下 `composeApp:testAndroidHostTest` 和 `androidApp:assembleDebug` 通过。安全资源 JSON 为本地生成文件，不是 CI 产物。

## 已完成的基础验证

- `composeApp:testAndroidHostTest`：71 项通过，包含新增授权回调、跳转来源、微信路由、重复/取消回调测试。
- `androidApp:assembleDebug`：standard/store debug 均成功；安卓仍本地构建。
- iOS Kotlin 与 Swift：[Codemagic 构建 6abcfd69083ff0a9a53ab319](https://codemagic.io/app/6abcc2cd6c98472e80a8cc91/build/6abcfd69083ff0a9a53ab319) 的共享 iOS 测试成功，设备应用与新增 Swift 原生桥接编译、IPA 打包成功；Artifacts 提供 32.29 MB 的未签名 IPA。仍未安装真实校园网关。
- 真机授权、相机权限/取消、微信返回和完整洗衣流程：未验证。当前不可用页面的入口显示也需新版 IPA 安装后确认。
