# 天猫校园短信登录协议核对（Android 测试版）

本记录只使用用户提供的 `登录数据 root.har` 的脱敏结构。原始 HAR 含手机号、验证码、Cookie、会话及设备凭据，不进入仓库，也不作为可重放的测试数据。

## 当前 `登录数据 root.har` 的实际链路

本文件记录的是 H5 短信登录，不包含 `mtop.taobao.mloginservice.smssend` 或 `mtop.taobao.mloginservice.smslogin`。先前交接记录描述过另一条 MTOP 短信链路，但不能用那份描述代替当前 HAR，更不能混用字段或成功判据。

| 阶段 | 接口或页面 | 已核对的关联关系 |
| --- | --- | --- |
| 初始化 | `havanalogin.taobao.com/taobao_oauth_common.htm`、`/mini_login.htm` | 页面装载 H5 安全组件、Cookie 与临时登录上下文。 |
| 发送短信 | `/newlogin/sms/send.do` | 首次响应转入 `_____tmd_____/punish` 和滑块验证；再次请求返回 `smsToken`。 |
| 提交验证码 | `/newlogin/sms/login.do` | 请求使用上述 `smsToken`，响应给出账号选择跳转地址。 |
| 账号选择和转换 | `/mutiAccountSelect.htm`、`/login_token_login.htm` | 账号选择后产生新的转换结果；不能把首次跳转 token 原样当作 App 登录 token。 |
| App 会话 | `mtop.taobao.mloginservice.snslogin` | `snsLoginInfo.token` 出现在转换页响应中；该请求还需要动态 MTOP 签名及风控字段。 |
| 本人资料 | `mtop.tmall.campus.member.app.user.get` | 官方 App 使用 `x-sid` 查询资料。此记录只证明官方链路成功，不证明独立客户端可复现。 |
| 后续交换 | `mtop.tmall.campus.member.wechat.user.ucc.token.get`、`mtop.alibaba.ucc.oauthlogin` | `linkToken` 流向 UCC 登录；没有洗衣请求，无法证明洗衣需要此交换。 |

短信接口请求含 `_csrf_token`、`loginId`、`smsToken` 或 `smsCode`，以及 `bx-ua`、`bx-umidtoken`、`bx_et`、`umidToken`、`x-pipu2` 等浏览器安全字段。它们不能从一次 HAR 的旧值重放。`snslogin` 的请求体分为 `snsLoginInfo`、`riskControlInfo`、`ext`；请求头含 `x-sign`、`x-mini-wua`、`x-sgext`、`x-t`、`x-appkey`、`x-utdid`、`x-devid`。HAR 没有这些字段的生成算法。

`mini_login.htm` 的响应引用了 AWSC/Baxia 安全脚本。HAR 保留了部分脚本内容，但主登录脚本 `index.js` 和 `fireyejs.js` 的响应正文为空，无法仅凭此包复现完整浏览器风控字段。只复制请求字段名或旧值不足以构成一次新登录。

对应的天猫校园 Android APK 为 `com.tmall.campus.and` 5.7.0。离线检查确认 `InnerSignImpl.getMtopApiSign` 调用 `SecurityGuardManager.getSecureSignatureComp().signRequest(...)`，APK 含原生安全库与安全图片。这说明签名依赖 APK 的安全组件，但不能证明该组件可在西瓜课表自己的包名和签名证书下使用。Android debug 探针仅检查组件初始化，不发送登录或洗衣请求；即使初始化成功，也还须验证能为新请求生成服务端认可的签名。

在同版本天猫校园已安装的 Android 模拟器上，探针使用西瓜课表自身 `applicationContext` 初始化时得到 `SecException` 错误码 103；尝试访问来源包上下文时得到 Android `SecurityException`。阿里云的 [Security Guard 错误码文档](https://help.aliyun.com/en/document_detail/70196.html) 将 103 描述为缺少必需插件。此测试说明当前这种跨包动态加载方式没有取得签名组件，不能据此断言所有独立实现都不可能，也不能把来源包上下文当作产品依赖。

后续临时 debug 探针只为离线核对，又尝试在本应用包内加载 APK 所含的 `libsg*`。在现有 x86_64 模拟器中，`getSecureSignatureComp()` 能返回组件对象，但约一秒后本应用进程的 `libsgmainso` 后台线程发生 `SIGSEGV`，栈顶经过 Houdini 与 `sqlite3_create_module_v2`。有无安全图片均出现同类崩溃。官方天猫校园 App 在同一模拟器中也会加载此库，因此不能简单归因于 ARM64 转译；更不能把短暂取得组件对象当作有效、稳定的签名能力。没有调用 `signRequest`，也没有发送登录或业务请求。此结果不能说明 ARM64 真机一定失败。探针及提取的库、图片已从源码树移除；重新构建的 Android APK 经检查不含这些文件或探针 Activity。

随后在同一模拟器上用独立的最小 Android 应用复测：该应用没有网络权限，也不加载西瓜课表业务代码；只动态读取本机已安装的官方 APK 类，并把同一组 `libsg*` 放在自身包内。调用 `SecurityGuardManager.getInstance(...)` 时即发生原生 `SIGSEGV`，早于 `getSecureSignatureComp()` 和 `signRequest()`。这排除了西瓜课表数据库等初始化代码作为崩溃的必要条件，但仍不能区分跨包资源、包名/签名约束与模拟器环境的影响。最小探针已卸载，临时 APK、库和签名文件已删除。当前没有可靠的独立签名实现。

ADB 在雷电模拟器的干净 debug 包上确认：无学号账号可进入首页，首页洗衣按钮和“我的”页面洗衣入口可见；进入洗衣页只显示“尚未取得校园会话”的诊断状态。模拟器中没有进行新短信登录，也没有付款或启动设备。当前交付 APK 不含探针 Activity、`libsg*` 或安全图片。

## 网页认证与当前验收状态

用户现已允许在 Android 测试版内显示官方 H5 手机号短信登录页。由网页自己生成 CSRF、Cookie 和风控字段，并由用户完成实际验证码及图形验证；这些字段不从 HAR 重放。测试版尝试从洗衣网页的 H5 MTOP 环境读取 `mtop.tmall.campus.member.user.login` 的 `doHaveLogin`，再以 `mtop.tmall.campus.member.wechat.user.get` 检查是否有本人身份字段。两个接口名及登录态字段可在当前发布的洗衣网页脚本中核对，但还没有本人的新登录实测。WebView 页面加载、HTTP 200 或短信页跳转均不会显示为登录成功。

当前 HAR 中的 `havanalogin.taobao.com` 账号选择流程在 `/login_token_login.htm` 后把一次性授权结果交给宿主 App，接着由 App 调用需要动态签名的 `snslogin`。这条 **App 会话** 的签名限制仍然存在，但不能由此推断另一路 **网页会话** 必然不可用。测试版使用 `login.m.taobao.com` 的 H5 登录页回到洗衣网页，需通过新的验证码实测这一网页会话是否能够被洗衣网页识别。如果网页只返回 App 授权结果，界面会如实显示“业务会话尚未建立”。

协议验收仍需：输入新验证码，查询到本人资料，重启后恢复有效会话并识别失效。当前尚无此实测，**协议尚未通过验收**。WebView Cookie 由 Android 的应用私有 WebView 数据区管理；目前没有另行复制或持久化验证码、Cookie 或令牌。若后续实现独立凭据存储，须使用 Android Keystore。网页会话验证通过前，不接入洗衣订单查询。

## 2026-09-23 网页实测失败抓包

用户在 Android 测试版手动完成了 `login.m.taobao.com` 的 H5 短信流程。`/havanaone/loginLegacy/sms/sendSms.do` 与 `/sms/login.do` 都返回业务成功，后者给出返回洗衣页的地址，并在 `.taobao.com` 设置登录 Cookie。这个结果只确认淘宝网页认证成功。

返回 `share.confong.cn` 后，`acs-m.confong.cn` 的 `mtop.tmall.campus.member.user.login` 两次均返回 `SUCCESS` 与 `doHaveLogin=false`；`mtop.tmall.campus.share.applet.general.user.urgent.order.list` 返回 `FAIL_SYS_SESSION_EXPIRED`。请求中没有把 `.taobao.com` 登录 Cookie 当成 `.confong.cn` 的校园业务会话使用。故 **普通淘宝 H5 登录页重定向到洗衣页不能完成天猫校园登录**，重复发送短信不能解决这条会话缺口。

登录检查的响应还以 `Max-Age=-1` 清除 `.confong.cn` 的 `cookie2`；它不是新取得的有效会话 Cookie。HTTP 成功和 `ret=SUCCESS` 只表示登录检查请求执行成功，不覆盖 `doHaveLogin=false` 的业务结论。

新抓包虽出现洗衣页的列表查询，但发生在未登录状态，没有设备、付款后运行订单或完成订单的有效响应，仍不足以实现真实订单和剩余时间。测试版已把“网页返回但校园会话未建立”单独显示；此路径尚未通过协议验收。需要继续确认原抓包中一次性网页授权结果如何被受信任的 `snslogin` 转换为校园 App 会话，或找到有实测依据的网页端会话交换路径。

用户另提供的 `订单取消.har` 只有 22 条记录。与洗衣相关的仅有两次 `biz.confong.cn/.../cashier-pay` 页面 GET；响应为页面壳，没有登录、取消订单、订单详情或状态查询的业务请求。该文件不能用于判定取消接口、订单状态或洗衣会话建立方式，也不包含可供实现的设备与剩余时间字段。

## 后续完整抓包：官方 App 登录并进入洗衣页

用户重新导出的 `HTTPToolkit_2026-09-23_23-08.har` 包含 411 条记录，覆盖了一次成功的官方 App 链路。本文只记录脱敏后的字段结构，不保存该 HAR 或从中取出的任何凭据。

1. H5 `/newlogin/sms/send.do` 首次进入风控验证，完成滑块后返回新的 `smsToken`；`/newlogin/sms/login.do` 使用本次 `smsToken` 并返回账号转换页。
2. 账号转换页之后，官方 App 调用 `mtop.taobao.mloginservice.snslogin`，业务结果为 `SUCCESS`，返回 `sid`。随后的本人资料请求 `mtop.tmall.campus.member.app.user.get` 使用同一 `x-sid` 并成功。
3. `mtop.tmall.campus.member.wechat.user.ucc.token.get` 返回的 `linkToken` 确实作为 `mtop.alibaba.ucc.oauthlogin` 的 `authorizationRequest.userToken`。后者产生另一 `sid` 和 Cookie 列表。洗衣业务请求的 `x-sid` 仍与 `snslogin` 的 `sid` 相同；但 Cookie 集在 UCC 之后变化，所以仅凭此链路不能判断 UCC 交换对洗衣是否必需。
4. 洗衣页调用 `mtop.tmall.campus.share.applet.general.user.urgent.order.list`，返回成功且运行列表为空；`general.user.order.list` 后续返回历史订单，状态为已完成或已关闭。这是首次有业务结果的订单抓包，但没有已付款且运行中的订单，也没有可靠的剩余时间样本。
5. 设备列表返回两台设备。`general.device.info` 请求的 `deviceId` 对应所选列表项的 `deviceId`，`resNo` 对应其 `deviceCode`；`order.render.execute` 沿用这两个标识并返回模式和价格预览。此段是从设备列表进入详情，未记录二维码内容，不能推断二维码编码规则。

上述 App 登录、资料、UCC 和洗衣请求均含动态 `x-sign`、`x-mini-wua`、`x-sgext` 等安全字段；登录后的请求还带 `x-sid`。成功抓包证明原生 `snslogin` 会话可用于洗衣查询，同时也确认**独立动态签名仍是登录和洗衣读取的共同阻碍**。旧 HAR 凭据不能重放；在西瓜课表进程中生成新签名并完成一次新验证码登录、本人资料与洗衣查询前，协议验收仍未通过，业务入口不能显示真实订单。

同一洗衣网页在官方 App 中发出的是 `acs.m.taobao.com/gw/...` 的原生 MTOP 请求，并携带 `x-sid`；西瓜课表的普通 WebView 实测发出的是 `acs-m.confong.cn/h5/...` 请求，返回 `doHaveLogin=false`。两者不是仅改登录页返回地址就能互换的会话链路。

这份成功链路没有二维码实际内容、付款启动、运行订单或完成订单请求。`urgent.order.list` 的空结果与设备详情、模式价格预览已有样本；运行订单详情及剩余时间仍未验证。取得相应只读样本后，再确定二维码设备标识和剩余时间字段；支付及启动设备只由用户手动操作。

## 2026-09-24 新增支付及取消抓包

用户提供的三份片段分别有 159、74、22 条记录。它们没有短信发送、验证码提交、`snslogin`、本人资料查询或校园登录检查，因此不能定位西瓜课表当前登录失败的新增原因，也不能证明测试版已取得校园会话。

两份支付片段各有一个不同的结算单。`mtop.tmall.campus.cashier.applet.payment.prepay` 返回 `SUCCESS`，支付渠道为微信小程序，响应包含 `prePayInfo.prePayTn`；`mtop.tmall.campus.cashier.applet.checkout.query` 返回 `SUCCESS`、`success=true`，但结算状态仍是 `INIT`。这里的成功表示预支付或查询请求成功，**不是付款完成或洗衣机已启动**。两份片段均只观察到一个相同的原始金额值，不能从文件名“各种档位”推断各档位价格。

这些成功的 `acs-m.confong.cn` H5 MTOP 请求 URL 均有 `appKey`、`t`、`sign`、`biData` 和 `c` 参数；所记录请求没有 `x-sid` 头或 Cookie 头。取消片段中另一次 `checkout.query` 缺少 `c`，服务端返回 `FAIL_SYS_TOKEN_EMPTY`。参数存在与结果相关，但抓包不足以证明 `c` 的具体含义、生成方式或登录用途，不能重放其旧值。`share.base.user.we.chat.open.id.get` 返回的 `Set-Cookie` 是删除 `cookie2`；业务页面 GET 虽带 Cookie，也不能据此认定结算请求已建立新的校园登录态。

三个片段只出现洗衣设备详情页面 GET 和收银台页面 GET，没有二维码内容、档位接口、付款成功回调、订单取消业务接口、运行订单或剩余时间字段。“订单取消(1)”仅有收银台页面壳。当前应继续以一次新登录后本人资料和洗衣只读查询成功作为协议验收；支付 `INIT`、预支付 `SUCCESS` 和页面跳转都不满足该条件。

## 无 ARM64 真机时的离线核对

当前 ADB 只连接雷电 x86_64 模拟器；本机 Android SDK 没有独立模拟器程序或 ARM64 系统镜像。用户暂无 ARM64 真机，因此先不重复发送短信，也不把已有的原生库崩溃当成真实 ARM64 设备的结论。

成功链路抓包保存的洗衣网页脚本 `1909.js` 确认：网页调用 `mtop.tmall.campus.member.user.login`，读取 `data.doHaveLogin`，仅在为真时请求 `mtop.tmall.campus.member.wechat.user.get`。脚本中的 `sessionStorage.loginState` 用于已有页面状态的缓存判断；它没有把服务端返回的 `doHaveLogin=false` 改为已登录的能力。该网页还检测天猫校园宿主环境并使用 `JsBridge`。目前未从这些静态片段找到独立的 H5 换取校园会话接口，仍以实际服务端结果为准。

## 2026-09-24 原生桥与 ARM64 模拟器复核

离线追踪成功抓包中洗衣网页的 webpack 模块：`1909.js` 的 `member.user.login` 检查经由 `5224.js` 的 `WindVaneCaller`；`4803.js` 实现把 API 名分段后交给宿主的 `window.WindVane.call(...)`。因此官方天猫校园 App 的登录检查走原生桥，西瓜课表普通 WebView 自行调用同名 H5 MTOP 接口并不等价。当前保存的页面脚本没有呈现独立 H5 换取校园 App 会话的路径；仍以服务端实际结果为准。

在无 ARM64 真机的条件下，本轮临时下载并校验 Google 官方 Android Emulator 37.1.11 和 Android 34 ARM64 镜像，创建了独立 AVD。模拟器启动阶段直接报错 `Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host. System image must match the host architecture.`，早于 Android 启动、官方 APK 或探针安装。因此本机不能用该模拟器验证安全组件在原生 ARM64 设备中的行为。无网络权限的临时探针未运行；下载包、AVD、探针及临时签名文件均已清理。本轮没有发送短信或使用手机号。

进一步核对 `4803.js` 的另一分支：只有天猫校园鸿蒙宿主会调用 `21498.js` 的 `Bridge.asyncCall`，仍需宿主注册原生桥。环境识别模块 `98610.js` 通过天猫校园 User-Agent 和 WindVane 是否存在来区分 App 宿主。两个已观察分支均不是普通 WebView 独立换取校园会话的实现；仅修改 User-Agent 或注入同名 JS 函数不能提供真实的原生签名与服务端会话。

## 独立浏览器入口试验

在雷电模拟器自带、与天猫校园 App 分离的浏览器中直接打开洗衣页面，页面能渲染，并显示“暂无进行中订单”，但此时没有完成校园登录。这个文案是页面状态，不能作为订单接口成功返回空列表的证据；也不能覆盖先前测试版得到的 `doHaveLogin=false`。只读点开页面订单和钱包入口未观察到可用的独立登录跳转。未输入手机号、未发送短信、未支付。结合上述 `WindVaneCaller` 依赖，现有网页入口没有提供已验证的独立 H5 校园会话交换路径。

## 2026-09-24 隔离签名探针复核

为区分模拟器原生库问题和跨包上下文问题，本轮建立了**无互联网权限**的独立 Android 探针；它不包含西瓜课表业务代码，也没有发送短信、登录或洗衣请求。探针用 `createPackageContext` 只读取本机已安装的天猫校园 APK 类与资源。在直接把来源包 `Context` 传给 `SecurityGuardManager.getInstance` 时得到 `SecException 109`；同期 Android 日志显示安全组件尝试修改官方 App 私有目录 `app_SGLib`，遭到 `EACCES`。这次 109 与跨包私有目录访问直接相关，不能概括成签名算法完全不可用。

让探针的 `ContextWrapper.getDir/getFilesDir/getCacheDir/getDataDir` 使用**探针自己的私有目录**后，错误变为 103；Android 日志显示仍缺安全插件。仅在这个临时探针 APK 中放入用户提供的官方 APK 内四个 `libsg*` 原生库，安全组件对象可以返回。最初后台线程因探针缺少 `ACCESS_NETWORK_STATE` 普通权限退出；补上该权限后进程持续运行。该探针仍没有 `INTERNET` 权限。组件内部还尝试写入官方 App 的 `shared_prefs` 并被拒绝；此项不影响本次离线签名测试，但属于未解决的兼容风险。

离线反汇编同一 APK 的 `InnerSignImpl` 可见：`getMtopApiSign` 将请求字段转换为 `SecurityGuardParamContext`，设置 `requestType=7`，再调用 `ISecureSignatureComponent.signRequest`；输入包含 `utdid`、`uid`、`reqbiz-ext`、`data` 的 MD5、`t`、`api`、`v`、`sid`、`ttid` 等字段，另有可选业务字段。`getMiniWua` 属于另一条安全组件调用，不能把 `x-sign` 一项当作完整的 MTOP 请求安全字段。

使用抓包里的应用标识、但**全新合成且不含账号信息**的两份输入，隔离探针在本机生成了两个不同的非空、50 位十六进制签名；只记录“非空、长度和是否不同”，没有输出签名值。这个结果证明当前模拟器在上述隔离条件下能调用动态签名方法，修正了先前“组件初始化一定崩溃”的推断。它**不证明**签名会被服务端接受，也不证明 `x-mini-wua`、`x-sgext`、设备字段和新短信登录流程完整可用。探针依赖本机已安装的官方 APK 类及其原生库；西瓜课表 debug APK 没有加入这些私有组件，仍不能声称实现了独立签名或登录。下一阶段只有在合法且可维护的独立签名来源、服务端新请求验证、本人资料查询及重启恢复均成立后，才能越过洗衣业务接入门槛。

### 完整安全字段的进一步核对

同一成功 `snslogin` 请求同时有 `x-sign`、`x-mini-wua`、`x-sgext`、`x-umt` 等头。官方 APK 的 `InnerSignImpl.getMiniWua` 把环境和 API 名交给 `IMiddleTierGenericComponent.getMiniWua`；`getUnifiedSign` 则把请求参数与是否使用 WUA 等配置交给 `IUnifiedSecurityComponent.getSecurityFactors`。客户端请求构造代码还会分别处理这些返回字段。由此可确认：探针仅离线生成 `x-sign`，没有生成完整的新 `snslogin` 请求安全上下文，不能直接拿它做新验证码登录的服务端验收。所有字段值须由当前请求和当前设备状态产生，不能引用 HAR 的旧头值。

## 2026-09-24 回调关联与一次匿名资料请求

成功抓包的 `/login_token_login.htm` 页面将一次性 `top_auth_code` 交给 `www.alipay.com/webviewbridge`；同一次流程紧随其后的 `snslogin` 请求中，`snsLoginInfo.token` 与该授权码**完全相同**。这是可核对的数据传递关系，不是从接口先后顺序推断。此授权码属于 App 登录输入，单独得到它并不代表已有校园会话。Android 测试版据此收紧回调判断：只有 `webviewbridge` 同时带 `action` 和非空 `top_auth_code` 时，才报告“取得 App 授权结果”；不记录或持久化授权码。

隔离探针在本机生成了新的 UTDID、时间戳与合成资料请求参数，用官方 APK 的 `InnerSignImpl.convertInnerBaseStrMap` 组装精确的签名输入，再调用统一安全组件。新请求离线返回 `x-sign`、`x-mini-wua`、`x-sgext`、`x-umt` 四个非空字段；更换请求时间后 `x-sign` 随之变化。这证明动态字段能在该**依赖已安装官方 APK 代码与原生库**的探针中生成，并不证明西瓜课表可独立生成或服务器认可它们。

在用户要求重新触发审批、且系统允许执行后，探针只显式发出了一条不带手机号、验证码、Cookie 或 `sid` 的本人资料 GET。服务端 HTTP 为 200，业务错误为 `FAIL_SYS_PROTOVER_MISSED`。阿里云的 [MTOP 错误码表](https://apsara-doc.oss-cn-hangzhou.aliyuncs.com/apsara-pdf/emas/v_2_5_3_1/emas/zh/development-guide-2.pdf) 将其列为“缺少 mtop 协议版本”；本次请求确实未设置成功抓包中存在的 `x-pv`。因此它发生在更早的协议参数阶段，**不能**当作签名通过、会话失效或本人资料查询成功。此前自动审批曾因设备标识和动态安全字段外发而拒绝这一步；本次获准后只执行这一条显式只读请求，没有重试。

成功抓包中的 `x-devid` 为稳定的 44 字符 URL 安全编码值，与 `snsLoginInfo.deviceId` 一致，不等于 24 字符的 `x-utdid`。官方 SDK 的 `DeviceIDManager` 先读本地持久化值；远端流程使用 `MtopSysNewDeviceIdRequest` 取得并保存新的 `device_id`。成功 HAR 未覆盖该设备首次注册，不能将旧 `x-devid` 复制到新客户端，也不能把随机 UUID 称为已验证的设备 ID。下一次网络验收前要补全协议版本，并独立核对设备注册和其他必需头；任何新请求都需单独授权。

为修正上述缺少 `x-pv` 的问题，曾准备带协议版本及同类静态请求头的第二条匿名资料请求。自动审批当时因再次外发新生成的设备标识、动态安全字段及可能的安全组件遥测而拒绝执行；在用户**另行明确授权这一条**后，才重新构建并启动一次性探针。前两次启动因本地参数类型错误停在发请求之前；修正后只发出一条新的匿名资料 GET，HTTP 200，业务码为 `FAIL_SYS_ILEGEL_SIGN`。这表示本次签名未被服务端接受，既不是会话过期，也不是本人资料查询成功。探针预先写入仅发送一次的本地标记，并已从模拟器卸载；没有重试该网络请求。

离线比较显示，成功抓包的资料请求 `data` 含一个 `platForm` 字符串字段，本次匿名探针使用空 JSON；成功抓包中的 `x-sign`、`x-mini-wua`、`x-sgext` 长度分别约为 106–110、195–203、962–1000，本次探针约为 102、185、332。这些长度差异仅能说明请求与安全环境不同，不能单独定位非法签名的唯一原因。探针仍使用未注册的合成 `deviceId`，并依赖本机已安装的官方 APK 代码及原生库；未达到独立客户端的登录验收门槛。后续须先离线确认设备首次注册、签名输入、风控上下文和协议字段，避免盲目发送更多请求。


离线反汇编进一步确认，`DeviceIDManager.getRemoteDeviceID` 先读取本机 UTDID，并根据 SDK 开关决定是否同时读取原始 IMEI、IMSI、设备序列号及 Android ID，然后构造 `MtopSysNewDeviceIdRequest`；成功响应中的 `device_id` 才会保存供后续请求使用。本轮探针没有调用该注册接口，发送的是新生成但**未注册**的合成 `deviceId`。现有 HAR 缺少设备首次注册过程，不能据此推断具体是哪一项导致 `FAIL_SYS_ILEGEL_SIGN`，也不能把采集这些设备信息当作已验证的项目实现。

已对用户提供的六份 HAR 逐一搜索 `mtop.sys.new.deviceid`、`newdeviceid` 及 `device_global_id`，均未发现设备首次注册链路。因此无法从现有抓包复原已注册 `x-devid` 的新请求前置状态。

## 2026-09-24 隔离用户首次启动抓包

用户在雷电模拟器临时 Android 用户中启用抓包后，首次启动未登录的官方天猫校园 App，导出 `HTTPToolkit_2026-09-24_16-14.har`（111 条记录）。原始 HAR 仅留在用户本机，不复制到仓库；以下只保留脱敏结构和结果。

- 第 18 条请求（从 1 开始计数，数组索引 17）为 `acs.m.taobao.com/gw/mtop.sys.newdeviceid/4.0/`，GET，HTTP 200，业务 `SUCCESS`。请求 `data` 含 `new_device`、`device_global_id`、`c0`～`c6`；其中 `c3`～`c6`、`c2` 为空字符串，其余字段不记录具体值。请求未带 `x-devid`，但带当前设备/请求的动态安全字段。
- 响应 `data.device_id` 为 44 字符；后续 9 条 `acs.m.taobao.com` 请求的 `x-devid` 与本次返回值逐字节相同。由此确认官方 App 首次注册设备后复用服务端返回的 ID，不能用客户端随机生成的 44 字符串替代。
- 首次启动期间还有多个无需登录即可成功的校园配置请求；一个需要账号会话的请求返回 `FAIL_SYS_SESSION_EXPIRED`。这符合隔离用户未登录状态，不能把公开请求的 `SUCCESS` 当作手机号登录完成。
- 本次 HAR 补全了前六份抓包没有的设备注册环节，但仍未揭示安全组件如何在**独立客户端**生成会被服务端认可的签名。此前探针依赖已安装的官方 APK 与原生库，且其一次新匿名资料请求返回 `FAIL_SYS_ILEGEL_SIGN`。设备注册是已验证的前置步骤，不足以单独通过登录协议验收；不据此接入真实洗衣订单。
- 对同一请求做内部相等性核对：`data.device_global_id` 与 URL 解码后的 `x-utdid` 完全一致（原始编码文本不相同）。这进一步确认设备注册以当前 UTDID 为输入，但不揭示动态签名算法。

## 2026-09-24 继续核对：编码长度与设备注册边界

本轮只离线读取首次启动 HAR 与用户提供的 APK，没有安装或运行安全组件，没有外发网络请求、发送短信或使用旧会话。新增 `tools/audit_tmall_bootstrap.py`，只输出计数、固定字段的长度和内部相等性，不输出原始头、响应、签名或设备标识。其三项合成数据测试覆盖编码、注册失败、响应解析失败和脱敏输出。

### 修正此前的长度比较

首次启动 HAR 共 111 条，含 21 条带 `x-sign` 且有可解析响应的原生 MTOP 请求：

| 字段 | HAR 中发送长度 | 一次表单 URL 解码后的长度 |
| --- | --- | --- |
| `x-sign` | 102～116 | 全部为 102 |
| `x-mini-wua` | 105～201 | 101 或 185 |
| `x-utdid` | 30 | 24 |
| `x-sgext` | 368～848 | 364～824，随请求变化 |

此前记录的探针 `x-sign` 长度约 102、`x-mini-wua` 约 185，与官方字段在解码后的部分长度一致。此前未统一编码状态的长度对比不能用作“签名生成方式错误”的证据；长度一致同样不能证明签名正确。`x-sgext` 的差异仍存在，但不足以单独归因。

APK 的 `mtopsdk.mtop.protocol.converter.impl.AbstractNetworkConverter.buildRequestHeaders` 对协议映射字段调用 `URLEncoder.encode(value, "utf-8")`。额外头的编码另受布尔参数控制，不能据此把全部 HTTP 头都编码。应分清安全组件原始输出与线路上的编码值；特别是 `+`、`/`、`=`、`%`，防止漏编码或重复编码。旧探针源文件及实际发包记录目前不在工作区，无法据此确认此前匿名请求是否发生编码错误。

### 设备注册不是所有请求成功的必要条件

- 12 条带签名且没有 `x-devid` 的请求全部返回 `SUCCESS`，其中包括设备注册以及公开配置请求。
- 另 9 条携带的 `x-devid` 与注册响应一致；其中 8 条成功、1 条会话过期。
- 注册请求不带 Cookie 或 `x-sid`，但带动态安全字段。必须先具备可用签名能力，才能完成这一注册；不能用设备注册绕开签名问题。
- 这些结果不证明本人资料接口接受无设备 ID 请求，也不证明任意伪造的设备 ID 可用。只能排除“所有请求必须先有设备 ID 才能成功”的泛化判断。
- HAR 记录顺序不能替代请求完成顺序，本文的“后续复用”仅指记录顺序及值相等，不推断请求串行执行。

### 后续应分层核对

离线反汇编再次确认 `InnerSignImpl.convertInnerBaseStrMap` 从参数中读取 `deviceId`、`utdid`、`t`、`api`、`v`、`sid` 等字段，对 `data` 字符串计算 MD5。`getUnifiedSign` 再把转换结果与 `appkey`、`useWua`、`env`、`authCode`、`extendParas`、`requestId` 等上下文交给私有安全组件。这确认需要核对完整上下文，不能只比较最终签名长度。

下一次实现应先离线验证：正文只序列化一次且签名/发送复用同一字符串；签名时间与请求头时间一致；UTDID 使用正确的原始值；注册请求不伪造 `x-devid`；注册成功后签名输入与请求头使用同一设备 ID；协议映射头只编码一次。通过这些检查仍不等于拥有独立签名算法。

当前结论仍为：没有服务端认可的独立签名实现，不能宣称登录完成。无法从本轮证据唯一定位旧匿名请求的 `FAIL_SYS_ILEGEL_SIGN`；不能断言只补设备注册或只修编码即可成功。优先验证一个全新、匿名公开配置请求的签名与编码，再验证新设备注册；避免用含账号信息的登录请求盲试。正式登录验收仍要求新验证码、本人资料和洗衣只读查询成功。

复核工具（路径由调用者提供，原始 HAR 不进入仓库）：

```powershell
py tools/audit_tmall_bootstrap.py '<首次启动 HAR 路径>'
py -m unittest discover -s tools -p test_audit_tmall_bootstrap.py
```

本轮未改 Android 业务代码，因此未重新运行 Gradle 或生成 APK；此前测试包不因此获得登录能力。

## 离线请求契约实现

新增 `tools/tmall_request_contract.py`，实现可审查的**离线诊断前置模块**，没有网络发送、签名生成、短信登录或 APK 动态加载能力。没有将它接入 Android 产品代码，也没有使用原始 HAR 凭据构造新网络请求。

当前只覆盖已观察到的匿名配置查询 `mtop.tmall.campus.guide.advertising.config.list/1.0`（空正文）和首次设备注册 `mtop.sys.newdeviceid/4.0` 的组装一致性：

1. `RequestSnapshot.freeze` 只序列化一次正文，固定时间戳及设备上下文；签名前参数表不可修改。正文 MD5 仅供内存核对，不输出。该参数表不等同于完整签名串。
2. 首次注册不能预设 `deviceId`，正文 `device_global_id` 必须等于原始 UTDID。后续请求如提供设备 ID，会在参数表和请求头中复用相同值；本模块不能证明该 ID 确实由服务端注册取得，来源仍由上层负责。
3. 时间戳限定为当前观察到的十位秒值，拒绝误传十三位毫秒。应用标识、协议版本等由调用者显式提供，不在源码中硬编码真实设备或账号信息。
4. `RawSecurityFactors` 接收外部产生的原始安全字段；不生成签名，空字段立即报错。`preview` 根据已确认映射编码为内存中的线路预览。
5. `check_wire` 对照原始快照和安全字段，报告正文变化、时间或设备变化、漏编码、多编码、重复头、意外 Cookie 等固定错误码。不会打印不匹配值。对象默认表示隐藏内容。

编码器按 Java `URLEncoder` 的 UTF-8 规则实现：空格为 `+`、字面量加号为 `%2B`、`*` 保留、`~` 编为 `%7E`。已用本机 Java 编码器对四组合成向量交叉验证，包含全部 ASCII 字符、中文、emoji、百分号和加号，全部一致。不能直接用普通 URL 路径编码器代替。

扩大后的离线 HAR 工具检查协议映射头和四个安全头，以及 `data` 的线路编码。首次启动 HAR 的 21 条已解析签名请求中：除 `x-devid` 仅出现 9 次外，其余当前检查字段均出现 21 次，全部符合 Java 表单编码规范；21 个正文编码也全部符合。**规范编码不证明只编码了一次，更不证明签名有效。**新增测试明确覆盖“双重编码仍能满足线路规范”的情况；发现多编码一层需要独立保存的原始安全字段作为比较依据。

测试命令：

```powershell
py -m unittest discover -s tools -p 'test_*.py'
```

本阶段共 13 项离线测试通过。这里只确认本次新实现的组装一致性规则；旧探针是否符合仍未知。未重新构建 Android APK，未提交或推送。

下一阶段的诊断组件必须接收同一冻结快照，并保留原始输出供发送前比较。还需逐项补全私有安全组件的上下文、额外协议头及服务端验收；不能把 `WirePreview` 当作已经完整可发送的请求。依赖官方 APK 的诊断基准即使成功，仍须另行解决独立签名来源，才能进入新短信登录验收。

## 隔离签名基准已复测（离线）

本轮新增可审查源码 `tools/tmall_probe/` 与构建脚本 `tools/build_tmall_offline_probe.py`。临时 APK 包名为 `vip.mystery0.xhu.timetable.offlineprobe`，与西瓜课表和官方 App 分开。检查打包后的 Manifest 确认只有 `ACCESS_NETWORK_STATE` 权限，没有 `INTERNET`；应用启动时也核实网络权限未授予。

构建脚本仅从首次启动 HAR 取应用的静态协议配置，不读取旧安全字段或会话用于探针。每次生成合成 UTDID、当前时间戳，以空正文配置查询建立同一冻结快照，不设置设备 ID、手机号、验证码、Cookie 或 `sid`。注意，合成 UTDID 并未通过服务器设备注册。

探针在雷电模拟器中使用已安装官方 APK 的类，以及用户提供的 APK 中四个安全库。`ContextWrapper` 将 Java 私有目录和 SharedPreferences 重定向到探针自己的目录。关闭 SDK 的可配置日志输出，探针只写入固定字段的脱敏结果，不保存原始安全字段。

实际结果：

| 检查项 | 结果 |
| --- | --- |
| 网络权限 | 未授予 |
| 四个安全字段 | 均非空 |
| 原始 `x-sign` / `x-mini-wua` 长度 | 102 / 101 |
| 原始 `x-sgext` / `x-umt` 长度 | 332 / 24 |
| SDK 编码头与契约比较 | 检查 11 个头，全部一致 |
| 预览中设备 ID / 会话 | 均不存在 |
| 更改时间戳后的签名 | 非空且与前一次不同 |
| 冻结正文 | 保持不变 |
| 探针运行 | 完成，结束核对时进程仍存活 |

签名和 SDK 转换都使用冻结输入的副本，编码比较针对同一次安全组件输出；不把不同时间生成的签名拿来做字符串相等比较。时间戳变化试验固定其他显式输入，但安全组件可能有自己的内部状态变化，因此这里只记录现象，不声称完成严格密码学变量控制。

本轮首次使新的离线契约与真实 SDK 的头转换结果在同一进程中完成比较。它减少了重建探针时发生编码偏差的风险，**不证明旧匿名请求的失败原因，也不证明服务器会认可新签名**。尚未发送任何公开配置、设备注册或登录网络请求；仍未获得独立签名实现。

13 项离线回归测试继续通过，临时 APK 构建与签名验证通过；未重建或替换西瓜课表 APK。探针已从模拟器卸载。构建成功后临时密钥已删除，但自动执行策略拒绝了对应构建目录的递归清理，未提供更具体原因；`build/tmall-contract-probe/9027f57eab19` 仍含临时 APK 和安全库等构建产物，位于 Git 忽略范围，不得提交。未提交或推送本轮源码、测试与记录。

## 新匿名请求首次成功（本机发送器单次验收）

用户要求作出下一步决策并执行后，本轮选择验证一个新匿名公开配置请求，暂不发送短信或注册设备。此节更新此前“尚无服务端成功新请求”的阶段状态，**独立签名与登录仍未完成**。

为避免私有安全组件自行联网，Android 探针仍未申请 `INTERNET`。构建、启动时产生新的合成 UTDID、时间戳和安全字段；应用静态配置来自抓包，但没有复用抓包的签名、设备标识、验证码、Cookie 或会话。SDK 的 11 项头转换继续与契约完全一致。

探针新增显式的候选准备模式：只在应用私有目录暂存这一次新产生的冻结参数、安全字段原文及 SDK 编码预览。独立本机脚本 `tools/verify_tmall_anonymous_once.py` 经 ADB 读取到内存，原始字段没有进入模型输出或本机结果日志。脚本核对输入不超过 120 秒、目标 API、空正文、全部参数及编码一致性，拒绝会话、Cookie、设备 ID 或额外头，然后在建连前创建排他尝试标记。

本次实际显式网络请求共 **1 条**：

```text
GET acs.m.taobao.com/gw/mtop.tmall.campus.guide.advertising.config.list/1.0/
HTTP 200
ret: SUCCESS
```

未跟随跳转、未自动重试、未使用响应 Cookie。没有调用设备注册、短信、本人资料、订单、支付或启动接口。该结果证明本轮新生成的签名请求获得公开配置接口正常业务响应；它不证明服务端对每个安全字段的校验强度，不证明新设备已注册，也不能单独将旧 `FAIL_SYS_ILEGEL_SIGN` 归因于编码，因为两次请求 API、参数及设备上下文并非严格一致。

当前基准仍依赖官方 APK 类和四个私有原生库，不满足用户最终的独立实现目标。不能把此结果用于宣称西瓜课表登录完成或直接把探针打包进产品。下一步决策为：固定成功的组装流程，先离线核对注册请求的剩余字段及 SDK 生成规则，再用新的注册流程验证设备 ID 取得和复用；仍不直接尝试短信登录。

19 项测试通过，新增测试使用伪连接验证：一次发送、超时不重试、过期或混入 Cookie 拒绝发送、重定向不跟随及响应脱敏。真实服务器请求不属于自动化测试。临时探针已卸载，私有候选文件随应用数据删除；本机仅保留 Git 忽略的构建产物及单次尝试标记（本轮目录 `build/tmall-contract-probe/f9aa303214ac`）。未替换西瓜课表 APK，未提交或推送。

## 2026-09-25 设备注册与复用通过、Android 测试构建完成

用户要求继续验证并尽可能构建测试。本轮先反汇编核对 `DeviceIDManager.getRemoteDeviceID`：`c0`、`c1` 对应 `Build.BRAND` 和 `Build.MODEL`；注册调用设置 `bizId=4099`。新诊断使用当前模拟器品牌和型号，以及新合成 UTDID；`c2`～`c6` 为空，不读取手机号、IMEI、IMSI 或序列号。抓包样本的 `new_device` 为字符串 `"true"`。

第一次显式注册请求返回 HTTP 200、`FAIL_SYS_ILEGEL_SIGN`，流程立即停止，没有继续配置查询。排查发现探针沿用了请求对象构造函数中的 `mtop.sys.newDeviceId`；但 SDK 真正的 `InnerProtocolParamBuilderImpl.buildParams` 在放入签名参数前会通过 `Locale.US` 转小写。此前只把 URL 路径转小写，签名输入仍有大写，存在明确的实现偏差。

修正 `RequestSnapshot.freeze` 在签名前规范化 API 名，补上回归测试后，重新构建并显式执行一次新的验证，结果：

| 阶段 | HTTP / 业务结果 | 说明 |
| --- | --- | --- |
| 修正后的新设备注册 | 200 / SUCCESS | 返回结构有效的 44 字符设备 ID |
| 使用该 ID 的新配置请求 | 200 / SUCCESS | ID 与本次注册响应一致，未从 HAR 复制 |
| SDK 头转换核对 | 12 项一致 | 包括新加入的 `x-devid`，仍不带账号会话 |

本轮实际网络请求总计 **3 条**：首次失败注册、修正后的注册、注册后配置查询。不存在自动网络重试，也没有发送短信、获取本人资料、查询订单、付款或启动设备。两次注册之间修正了已核实的参数构造偏差，但也使用了新上下文，不能用它解释此前所有不同接口上的签名失败。

新增 `tools/verify_tmall_registration_cycle.py`，注册结果只经内存与探针私有目录交给下一阶段，不出现在命令参数、日志或仓库。探针仍没有网络权限；两次临时安装均已卸载，私有候选及设备 ID 随应用数据删除。临时构建产物仅在 Git 忽略的目录中：失败轮 `build/tmall-contract-probe/7c5a61a359e0`、通过轮 `build/tmall-contract-probe/13dbe7a3b72a`。

离线测试增加到 22 项且全部通过，包括 API 大小写规范化、注册 ID 只在有效成功响应后交给下一阶段、复用 ID 必须与本次注册相同。首次 Gradle 构建因未设置 SDK 路径失败；仅在构建进程设置 `ANDROID_HOME` 后，`androidApp:assembleDebug` 成功（包含 `composeApp:compileAndroidMain`），未改写本机路径到源码或项目配置。

standard debug APK 已生成并通过签名验证，检查确认不含 `libsg*` 或探针 Activity；store debug 也构建成功。交付包仍是现有游客入口与 H5 会话诊断版，**本轮注册成功发生在独立诊断流程，没有接入西瓜课表登录页面**。因此此包不具备独立短信登录、本人洗衣订单或倒计时能力。

当前已通过：新匿名配置请求、设备注册、新设备 ID 复用。仍未通过：脱离官方 APK 私有组件的独立签名、新验证码登录、本人资料与订单查询、会话持久化恢复。不得把诊断私有库混入产品包，也不得把设备注册成功显示为账号已登录。未提交或推送。

## 2026-09-25 独立登录依赖复核：正文 WUA 尚未实现

用户要求完成独立短信登录后，重新核对两份当前本机 HAR：`登录数据 root.har` 为 157 条，成功完整链路 HAR 为 411 条。两份均包含成功的原生 `snslogin`，请求正文为 `snsLoginInfo`、`riskControlInfo`、`ext`。只输出字段结构与内存相等性，不保存或重放实际授权码及会话。

成功完整链路中，`riskControlInfo.wua` 非空，长度 241，与 URL 解码后的 `x-mini-wua` 不同；`riskControlInfo.umidToken` 与解码后的 `x-umt` 相等，`snsLoginInfo.deviceId` 与 `x-devid` 相等。正文的时间字段不能全部强制等于 MTOP 请求头时间：该样本 `riskControlInfo.t` 是 13 位，`snsLoginInfo.t` 长度为 1，而请求头 `x-t` 是秒级。此前离线契约关于时间戳一致性的规则仅约束 MTOP 签名输入与请求头，不能扩大到所有登录正文时间字段。

离线追踪用户提供 APK 的 `classes2.dex`：

- `com.ali.user.mobile.login.service.impl.UserLoginServiceImpl.snslogin` 调用 `buildBaseRequest` 组装登录参数，再通过 `SecurityGuardManagerWraper.buildWSecurityData` 取得风险上下文。
- `SecurityGuardManagerWraper.getWUA` 取得 `SecurityGuardManager` 的 SecurityBody 组件，以当前毫秒时间参与构造，通过 `getSecurityBodyOpen` 或 `getSecurityBodyData` 路径产生 WUA。
- 因此登录正文 WUA 是另一项私有安全组件依赖，不是把请求头 `x-mini-wua` 改名或复制到正文即可完成。尚未在独立客户端生成并验证这一登录正文。

本轮搜索未找到已验证可直接替代的独立短信登录实现。[官方 QN.mtop 文档](https://g.alicdn.com/x-bridge/qap-sdk/2.1.2/docs/api/api-mtop.html)存在 `H5Request` 选项，但这只说明 SDK 有网页请求方式，不能证明 `snslogin` 支持无需原生组件的等价授权交换。当前抓包的成功路径仍是原生 MTOP；没有足以交付的独立 H5 替代链路。

决策：在“不得依赖官方 APK 私有组件”的既定边界下，独立签名及登录 WUA 两项仍未解决，本轮不能交付可用的独立短信登录。不得通过扩大探针对官方类和库的复用范围来改称独立实现，也不在这些依赖未解决时发送真实验证码进行盲试。没有更改 Android 产品代码、发送短信或构建新的所谓登录成功包；此前可安装 APK 仍仅为诊断版。

## 2026-09-27 Android 本机组件登录路线

用户随后明确要求“走能实现登录的路线，无论什么方法”，允许调整此前的独立实现限制。本轮改为 **依赖已安装天猫校园 5.7.0 的 Android debug 兼容实现**。该决定取代上文关于测试包不得包含私有组件的限制；不应再称为独立短信协议实现。未改动 release 登录路径，未提交或推送。

新增实现：

- `androidApp/src/debug/java/vip/mystery0/xhu/timetable/laundry/`：独立进程认证 Activity、校园请求客户端、Keystore AES-GCM 存储。
- `tools/prepare_tmall_login_debug.py`：只从 HAR 提取五项公开应用配置，从本机 APK 提取已核对的 ARM64 组件到忽略的 `androidApp/build/generated/tmallDebug`。没有复制原用户设备 ID、会话、验证码、签名或授权码。
- 首次注册本应用设备，在自己的不可备份目录保存加密状态；组件使用本应用私有目录，不读取官方 App 私有会话。
- 使用 `havanalogin.taobao.com/taobao_oauth_common.htm` 的校园应用授权上下文，支持用户自行进入短信表单；不再使用普通淘宝登录后跳洗衣页的旧入口。
- 仅接收 HTTPS、主文档、固定域名和路径、`action=taobao_auth_token` 的一次性授权回调；当前流程只处理一次，不把授权码写入 Intent、日志或持久化文件。
- 新授权码进入原生 `snslogin`。登录正文 WUA 与 UMID 由当前组件动态生成；请求签名在正文序列化后生成。
- 只有本人资料和待处理洗衣订单查询均通过，才持久化会话并向课表页返回成功。空订单列表只能解释为待处理列表为空，不能据此编造设备剩余时间。
- 请求入口仅允许设备注册、登录交换、本人资料、待处理订单四个 API，没有付款或启动设备调用。请求超时后不自动重试。

本机验证结果：

1. 原有 22 项协议契约测试通过。
2. `androidApp:assembleStandardDebug` 成功，包含共享层 `composeApp:compileAndroidMain`。
3. 新包安装到模拟器成功。通过课表首页洗衣入口打开认证 Activity，当前设备注册及登录 WUA/UMID 检查通过，状态日志仅包含 `device_ready=true;login_security_ready=true`。
4. 授权页面加载成功；点击“短信验证码登录”后能看到手机号输入、获取验证码和确认授权表单。没有代替用户输入手机号、发送短信或提交验证码。

**用户实机反馈（2026-09-27）**：本次测试版已完成短信授权并登录成功；新授权码完成 `snslogin`，本人资料与待处理洗衣订单查询均通过。没有收到具体响应数据，不记录或推断订单数量、订单状态、设备标识和剩余时间。当前实测说明这条 Android debug 登录链路可用；进程退出后从加密存储恢复会话、会话失效后的重新登录仍待实机验证。现有登录正文未接入 SDK 的 Alipay 设备风控 `apdId` 和来源扩展 `aFrom`，不能据此推断其他设备与账号的兼容性。UCC/Cookie 交换是否为部分洗衣接口必需也仍待验证。扫码内容、运行订单剩余时间协议尚缺样本。

测试时同一手机需安装天猫校园 5.7.0 和本项目 standard debug APK；进入“我的 → 洗衣服务”或首页洗衣按钮，在页面内完成验证码和授权。不要把验证码或会话发送到聊天。生成组件只在 debug source set 中引用，不能把该测试包作为无依赖的公开发布版本。

本次附带的 `订单取消.har`、`微信支付及各种档位.har`、`微信支付取消.har` 与上文 2026-09-24 分析的三份片段相同：它们只提供收银台预支付和 `INIT` 结算查询等证据，没有付款成功、设备启动、运行订单或剩余时间响应。文件名不能替代业务结果。下一步仍需扫描真实二维码后的设备详情与档位、用户自行支付并启动后的运行订单查询、洗衣结束后的完成状态抓包；在取得响应字段前不添加虚构倒计时或自动付款、启动调用。

用户随后确认自己已完成微信支付。重新检查 `微信支付及各种档位.har` 的请求顺序，能看到微信小程序支付入口、预支付返回以及一次状态为 `INIT` 的结算查询；该查询发生在收银台页面返回之前，后续没有同一结算单的终态查询或校园洗衣运行订单响应。用户已付款与 HAR 没有记录付款完成业务回调可以同时成立。当前不能把 `prepay` 的 `SUCCESS` 或小程序跳转判为支付完成，也不能用这份片段推导洗衣机启动结果。

Android debug 页面现可显示新会话验证时返回的待处理订单数量，提供手动刷新和已保存会话检查入口。数量来自当前请求响应，不保存订单内容，也不把待处理订单自动标记为运行中。扫码入口使用本应用内的相机画面和本机二维码解码，不打开二维码链接；后续只将识别出的设备编号用于洗衣设备只读查询，不保存二维码原文或启动设备。

支付 HAR 的 `deviceDetail` 页面跳转中，`result` 参数是 `https://share.confong.cn/cf` 链接，含 `id`、`biz`、`isv` 三个参数。扫码器据此将同结构的二维码标为“已识别校园洗衣二维码”；它没有证据确认 `id` 与 `general.device.info` 的 `deviceId` 或 `resNo` 如何对应，所以尚不请求设备详情。其他格式标为待确认。真实洗衣机二维码、运行订单和剩余时间仍需实机验证。

## 2026-09-27 扫码后只读设备详情

重新对照成功的官方 App 抓包和两份支付片段，二维码链接的 `id` 与前者设备列表中的 `deviceCode` 相同，不等于列表的 `deviceId`。官方 App 的 `DEVICE_INFO_GET` 请求将 `deviceCode` 放入 `resNo`，另传列表给出的 `deviceId`。这建立了已观察到的一种扫码映射，但尚未验证其他机型或二维码格式。

Android debug 客户端据此在扫码后先查常用设备列表，未找到时查询可用楼栋并分页查设备列表，使用新会话签名读取命中设备的详情。列表与详情的设备标识必须互相匹配。页面只接收设备名称、楼栋、楼层、可用状态和开放档位的显示字段；原始二维码与设备标识不写日志、不存储。当前查询尚待用户真机验证，扫描未命中会明确显示找不到设备。

详情响应的 `deviceWorkingModelDTOS[].priceModelList[]` 含档位描述、开放状态和 `priceYuan`，页面以“参考价”展示。官方链路中 `order.render.execute` 的服务项目 ID 与档位 `key` 相同、单价与档位 `price` 相同，但当前尚未接入订单预览。现有抓包没有 `share.order.create.execute` 的实际请求，也没有付款完成后的启动链路。网页脚本出现相关接口名不能确定创建订单正文、成功判据或支付确认流程；本轮不发送创建、预支付或启动请求。

## 2026-09-27 实机扫码反馈与设备详情查询修正

用户实机扫码后反馈“已识别二维码，但设备详情查询失败”。原实现必须先在常用设备列表或楼栋分页列表中找到二维码对应的 `deviceId`，再请求详情；这个前置条件不适用于列表外设备。已检查抓包中的官方页面脚本：`getDeviceInfo` 始终传 `resNo`，仅在已有 `deviceId` 时附加它。因此 Android debug 版改为先用扫码得到的 `resNo` 直接只读查询设备详情；若服务端明确拒绝，再按已抓到的列表路径补查。返回的 `deviceCode` 仍必须与扫码编号一致。

失败提示现在区分校园服务拒绝、签名拒绝、网络错误、响应结构异常与设备编号不一致，均不包含原始二维码、响应正文或会话。该修正只完成构建，尚待用户实机复测；不能把构建成功视为设备查询成功。付款及启动仍未接入。


## 2026-09-27 单应用安装改造

用户已反馈上一版“验证通过，登录成功”，因此上一版账号验收状态更新为用户实机通过。随后用户明确要求只安装西瓜课表。本轮保留现有扫码、设备查询等未提交修改，只调整组件加载方式。

- 新增 `BundledCampusRuntime`：从西瓜课表资产复制内置运行时，校验 SHA-256，以只读文件和独立 ClassLoader 加载代码与资源；同一进程缓存并复用加载器。
- 运行时位于本应用不可备份私有目录；动态代码不从网络下载。新包不再调用 `createPackageContext` 或检查天猫校园安装版本，删除对应 package queries。
- `prepare_tmall_login_debug.py` 在构建机准备官方 5.7.0 原 APK 运行时、公开配置和安全库。手机不需要安装或手动导入官方 APK；构建机仍需要合法取得的原始组件。
- 当前为完整运行时内置验证方案，APK 约 163 MB，后续可以单独做依赖裁剪。它解决的是单应用安装，不是完全独立的协议/密码学实现。
- 保留已有加密会话的文件格式、Keystore alias 和设备标识，不清除用户登录状态。

已在模拟器新建测试用户 `CampusBundledTest`（用户 11）。该用户下 `pm list packages --user 11 com.tmall.campus.and` 为空，实际认证进程归属 `u11_a77`。新包完成设备注册、WUA/UMID 检查，并打开带“短信验证码登录”的账号授权页。没有卸载主用户的天猫校园，也没有在测试用户发送短信、付款或启动设备。

注意：上一版用户验证登录成功不能代替本版真实账号验收。新包仍需用户验证原会话读取或新短信登录，以及本人资料、订单查询。不得仅凭组件初始化和授权页打开成功宣称本版端到端登录已实测完成。

最终验证：`androidApp:assembleDebug` 成功（standard/store 两渠道），standard APK 签名与内置运行时 SHA-256 校验通过，产物 163055184 字节。在用户 11 中安装最终包、强制结束后冷启动，以及同一认证进程反复进入页面，均得到设备与登录安全字段准备成功。测试后已切回模拟器原用户 0，未删除测试用户或原用户数据。新包不再要求安装天猫校园；真实账号会话仍待用户在新包实测。

## 2026-09-27 三份支付 HAR 与收银台脚本复核

用户补充 `Stream-2026-09-27 15_15_37.har`、`log-api.pangolin-sdk-toutiao-b.com_2026_09_27_15_01_22.har` 和另一份 `微信支付及各种档位.har`，并要求优先追查 `encryptedData`。离线检查只输出接口结构和状态；未复制、重放或记录其中的一次性支付参数。

- 三份 HAR 均能看到收银台入口；新 `Stream` HAR 有两次 `checkout.query`，先返回 `FAIL_SYS_TOKEN_EXOIRED`，再返回 `SUCCESS` 且业务 `status=INIT`。之后有获取微信 OpenID 和 `payment.prepay`，但没有支付后的再次 `checkout.query`，因此仍不能用 HAR 证明支付成功状态或设备启动。
- 抓到的 `checkout.query` 请求正文含 `checkoutId` 和 `encryptedData`。后者 Base64 解码共 32 字节，以 `Salted__` 开头；这只说明封装格式，不能确定明文、密钥、模式或生成方。
- 对两份 HAR 中可核对的七条小程序 MTOP 请求做纯离线比对：`sign` 均等于 `MD5(c 在首个下划线之前的前缀 + "&" + t + "&" + appKey + "&" + 实际 data JSON 字符串)`。这验证的是这些样本的外层签名关系，**不是** `encryptedData` 的加密算法，也不意味着可复用旧 `c` 或旧签名。过期样本中，首次响应给出的新 `c` 与第二次请求的 `c` 完全一致；正文相同，`t/sign` 随重试重新生成。所有比较均在内存完成，未输出令牌和签名。
- 收银台 HTML 引用的公开版本 `campus-settlement-app/1.1.1` 脚本中，`p_cashier-pay-index.js` 发起 `checkout.query` 时只构造 `{checkoutId}`。同版本已核查脚本及动态 `lib-mtop/2.7.2/mtop.js` 中没有 `encryptedData` 字段或该字段的生成实现。抓包请求的 `appKey=32529321` 且 `Referer` 为微信小程序 `servicewechat.com`；这提示密文字段可能由另一层小程序调用路径加入，**不是已从收银台 H5 脚本中定位出密钥**。三份 HAR 本身没有对应小程序脚本资源。
- 收银台脚本把 `INIT`、`PAYING`、`SUCCESS`、`FAIL`、`CLOSE` 列为前端处理的状态，并在用户返回付款页后重新查询；`SUCCESS` 是页面代码识别的状态值，尚无这些 HAR 中支付后服务端实测响应，不应混同为已验证付款结果。
- `order.create.execute` 只在日志上传内容中出现，完整直连请求和回包仍缺失。当前证据不足以在本应用内安全创建订单、发起支付或认定设备已启动。本轮仅更新协议分析，没有改动支付代码或发送网络业务请求。

## 2026-09-27 用户确认付款成功的抓包

用户补充 `Stream-2026-09-27 20:07:07.har`，明确确认这轮微信付款已经成功。离线核对中，同一笔订单的支付前 `checkout.query` 返回 `status=INIT`、金额 50 分；先出现一次 `FAIL_SYS_TOKEN_EXOIRED`，使用响应中的新 `c` 重试后成功。后续 `payment.prepay` 的订单标识和金额均与查询结果一致，渠道为 `WECHAT` / `MINI_PROGRAM`，`prePayTn` 含微信小程序支付所需字段。文档不记录实际订单号、预支付单号或签名。

微信 `SdkReport` 的 Base64 请求体可解出页面事件：`miniAppPay` 在预支付后离开，约 16 秒后重新出现，随后再次离开。它与用户确认的付款时间线吻合，但页面进出事件本身不包含微信付款成功回调或商户到账结果。整份 HAR 在付款返回后没有第二次 `checkout.query`，因此这次**没有观察到**前端从 `INIT` 轮询到支付成功状态。前端可能使用微信本地回调，商户服务器也可能另行收到异步通知；两者在此 HAR 中均不可直接验证。

付款后能看到多批 `campus-2c-app.cn-hangzhou.log.aliyuncs.com/logstores/campus-app/shards/lb` 日志上传，声明 `application/x-protobuf` 和 LZ4，部分请求头给出解压前大小；但本次 HAR 的 11 条日志上传均只有 `postData.mimeType`，没有请求正文 `text` 或参数，不能从大小或上传时刻还原履约、设备启动接口与结果。付款后另有 `guide.delivering.recall.general.data.query`，接口名称和现有返回不能当作启动证据。

当前可确认：用户实际完成这一轮付款，支付前业务状态为 `INIT`，预支付参数与同一订单对应，微信页面发生离开与返回；仍缺商户最终支付状态、完整创建订单请求、设备下发与启动结果。后续若抓设备履约，抓包需保留上述 protobuf 原始请求正文及对应响应，同时避免分享账号和支付一次性凭据。本轮只更新文档，不发起支付或启动请求。


## 2026-09-29 五份新 HAR：恢复 LZ4 日志并接入订单预览

本轮文件为“微信支付及各种档位”“微信支付取消”“订单取消(1)”“查询订单（未成功解密）”“查询订单”。只离线分析，没有重放账号、支付或订单凭据。

重要修正：不能仅根据直连 HTTP 条目判断本批 HAR 缺少创建订单正文。校园日志上传这次保留了 LZ4/protobuf 正文，既有显式 Base64，也有按 Latin-1 字节映射保存的无 encoding 文本。严格解压长度校验和 protobuf 解码后，前三类含日志文件分别提取 29、32、47 条校园业务记录（对应档位、支付取消、未解密查询文件）。新增工具 `tools/audit_laundry_log_har.py`，默认输出结构，绝不输出日志中的手机号、昵称、Cookie、签名、设备/订单标识、授权和支付参数。

已确认的链路：

1. `share.order.render.execute` / `RENDER_ORDER`：请求包含当前设备编号、设备 ID、campusAreaCode、deviceType、modelType、服务项目和空优惠列表；响应 `data.response` 给出 totalAmount、discountAmount、actualPayAmount。金额单位为分。观察到标准洗 400、快速洗 300、大物洗 500、单脱水 100、筒自洁 50；这是样本报价，代码不硬编码档位和价格。
2. 预览的 `campusAreaCode` 与同设备详情的 `campusAreaId` 在样本内相等，不能误用 campusId。档位来自 `deviceWorkingModelDTOS[].priceModelList[]`，服务项目 ID 对应档位 key，attrName 来自所属工作模式。
3. `share.general.uuid.get` 生成业务序列；`share.order.create.execute` / `CREATE_ORDER` 请求包含 isvOrderId、设备信息、预览金额、服务项目等；三份含日志文件各有一条完整创建请求和成功回包。回包位于 `data.orderParamDto`，含 checkoutId、bizOrderId 等；初始 payStatus=TO_PAY、fulfilStatus=WAIT_FULFIL，createFailed=false。不能把创建成功当作付款或设备启动。
4. App 侧 `cashier.checkout.query` 请求使用 checkoutId，没有小程序 `encryptedData` 字段；`cashier.paymethod.query` 还携带 extraAttr 中的 bizOrderId。可继续沿 App 路线研究，不必把解开小程序密文作为订单预览的前置条件。日志中的 wua/rnd/type 属于捕获调用上下文，不能复用；当前 Android native 预览沿用本应用动态 MTOP 签名，服务端兼容性仍待实机验证。
5. “微信支付取消”里同一 checkoutId 可见 INIT 和 PAYING；success=true/resultCode=SUCCESS 仅表示查询成功，不表示已付款。文件内部条目顺序不作为实际时间顺序，不能据此宣称状态按特定方向转移。
6. “订单取消(1)”的 22 个条目没有可用的校园取消 API 请求或校园日志正文；两份查询文件也未给出运行中洗衣订单、设备剩余时间。不能从文件名推导取消协议，不能由程序标称时长启动假倒计时。

本轮实现：扫码后各档位增加“预览应付金额”。点击后在独立校园进程重新读设备与当前价格，确认档位仍开放、设备可用且属于已验证的固定时长洗衣机，再调用只读预览。校验返回设备与服务项目，严格验证整数分金额、优惠不超过总额和应付金额一致性，显示服务端原价/优惠/应付。没有接入创建、支付、取消或启动按钮，避免产生无法完成支付或取消的真实订单。设备编号只在本应用内存/非导出 Activity 参数流转，不写日志或持久化。

验证：Python 离线日志/协议测试、Java 金额测试以及 Android debug 构建；本机当前无连接的 Android 设备，未执行真实账号的预览验收，也未执行 `LaundryOrderProtocolTest` 的 Android JSON 测试入口（该源码供设备侧后续执行）。下一步先让用户实测报价接口，再补齐付款返回后的服务端最终状态、明确取消请求和运行订单明细。


## 2026-09-29：订单核验与运行倒计时测试入口

新文件“订单25.har”和“订单.har”包含完整日志正文。已离线确认同一运行订单的 payStatus=SUCCEED、fulfilStatus=FULFILLING、urgentOrderType=RUNNING_ORDER，并取得 remainSeconds=119/112/100/96。另有历史已完成订单 COMPLETED 和关闭订单 CLOSED。收银台业务 status=SUCCESS 也已观察到。这补充了前文缺少支付成功、运行秒数和完成订单样本的限制；不是同一订单完整生命周期的连续抓包。

Android debug 新增“运行订单与付款核验”入口，沿用独立校园进程和现有会话。查询 urgent list 后逐笔查询详情、匹配订单标识，再显示付款状态及运行秒数；历史列表最多查询第一页 10 条。页面每 15 秒刷新、每秒按单调时钟显示预计剩余时间，后台不再发起轮询（在途请求可能结束）。倒计时归零仍等待服务端完成状态，不能推断设备结束；失败保留上次结果并标记，失效清除页面数据并提示重新登录。无真实订单、凭据落盘或日志输出。

本轮没有接入创建订单、微信拉起或付款按钮，没有重放 HAR 凭据，没有实际扣款或启动设备。接口兼容性仍需用户在测试 APK 内以当前本人会话验证。纯 Java 状态规则和倒计时边界 9 项测试通过；Android debug 构建用于编译和打包验证，不能替代真机业务验证。


## 2026-09-30：Android debug 付款入口

用户确认上一版运行订单与付款核验测试通过，并授权加入付款功能。本轮增加实时报价确认、创建订单、微信小程序跳转、返回查询及未完成付款恢复入口。没有使用真实账号进行下单或付款测试。

协议依据：新订单 HAR 的 OUT_UUID_SEQUENCE_GET / ORDER_CREATE_OUT_ID_SEQUENCE、CREATE_ORDER；创建前重新查询设备与报价，金额变化中止并要求重新确认。创建参数的服务项目及优惠来自服务端 render 响应。支付方式由 cashier.paymethod.query 动态读取，仅接入 USING/WECHAT/REDIRECT_PAY/SCHEME 且 extraAttr 为空的已验证结构。

本地已下载的公开收银台 p_cashier-pay-index.js 的 nH/nJ 函数提供微信 business scheme、公开小程序 appid 和 miniAppPay 页面路径，参数两层 URL 编码。该页面变量 bizOrderId 在 paymethod 请求中实际对应 checkoutId，已用 HAR 值在内存比对确认；不能误传洗衣 bizOrderId。这里只构造当前新订单的跳转参数，不重放旧预支付签名，不接商家开放平台，不自动支付。Android 微信对该跳转的兼容性仍需真机验证。

campus-payment.enc 使用现有 Keystore 加密及 noBackup 目录，独立于登录文件，保存账号绑定、业务序列、应付金额和可恢复结算标识。提交前先保存意图，同一进程加锁且已有意图时拒绝再次创建；请求异常不会在应用层重试创建。结算标识未取得时从最近 10 笔订单按业务序列恢复，查不到时保留待核验状态。不得因查不到或网络错误擅自清除并重新下单。另一账号不能接续此付款。只有服务端确认 SUCCESS 或 CLOSE 后，用户点击确认结果才清除记录。

创建及收银台响应均验证订单标识和金额；SUCCESS 为支付成功，INIT 可再次打开微信，PAYING 等待核验，其余状态不宣称付款成功。支付成功不等于设备启动成功，用户可进入运行订单页进一步查看。恢复旧订单时显示对应设备与位置。

验证：17 项纯 Java/JSON 支付契约测试通过（模拟数据，包括金额/标识不匹配、渠道不支持、编码与创建参数），androidApp:assembleDebug 成功，standard debug APK 签名验证成功。JSON 测试运行库仅下载到忽略的 build 目录，没有新增应用依赖。无实际扣款、启动设备、提交或推送。需要用户完成一次微信拉起及支付后回到测试版的实机验证。


## 2026-09-30：内置组件裁剪（真机复测待完成）

用户确认付款测试通过后要求移除内嵌完整天猫校园 APK。新增 tools/build_tmall_slim_runtime.py：对原 APK 的 9 个 dex 拆解、从 InnerSignImpl/MtopConfig/TBSdkLog/InnerNetworkConverter 和安全/设备组件入口计算类引用闭包，包含常量反射类名。73,242 类保留 14,235 类；这是保守依赖闭包，不承诺运行时最小集合。WriteSelectedDex 按原 dex 分组保留方法指令，避免单 dex 引用数溢出。移除原 App 广告、地图等资产及其他原生库，归档中保留资源表、yw 安全资源和公开 META-INF 证书材料；裁剪归档不等于原 APK 的有效签名包。

四个 libsg 原生库仍仅打包一份。prepare_tmall_login_debug.py 现在必须显式传入 --runtime 精简归档，不再复制整包；首次需要 --har，后续可保留已有公开配置。BundledCampusRuntime 在新组件初始化及 riskData 成功后清除同目录旧 hash.apk 缓存，避免更新安装后继续占用完整原包空间。

实测文件大小：组件归档 121,385,708 → 8,171,446 字节；最终 standard debug APK 52,329,250 字节（约 52.3 MB / 49.9 MiB），相对约 163.8 MB 减少约 68%。增量打包曾保留 ZIP 空洞，已通过重命名备份两个渠道的 package 增量目录及旧输出后重新打包解决，没有删除原始天猫 APK。

验证：assembleDebug、standard APK 签名、28 项 Python 测试成功。新的无 INTERNET 权限组件诊断支持登录 WUA 与动态签名检查，但当前雷电模拟器的 slimprobe、slimprobe37 和完整归档 fullprobe 均在 libhoudini ARM 转译层发生 SIGSEGV，均未生成完成报告。因此不能宣称精简后的登录/签名运行验证通过；必须由真机覆盖安装复测登录、订单查询及付款。源码中无真实账户、设备或支付凭据。

复现：工具依赖 baksmali/smali/dexlib2/util 2.5.2、guava 27.1-android、jcommander 1.64、antlr/antlr-runtime 3.5.2、stringtemplate 3.2.1，仅存 build/campus-slim-tools，不引入 App 依赖。先运行 build_tmall_slim_runtime.py --apk <原始APK>，再使用 prepare_tmall_login_debug.py --apk <原始APK> --runtime build/campus-slim/campus-runtime-slim.apk。原始 APK 必须保留在生成资产目录之外；缓存输入不同会拒绝复用。动态构造反射名称、JNI 依赖仍可能超出静态闭包，真机发现缺类时需补充保留规则，不应伪称已无遗漏。

## 2026-09-30：洗衣 Compose 界面与付款状态整合

本轮仅改造 Android debug 洗衣模块；宿舍用水和课表主界面保持原有行为。工作区已有修改继续保留，没有提交、推送或构建 Release。

共享层新增不依赖 Koin 的类型化洗衣状态与 Compose 页面，通过状态和回调显示首页、程序选择、付款、订单与登录容器，不读取 JSON、网络或凭据。沿用现有主题、字体、Material 3 与深色模式；主题增加显式 NightMode 重载，独立校园进程不访问主进程主题存储。Android debug 的 CampusLaundryActivity 通过显式 ViewModel Factory 管理导航与 StateFlow，串行调用现有 CampusClient，替代原生设备、预览、订单 Activity。登录仍使用授权 WebView、原回调验证及会话转换；扫码仍使用 ZXing 和既有二维码校验，返回设备编号。未改签名算法、请求协议、加密文件格式或付款恢复搜索范围。

左上角扫码入口带一次性扫码意图：无有效校园会话只显示登录，验证成功后打开相机；取消相机回到洗衣首页，取消登录退出到原入口。个人页洗衣服务进入首页。首页右上角查看订单；无运行订单显示扫码按钮，运行订单各自显示设备、程序及服务端剩余时间。程序页采用两列主题色选择卡片，默认选择服务端标准洗或首项，底部固定显示实时报价与付款按钮；可展开原价、优惠明细，移除无实际业务功能的广告与协议元素。

报价采用串行请求与版本校验，旧请求不覆盖新选择；加载、失败或金额变化时不能付款。确认弹窗保留金额、程序和关门提醒。已有付款意图优先核验或恢复，创建结果不明确时不自动重复创建。微信返回不作为付款成功证据；仅收银台 SUCCESS 回到首页，INIT 可继续付款，PAYING 与未知结果保留核验入口。用户点击“知道了”后仍由原客户端再次核验终态才清除加密付款记录。已付款但设备未运行显示等待状态；提前确认提示也保留短暂的界面等待状态，随后以 urgent list 或最近 10 笔订单的服务端结果替换，服务端已付款待履约订单可在重启后继续显示。

倒计时使用单调时钟，每 15 秒在前台同步；后台停止轮询，已发请求可能完成。无有效 remainSeconds 仅显示运行状态，归零显示“等待完成确认”，完成订单退出运行区域，查询失败保留上次结果并标记待更新。会话失效清除页面中的账号资料并重新登录；不同账号的付款意图继续阻止新建订单，并提供原账号登录入口。

登录中间页反馈：用户曾在模拟器停留于淘宝到校园的图标页。本轮补充 WebView 全尺寸布局、viewport、页面网络/安全连接错误处理、重新加载入口与无交互页面超时提示。用户随后纠正反馈并明确确认新版“西瓜课表-测试版”在模拟器登录成功。没有凭此判定原中间页的具体根因，也没有放宽 HTTPS 或回调校验。临时离线界面预览包使用独立包名和“洗衣界面预览”名称，不带网络权限；其入口、假数据和构建配置均位于忽略的 build 目录，不进入最终 APK。

验证状态：共享层状态测试与 Android ViewModel 测试覆盖一次性扫码、相机取消、报价版本、重复提交、创建不明确、微信返回、重启恢复、账号不匹配、会话失效、多笔运行订单、倒计时归零及提前确认后的设备等待。金额、订单报价、付款契约、订单状态与 Python 离线协议测试继续回归。执行 composeApp:testAndroidHostTest、androidApp:testStandardDebugUnitTest、androidApp:assembleDebug；浅色、深色、窄屏及 1.5 倍字体的程序卡片与固定支付栏已使用离线假数据检查。APK 签名及正式 debug 包名检查通过。

最终结果：上述 Gradle 任务成功，共享层 56 项、Android 状态 14 项测试无失败；Java 金额/报价/付款/状态共 66 项断言及 Python 28 项测试通过。standard debug APK 为 53,080,294 字节，内置精简运行时仍为 8,171,446 字节；包名 vip.mystery0.xhu.timetable.debug，版本 1.6.7.d896.3dcb5f51。离线预览 Activity 未打入最终 APK。

真机验收仍待用户操作：新 UI 下的相机取消、选择程序、微信跳转、真实支付后返回首页与服务端倒计时，以及覆盖安装后的加密付款记录恢复。本轮没有真实下单、扣款、启动洗衣机或代替用户输入短信验证码。模拟器登录成功、离线界面与自动化测试不替代上述真机业务验收。

## 2026-09-30：洗衣界面密度与订单层次调整

用户反馈程序卡片、确认付款弹窗过大，订单分区及运行订单缺少层次。本轮只调整共享 Compose 页面布局与文案，付款、报价、恢复及倒计时逻辑保持现状。

- 程序页压缩设备信息和间距，标准洗（没有则首项）为横向卡片，其余程序两列排列；价格与说明使用更紧凑的字号，保留主题色选中边框与勾选。底部金额和支付按钮在常规字号下同排，大字体或窄屏回退为上下排列。
- 确认支付使用紧凑弹窗，独立显示程序和实际应付金额，保留放好衣物、关好机门及可能立即运行的提醒；按钮简化为返回和确认支付。
- 订单页以标题、数量及说明区分待处理和最近订单，空状态独立呈现；历史订单合并为带分隔线的列表，用状态标签区分已完成与已关闭。运行订单使用图标、位置、程序和计时区域，倒计时改为分:秒显示；待更新、无秒数、等待运行及归零仍显示相应提示，不推断新的业务状态。

离线模拟数据验证：模拟器常规字号下五个程序与固定支付栏同时可见，UI 节点核对五个程序名称均在屏幕中。已查看浅色、深色、1.5 倍字号及滚动后的最后一行程序、确认弹窗、进行中卡片、无待处理订单及 10 笔历史记录的截图；预览没有调用真实网络或付款接口。composeApp:testAndroidHostTest（56 项）、androidApp:testStandardDebugUnitTest（14 项）及 androidApp:assembleDebug 成功，APK 签名和正常 debug 包名校验通过，临时预览 Activity 未进入最终包。当前 standard debug APK 为 52,427,498 字节。本轮保留原有工作区修改，没有提交、推送或发布 Release。

## 2026-09-30：洗衣模块请求与初始化优化

用户确认体积可以接受，本轮优先改善洗衣模块速度。界面、宿舍用水和课表业务保持现有行为；精简校园运行时、签名算法、支付协议、加密文件及付款恢复搜索范围保持现状。

- 校园独立进程共用一个 CampusClient 和串行执行线程，复用组件初始化及反射方法。每次入口仍重读加密会话，账号或 sid 变化时清除内存报价和设备映射；登录授权和风控字段仍动态生成。
- 登录完成的本人资料与订单核验可在同一会话、30 秒内向宿主交接一次，不通过 Intent 传递凭据。初次订单刷新复用核验阶段的 urgent list，继续实时查询每笔详情；保留原单调时钟采样时间，渲染时即扣除已经过去的时间。手动刷新、前台同步、微信返回使用新的服务端数据。
- 设备编号到设备 ID 使用会话绑定、最多 16 条的内存 LRU。缓存命中仍实时查询设备详情与报价；服务端拒绝或设备标识不符时丢弃映射并恢复原有查找流程。网络失败直接提示重试，不扩大搜索。设备可用状态、价格和付款结果不缓存。
- 用户连续切换程序采用 150 毫秒防抖，首次报价立即请求。旧请求仍受到选择版本和串行通道约束；报价等待及失败时不能支付，下单前仍实时复核金额。重复刷新合并为当前请求及至多一次后续请求，微信返回要求后续新查询。倒计时独立更新，慢网络请求不会阻塞计时；后台停止轮询。
- debug 仅打包 arm64-v8a；release 保留原有 armeabi-v7a 和 arm64-v8a 配置，本轮没有构建 Release。新增 CampusPerf 日志只记录固定阶段、耗时与省去的请求数量，不记录账户、二维码、请求内容或付款参数。

验证：composeApp:testAndroidHostTest（56 项）、androidApp:testStandardDebugUnitTest（24 项）及 androidApp:assembleDebug 成功。新增测试覆盖交接过期和一次性消费、会话变化与 LRU 淘汰、连续选择只请求最后一项、报价等待时禁止付款、重复刷新与微信返回追加实时核验、原始采样时间以及慢查询期间持续计时和归零。原有 Java 金额/报价/付款/状态 66 项断言、Python 离线协议 28 项测试通过。四个 arm64 安全原生库及 8,171,446 字节的校园运行时与上一版逐字节一致。

模拟器覆盖安装保留原会话；实测扫码入口、相机取消返回首页、再次进入扫码入口均正常。CampusPerf 记录同一版本首次初始化 707 毫秒、同一校园进程再次初始化 6 毫秒；这是一次冷/热初始化采样，不是优化前后整页耗时或真机性能比例。实测普通入口只发出资料和 urgent list 两次核验请求，首页复用了 urgent list；无未完成付款时，相比原入口少一次列表请求。登录完成后交接最多省去另外两次重复核验，交接规则已离线测试，本轮没有重新输入短信验证码。

测试与性能记录保存在忽略的 build/laundry-performance 目录。真实设备查找缓存收益、微信跳转及付款后倒计时、真机冷启动耗时仍需用户实测；本轮没有实际创建订单、扣款、启动洗衣机、提交或推送。

最终 standard debug APK 为 51,222,323 字节（51.22 MB / 48.85 MiB），上一版为 52,427,498 字节，减少 1,205,175 字节。重新打包前只备份生成的 package 增量目录和旧 APK，避免 ZIP 空洞影响测量。APK 签名、ZIP CRC、arm64 ABI 校验通过，最终包已覆盖安装到模拟器；既有工作区修改继续保留。

## 2026-09-30：iOS 洗衣迁移准备（业务接入尚未完成）

用户要求 iOS 与 Android 功能和界面一致，并说明只能使用 GitHub Actions 构建。本机为 Windows，没有执行 Xcode、iOS 模拟器或真机验证；没有提交、推送或触发 Actions。

已将 Android 洗衣 ViewModel 的业务状态迁入 commonMain 的 LaundryViewModel，JSON 转换留在 CampusTypedLaundryGateway，Android 原 Factory、独立进程、安全组件、金额与付款协议继续使用。新 LaundryGateway 接口只提供类型化且经过平台客户端核验的数据。两端复用同一套登录后一次扫码、程序报价版本、防抖、付款恢复、终态确认、订单分区与单调时钟倒计时行为，而不是为 iOS 复制一套业务规则。二维码校验也迁入共享策略，Android 的 ZXing 识别结果和 iOS 页面宿主均调用同一策略。

iOS 新增页面宿主及 IosLaundryRuntime 注册边界，使用现有 Material 3 页面和生命周期前后台轮询规则；原生登录、扫码、微信页面由 IosLaundryPresenter 提供，打开微信的返回结果仍只触发服务端查询。使用 systemUptime 毫秒作为订单采样时钟。新增独立的 Keychain 会话与付款意图存储边界、AVFoundation 相机页面和相机权限说明。相机页面只识别二维码，不直接打开识别网址。原生相机实现、页面生命周期与 Keychain 均尚待 iOS 编译和设备验证。

重要缺口：仓库尚无真实 IosLaundryGateway 和完整 IosLaundryPresenter 实现，没有调用 IosLaundryRuntime.install。当前 iOS 业务入口仅在真实客户端安装后启用，直接进入未接入路由时说明组件未接入；没有使用假会话、假报价或假支付让界面看起来可用。新增宿主、接口和安全存储不能当作登录、扫码、下单及支付已经打通。iOS 采用应用内平台客户端，不能照搬 Android 的 :campus_login 进程模型。

用户提供天猫校园 iOS 5.7.2 IPA。tools/audit_campus_ios_ipa.py 仅检查 ZIP 目录和 Mach-O 头，不解密或运行 App。其 bundle ID 为 com.tmall.campus4iphone，arm64 主程序 filetype 为 MH_EXECUTE，LC_ENCRYPTION_INFO_64 的 cryptid=1，声明保护区为 144,408,576 字节。目录包含两份 yw_ 安全资源，但未发现独立 MTOP 或校园安全 framework。此结果只确认主程序声明加密及可独立链接组件缺失，不推断私有代码的完整组成；应用可执行文件不等同于 SDK。用户说明没有另一份已解密 IPA 或独立 SDK。

进一步核对了[淘宝官方 SDK 下载页面](https://developer.alibaba.com/docs/doc.htm?articleId=106383&docType=1&treeId=129)，其公开 iOS 百川旗舰版 5.0.0.18 下载包已保存到忽略的 build/laundry-ios-ipa/public-sdk.zip。下载包为 112,805,709 字节，SHA-256 为 e5291469e34c8c1caf3949f2972320a63c7e03fcf5ce3d1bceca374ac0872a3e，含 MtopSDK、mtopcoreopen、mtopext、SecurityGuardSDK、SGMain、SGMiddleTier、SGSecurityBody 等 framework 与头文件。该包未加入应用、未升级项目依赖、未初始化 SDK 或外发校园请求；有公开 SDK 不等于已验证天猫校园的二方签名、会话转换及安全资源兼容。下一步须先验证可链接性、当前 bundle 环境的安全字段及新请求协议，不能直接把 Android 成功判据套用给 iOS。

现有 build_ios_personal.yml 增加 composeApp:iosSimulatorArm64Test 和测试报告 artifact 上传，继续沿用无签名个人测试 IPA 流程，没有改为发布或 App Store 上传。只有源码提交到 GitHub 后才可运行该构建；不能把本地 YAML 语法检查称为 Actions 成功。上传成功的 unsigned IPA 还需要用户已有的签名安装方式。

本地验证：composeApp:testAndroidHostTest 共 66 项、androidApp:testStandardDebugUnitTest 共 24 项及 androidApp:assembleDebug 成功，原 Android 业务回归未失败；新增共享测试涵盖一次性扫码与取消、报价等待、创建不明确、微信返回、终态再次核验、多订单及采样时间，二维码测试涵盖来源、嵌套与长度校验。Python 工具测试共 34 项通过，Info.plist 和 Actions YAML 语法解析通过。iOS 原生编译、SDK 兼容、真实登录、扫码与支付仍未验证。

### 用户授权后的首次 Actions 验证

用户随后明确授权提交、推送并运行个人测试 Actions。原 personal remote 地址不可访问，确认 personal-private 中 feature/water-service 仍指向本地基线 3dcb5f5 后，提交 6957b3b 并推送到该已有私有仓库；没有推送上游，没有加入 IPA、公开 SDK 下载包、凭据或构建产物。

[iOS 个人测试运行 36685124236](https://github.com/zhishouzhiqian/XhuTimetable-private/actions/runs/36685124236) 已触发，但任务在运行器启动前失败，steps 为空，没有构建日志或 IPA。GitHub 的失败注释指出账户付款或支出限额限制；另有 macOS arm64 排队容量通知。Android 个人测试也未启动运行器。此结果不能算作源码编译失败，也不能算作 iOS 编译成功。未修改账户付费设置、未反复重跑；需用户在 Billing & plans 恢复 Actions 使用条件后继续验证。iOS 校园 SDK 签名及真实客户端接入仍未完成。

### Codemagic 构建配置

用户选择改用已经登记的 Codemagic。新增根目录 codemagic.yaml，使用 mac_mini_m2、JDK 21 和 Xcode 26.2，沿用共享 iOS 测试及无签名个人测试 IPA；缓存依赖并保存测试与 Xcode 日志，仅手动触发。官方 schema、YAML 与脚本语法检查通过。浏览器控制连接失败，尚未确认 Codemagic 仓库导入、private_maven 加密变量配置或构建结果；账户侧步骤见 [Codemagic 个人测试构建说明](codemagic-ios-personal.md)。GitHub secret 不能读回迁移，须用户提供给 Codemagic 原始值。iOS 原生编译及真实校园客户端仍待验证。

用户随后在 Codemagic 应用级 private_maven 组保存 GITHUB_USERNAME 与 NEXUS_PASSWORD，脚本兼容映射且不显示值。选择 feature/water-service 后成功识别 YAML。首次云端测试编译失败于原有 iosMain 和 iosSimulatorArm64Main 重复声明 isDebug；将设备实现移到 iosArm64Main 后，第二次 [构建 6abcd8ac083ff0a9a53aa753](https://codemagic.io/app/6abcc2cd6c98472e80a8cc91/build/6abcd8ac083ff0a9a53aa753) 的共享 iOS 测试执行通过、Xcode 设备构建成功、未签名 IPA 打包及 ZIP 校验通过。本地 composeApp:compileAndroidMain 通过。iOS 真实登录、SDK 签名兼容、设备扫码、微信与付款恢复仍未实测，平台客户端仍未接通；编译成功不等同于真实洗衣功能完成。
