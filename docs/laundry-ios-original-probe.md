# 校园原配本地诊断

本实验使用用户已有的校园 5.7.2 破壳 IPA 中的原 SDK 和原资源，不依赖下载独立配套 SDK。用户已在 LiveContainer 中验证 6.8.260603 初始化成功，诊断版本 2 两次签名均具备四个必需字段，改变正文后 x-sign 不同。版本 5 用户报告匿名配置查询 HTTP 200 / SUCCESS，原 UTDID、编码和请求一致性预检全部通过。尚未将签名能力接入课表。版本 6 扩展为设备注册与返回 ID 复用的综合检查；版本 7 修正外层请求 API getter，已获得用户三段联网成功报告；版本 8 的本人登录及资料已通过真机验收；版本 9 的运行及历史订单已通过真机验收；当前版本 10 增加订单详情、机器编号直查与精确错误分类。

## 用户需要构建的部分

- 分支：fix/ios-campus-sdk-init。
- Codemagic 工作流：ios-campus-original-probe。
- 中文名称：iOS 校园原配本地诊断库（未签名）。
- 下载产物：CampusOriginalProbe.dylib。

该工作流不上传或下载原 IPA，不下载 5.6 SDK，不运行 Gradle，只执行 Python 补丁测试、macOS 原生桩测试并编译 arm64 iOS 诊断库。无自动构建触发。

## 本地制作

下载诊断库后，在工作副本根目录执行以下命令，按实际下载位置填写参数；本机路径只出现在命令示例，不写入源码。

```powershell
python tools/prepare_campus_original_probe.py --ipa '天猫校园_5.7.2.ipa' --dylib 'CampusOriginalProbe.dylib' --output 'build/ios-original-probe/CampusOriginalProbe-unsigned.ipa'
```

输出文件必须不存在；工具拒绝覆盖。源主程序必须与已检查的 5.7.2 样本 SHA-256 相同，拒绝给其它版本套用地址补丁。资源保留字节不变，生成清单供真机核对。工具检查诊断库是未加密 arm64 MH_DYLIB，并具备已定义的导出启动入口。

Windows 可完成打包；iOS 诊断库需要 macOS/Xcode 编译。若只拿到源码还没有 dylib，暂不能制作可运行的诊断 IPA。不要用伪造 dylib 或测试 fixture 制作安装包。

## 签名与真机运行

1. 用既有签名工具递归重签诊断副本，包括新增的 dylib 和原包内组件。保留原 Bundle ID；诊断要求 iOS 16 及以上。
2. 诊断副本与原校园 Bundle ID 相同，安装会与原校园冲突，可能替换其安装。只在可替换的测试安装上进行；本工具不签名、不安装。
3. 开启飞行模式并关闭 Wi-Fi，再打开“校园原配诊断”。必须看到专用诊断页面；若出现原校园首页，则不是正确的诊断启动链路，停止操作。
4. 点击“开始本地检查”，复制报告。不要登录、扫码或付款；诊断页没有这些操作入口。
5. 每个新进程只运行一次。超过 45 秒未返回，保留当前报告并彻底关闭应用；超时提示不代表 SDK 线程已被取消。

### 当前版本 10 的基础联网检查

启动不会自动发送诊断请求。离线按钮仍要求断网。联网阶段连接网络，手动点击“联网综合检查（配置/注册/复用）”，依次检查匿名配置、设备注册与返回 ID 复用，最多三个任务，每个进程只执行一次综合检查。独立 WUA/UMID 结果同时保留。不要以飞行模式下的网络错误判断签名失败；综合阶段超过 90 秒会显示超时提示，SDK 调用不会因此自动取消。

联网阶段先重新核对资源及初始化。版本 5 使用原 MTOP 的 TBSDKNetworkSDKUtil.utdid，并对照 UTDevice.utdid；不使用随机标识或 uniqueGlobalDeviceIdentifier。请求 AppKey 来自原 AppInfo.appKey，报告仅比较其与索引 0 是否相同。TTID 按原 TCSyncLauncher.setupMTOP 的形式，以 AppInfo.channel、bundleName、version 组装 `%@@%@_iPhone_%@`。原主程序 TBSDKRequest.setHTTPRequestHeader 使用 x-pv=6.3；编码由原 TBSDKMTOPEnvConfig.urlEncodeString: 执行，并用合成特殊字符向量及逐项解码一致性验证。

只允许 HTTPS GET 到 acs.m.taobao.com 的匿名配置接口和 mtop.sys.newdeviceid/4.0。配置正文固定 `{}`；注册正文按下文十个原 iOS 字段组装。秒级时间、UTDID、TTID、AppKey 和正文在每次签名前固定，新生成的四个安全字段检查完整后只编码一次。只有第三阶段使用本次返回的 x-devid；不用 Cookie、x-sid、账号、旧抓包签名或历史注册值。版本 5 的匿名配置已有服务端成功报告，注册与复用仍待验证，不能称为完整 iOS MTOP 客户端。

请求使用 ephemeral NSURLSession，关闭 Cookie、凭据存储和缓存，拒绝跳转，保持系统 TLS 校验。请求/资源超时为 15/20 秒，响应最大 1 MiB。没有应用层重试或后续请求；系统传输层的连接处理由 NSURLSession 管理，不能据此保证底层只有一次连接尝试。原程序加载期代码和第三方运行时修改仍不在诊断控制范围内。

报告仅展示 HTTP 状态、白名单业务码、固定错误说明及数字错误码，不展示 URL、头值、设备标识、响应正文或响应数据。只有 HTTP 200 且非空 ret 列表全部为 SUCCESS 才通过；未知业务码统一显示 UNKNOWN_CODE。注册还必须获得有效 data.device_id 才能复用。不跟随验证码/风控跳转，不发送短信、不登录、不下单或付款。

## 启动改动与边界

工具不改 LC_MAIN、不迁移 SDK。它仅改已确认边界内的原 main 函数：调用原程序已有的 dlopen/dlsym stub，加载本地诊断库，进入导出的 CampusOriginalProbeMain。92 字节启动代码与 67 字节字符串共占 159 字节，完整放入原函数的 164 字节范围，不再占用头部空白区。

旧诊断包将字符串放在加载命令末尾。LiveContainer 导入时会插入 LC_ID_DYLIB、TweakLoader 加载命令与 RPath，可能覆盖这些字符串；见 [LiveContainer 加载命令补丁实现](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/LCMachOUtils.m)。v2 包改为上述函数内存放，并用模拟插入命令的回归测试验证字符串与启动代码不变。此修复解决已确认的覆盖风险；没有真机崩溃日志时不能据此认定唯一闪退原因。

两个加载失败分支均返回 78；不会回到原校园 main。诊断入口调用 UIKit UIApplicationMain，使用默认 UIApplication 和专用 AppDelegate。诊断入口不实例化原 TCApplication/TCAppDelegate，不调用其正常业务启动流程；更早的类加载行为仍不受控制。清除副本中的主 storyboard、主 nib 和 scene 配置，防止加载原 UI。

原二进制和依赖库仍由 dyld 加载，其构造器和 Objective-C 类加载代码可能执行；这部分不受诊断页控制。因此必须断网，不能宣称完全阻断所有第三方后台活动。参照 [Apple UIApplicationMain 文档](https://developer.apple.com/documentation/uikit/uiapplicationmain(_:_:_:_:)-1yub7?language=objc)核对专用 Application/Delegate 创建方式。

SDK 检查先执行内部 SecurityGuardManager 默认入口、静态存储包装器 getAppKey:（索引 0），再取得 Open 管理器和 ISecurityGuardOpenUnifiedSecurity，执行 init:error:。初始化字典为空，保留原默认认证参数、资源入口和 flag，不改校验或签名返回。

初始化成功且 AppKey 非空后，核对 getSecurityFactors:error: 的参数和返回类型，再执行两次离线调用。复用已核对的 CampusMtopProbeInput.h 组装 iOS MTOP 22 字段，使用秒级时间、同一正文的 MD5 与本次生成的随机临时标识。第二次只改变正文中的 probe_nonce 和 requestId，其余签名串字段相同。该输入用于本地对照，临时标识未注册，正文不是业务请求，不发送到服务端。

两次结果分别检查 x-sign、x-mini-wua、x-umt、x-sgext 均为非空字符串且没有 NSError；非空但不完整的字典、错误伴随完整字典或类型不符均不能判为成功。只有两次完整返回才比较 x-sign 是否随输入变化。不展示 AppKey、临时标识、输入串或返回字段值。

报告只包含版本、资源长度/一致性、步骤结果和 NSError 数字码；不包含 AppKey、签名、路径、设备标识、异常正文或 SDK 日志。本诊断不劫持 NSLog，AppKey 空值时不声称捕获了底层 204。

## 如何判读

- AppKey 非空且统一签名初始化成功：原组件在本次测试安装环境可完成本地初始化；用户已提供此成功报告，公开 5.6 组件在课表检查中的失败仍未修复。
- 两次必需字段完整且 x-sign 不同：仅证明本次环境能生成完整安全字段并随输入变化；服务端接受性、设备注册、登录与洗衣业务仍未验证。
- 匿名配置查询 HTTP 200 / SUCCESS：证明本次新配置请求获得正常业务响应；不能推断所有安全字段的服务端校验强度，不能判定设备已注册或登录已完成。
- AppKey 为空或统一签名失败：保留具体阶段与错误码，进一步核对安装环境和初始化依赖；不能仅归因于公开 5.6 与原 6.8 的版本差异。
- 类/方法类型不匹配：诊断拒绝调用，不能伪造成功；需核对实际安装的样本和签名后的二进制。
- 无法启动：先检查新增 dylib 递归签名、系统版本和签名工具对原包依赖的处理。没有报告时不能推断 SDK 初始化结果。

## 已完成与未验证

本地 Python 回归验证补丁范围、源样本固定校验、头部保持不变、模拟容器插入加载命令、函数边界、加载符号、ARM64 失败跳转、输出保护、资源和 Bundle ID 保留。原样本指令离线反汇编确认，启动代码为 92 字节，原函数边界为 164 字节。

macOS 原生桩测试覆盖默认索引/认证参数、空初始化字典、AppKey 空仍继续初始化、初始化失败不调用签名、22 字段输入与两次正文摘要变化、完整签名、部分字典、错误伴随完整字典、非字符串字段及非字典返回、数值错误保留、报告脱敏以及缺资源/缺清单阻断。它们不会执行真实 SDK。

版本 1/2 的原配初始化及签名生成已获得用户真机成功报告。版本 3 的 dylib 需要用户在同一工作流重新构建，再制作 IPA；不能用旧 dylib 验证新增联网检查。Windows 未运行本次 Xcode 原生编译及桩测试，尚未发送本次诊断的真实网络请求。

新增 macOS 桩测试在内存中核对原设备/应用入口、空正文 MD5、iOS TTID 与请求字段一致、编码向量、双重编码阻断、缺字段阻断、设备/时间格式以及发送范围拒绝。响应测试覆盖 SUCCESS、签名错误、混合业务码、未知码、非字符串、HTTP 失败、断网、跳转、超限和无效 JSON，验证不泄露正文。测试发送入口只接收必须在建连前拒绝的请求，测试不访问服务端；真实 NSURLSession 成功链路仍需设备运行验证。

版本 3 首次原生测试在 URL 断言失败：NSURL.path 会去掉路径末尾斜杠，导致测试和发送校验都误拒绝合法请求。现使用 NSURLComponents.percentEncodedPath 和 percentEncodedQuery 构造并校验线路形状，保留末尾斜杠，不改变签名正文或放宽接口白名单；参见 [Apple NSURL.path](https://developer.apple.com/documentation/foundation/nsurl/path)。原生回归增加合法候选通过范围检查、完整 URL 不变、缺末尾斜杠/额外路径、双重编码、额外查询参数、重复 data 和改变正文的拒绝测试。本机没有 Xcode，修正后的原生测试仍需工作流验证。

用户随后运行版本 3：原配初始化和 AppInfo AppKey 对照均成功，但请求构造返回空值，报告“编码或协议核对失败；未发送”。这不能判断为服务端签名拒绝，也尚不能唯一定位具体失败条件。

版本 4 将拒绝原因细分为 AppKey、UTDID、TTID、时间、安全字段形状、编码向量、具体头字段编码、正文编码和最终线路范围；只输出固定原因及白名单字段名，不输出值。旧编码向量逐字比较会误拒绝 `%7E` 与 `~` 等合法等价表示，现改为保留字符转义及解码完全一致的语义检查，仍阻断漏编码、非法转义和重复编码，不更换 SDK 编码方法。保留 UTDID 24 字符/18 字节约束，没有将随机 UUID 当作原设备标识。原生测试增加等价转义、按原二进制参数执行 CFURL 编码及拒绝原因脱敏；版本 4 编译和真机结果待验证，尚未证实用户本次失败正是向量表示差异造成。

版本 4 用户报告明确返回 UTDID_FORMAT，仍未发送请求。因此本次失败不能归因于服务端或编码向量；向量修正不是已证实的此次根因修复。

重新核对固定样本后发现版本 3/4 选错设备入口：TBSDKMTOPEnvConfig.readUtdid（0x104bc0430）调用 TBSDKNetworkSDKUtil.utdid；该包装器（0x104bc21a0）查找 UTDevice 并调用 utdid。此前 UTDIDMain.uniqueGlobalDeviceIdentifier（0x105aa63a8）使用不同的唯一标识生成路径及 uniqueID 回退，不能当作 MTOP UTDID 使用。这是诊断实现错误，不是 SDK 初始化失败或 LiveContainer 已被证明不支持设备标识。

版本 5 改用上述原调用链，并批量报告字符/解码长度、两次读取稳定性、包装器与 UTDevice 一致性、五组编码向量、九个请求头回读及空正文一致性。长度可展示，设备值不展示；格式、不稳定或入口不一致仍阻断，不使用旧 HAR 或随机值替代。单个头字段预检失败时其它独立编码检查仍继续，最终构造门禁保持严格。此版本仍只发送手动匿名配置查询；尚未完成设备注册、设备 ID 复用或洗衣接入，不将独立标识生成等同于服务端注册成功。

原生桩新增不同形状的旧入口、正确 MTOP 包装器与 UTDevice、无效格式、两次读取变化、双入口不一致以及 15 项编码预检回归，断言旧入口零调用，设备预检失败不签名；Windows 打包测试不执行这些原生桩，版本 5 原生编译和真机联网结果待验证。


## 版本 6：注册、返回 ID 复用与本地凭据综合检查

版本 5 已获用户真机报告：原 6.8 SDK 初始化、AppKey 对照、原 MTOP UTDID 24 字符/18 字节契约、两次读取与 UTDevice 对照、五个编码向量、九个请求头和空正文全部通过，匿名配置响应 HTTP 200 / SUCCESS。此结果证明本次匿名请求成功，不证明登录、设备注册或洗衣功能完成。

版本 6 手动联网按钮最多执行三个串行 NSURLSession 任务：匿名配置基线 → mtop.sys.newDeviceId/4.0 设备注册 → 使用本次返回 data.device_id 重新签名的匿名配置。前一步失败就跳过依赖任务，不重试、不跟随跳转、不使用 Cookie、账号或登录会话。设备注册确实会请求服务端创建/返回标识；设备 ID 只保留在本次闭包内存，不写入原 SDK 状态，不宣称产生了新的物理设备。

注册字段来自固定原 iOS 样本 getDeviceIDFromServer:：device_global_id、c0=apple、c1=UIDevice.tbsdkPlatform、c2=原 UTDID、c3=0987654321、c4=UIDevice.tbsdkMacaddress、c5=CPUID、c6=SDCARDID、new_id_rule=true、new_device=true；均为字符串。UIDevice(TBNewSDKIdentifierAddition) 的类方法元数据与外部绑定已核对。不复制 Android 的 bizId，也不使用随机 UUID 替代原设备入口。

MtopExtRequest 的初始化实现会调用 lowercaseString；运行时使用原 initWithApiName:apiVersion: 和外层 getApiName/getApiVersion 核对实际名称（版本 7 修正，版本 6 曾误用 apiName），再取原返回值用于签名；网关路径固定小写。正文只序列化一次，同一份 UTF-8 字节参与 MD5 和 URL 编码，发送前再核对回读正文。复用时同一返回 ID 同时进入签名串第 11 字段与编码后的 x-devid 请求头，重新生成时间和四个安全字段。每阶段重新读取原 UTDID，变化就停止。

返回 ID 仅接受非空、最多 256 字符的有界安全字母表字符串，展示长度而不展示值。Android 样本的 44 字符长度不是已经验证的 iOS 契约，因此不以其作为必须长度。HTTP 200 和 SUCCESS 与 data.device_id 有效必须同时满足，才能进入复用阶段。

独立本地检查读取 Open 管理器 getUMIDComp/getSecurityToken，不调用 UMID 初始化或注册；仅比较是否与本次 x-umt 相同。完整 WUA 使用 Open 安全体组件 getSecurityBodyDataEx:appKey:authCode:extendParam:flag:env:error:，核对对象参数、两个 int 参数与 NSError 指针类型，使用毫秒时间、原 AppKey、authCode=nil、extendParam=nil、flag=4、env=0。它只是登录用途的候选生成检查，不等同于原登录流程参数已核对或服务器已接受；只比较是否与 x-mini-wua 不同，不输出凭据。WUA/UMID 错误不阻断其余独立网络检查。

新增原生桩检查注册字段、API 规范化、同一线路正文的 MD5、返回 ID 在签名与头中的一致性、跨阶段 UTDID 变化、越界/额外查询/错误方法/账号 Cookie 拒绝、返回 ID JSON 解析、WUA int ABI 与默认参数、错误码脱敏，以及 UMID 异常时继续 WUA。发送测试只使用建连前必须拒绝的请求，测试不访问服务端。

版本 6 仍需用户在 ios-campus-original-probe 工作流构建新的 CampusOriginalProbe.dylib。Windows 只运行 Python 打包回归和 Bash 语法检查，没有运行 Xcode 原生编译或这些原生桩；真实设备注册与 ID 复用结果待新 IPA 的真机报告。旧版本文段中的联网边界对应当时的版本，当前界面以版本 6 的三个任务说明为准。


## 版本 7：修正注册 API getter

用户版本 6 真机报告确认：原配 SDK 初始化成功、匿名配置 HTTP 200 / SUCCESS、UMID getter 返回非空且与本次 x-umt 相同、候选完整 WUA 返回非空且与 x-mini-wua 不同。最后停在“注册 API 原入口：原名称不符合已核对 API；未发送”，没有注册或复用的服务器响应。

根因是诊断实现混淆了外层与内部请求对象：MtopExtRequest 的读取方法是 getApiName（0x104b88d94）和 getApiVersion；getApiName 内部读取 mrequest，再调用内部 TBSDKRequest.apiName。版本 6 对外层调用 apiName，类型检查失败导致读到 nil，却输出了笼统名称错误。此前桩也错误提供 apiName，掩盖了问题。它不是 SDK 初始化失败，也不是服务端拒绝注册。

版本 7 改用外层 getApiName/getApiVersion，分别报告方法类型、空值/类型、名称和版本问题；名称仅接受已核对注册 API，版本只接受 4.0，再使用原对象返回值签名。没有直接硬编码一个签名名称来跳过对照。桩只提供真实外层 getter，明确断言外层不响应 apiName，并增加错误名称、空值、非字符串和错误版本四类签名前阻断测试，保留整个版本 6 综合检查。

同时离线重新核对固定原样本的 16 个相关类/实例方法及参数编码，包括两个注册 getter、原请求初始化、Open 管理器的组件入口、UMID、安全体 int ABI、设备入口、编码入口和 AppInfo 参数入口。Windows 的 8 项 Python 打包回归与 Bash 语法检查通过；新增原生桩和真机注册/复用仍由下一次构建与报告验证。版本 6 的 WUA 结果只是本地候选生成成功，不能代替登录接口验收。


## 版本 8：沿用 Android 业务流程，适配 iOS 登录与只读验收

版本 7 用户真机报告确认：匿名配置、mtop.sys.newdeviceid/4.0 注册、带返回设备 ID 的重新签名配置均 HTTP 200 / SUCCESS；data.device_id 为 44 字符。原配 SDK 初始化、UMID 对照、候选完整 WUA 本地生成也通过。这证明原程序诊断环境下的上述能力，不证明独立课表进程已取得配套 SDK 或真实登录会话。

业务顺序复用现有 Android CampusClient：官方 H5 新授权码 → snslogin → 本人资料 → 洗衣运行订单。iOS 适配使用原程序的 ALBBOAuthLoginInfo、ALBBRiskControlInfo 与 ALBBJSON.objectToJsonString:，没有复制 Android 的 sdkVersion、appVersion、设备品牌/型号或 Android 风控 ABI。原 ALBBAccountOAuthLoginHandler 的 snsLoginInfo/riskControlInfo 为外层 JSON 字符串，ALBBNewMtopInvoker 调用 useHttpPost；ALBBRPCInfo.site 是 NSString，useAcitonType/useDeviceToken 是 NSNumber 对象 setter。相关方法名称、参数编码与调用流程已在固定原样本离线核对。

页面先执行原有三个联网综合任务，全部通过才启用“本人登录及洗衣只读检查”。点击后在独立 WKWebsiteDataStore.nonPersistentDataStore 中打开官方授权页，由用户手动发送短信、输入验证码、选择本人账号和完成必要验证。诊断不读取网页输入或正文，不调用独立短信接口。授权策略沿用已有 LaundryAuthorizationPolicy：仅官方 HTTPS 域、禁止外部应用跳转，只消费主页面 www.alipay.com/webviewbridge 中唯一 action=taobao_auth_token 和唯一合格 top_auth_code。网页授权请求数量由用户操作及官方页面决定，不包含在三个原生任务的上限中。

取得授权码后最多三个新的串行 POST：mtop.taobao.mloginservice.snslogin/1.0、mtop.tmall.campus.member.app.user.get/1.0、mtop.tmall.campus.share.applet.general.user.urgent.order.list/1.0。原 iOS 登录 API 在 ALBB 包装层使用 mtop.taobao.mloginService.snsLogin，诊断固定网关与签名名均小写，与原 MTOP 规范化一致。当前资料请求使用 platForm=ios，此平台字段的服务端接受性仍待真机验收；订单查询沿用 Android 已核对的 USER_URGENT_ORDER_LIST 与 CAMPUS/WASH_AND_CARE 只读结构。

登录模型使用原 AppInfo AppKey、原 UTDID、iOS TTID、本次返回设备 ID、新授权码、site 字符串 96、原模型的应用和登录 SDK 版本。清除模型的 hid、deviceTokenKey/deviceTokenSign 与 ext，避免旧账号上下文进入新请求；不初始化完整 TCAccountCenter，不调用自动登录或登出。若原模型缺 SDK 版本，只通过 ALBBSecurityStorageImpl.getSdkVersion 取得原 SDK 自身的固定版本（该原样本实现为直接返回常量），不冒用 SecurityGuard 的版本或 Android SDK 版本。本次重新生成 WUA/UMID，风险模型通过原 addDeviceInfo 添加 iOS 信息，WUA 的数据使用毫秒时间并覆盖原模型同一 t。

每个 POST 的 JSON 只冻结一次，正文 UTF-8 的 MD5 进入原 iOS 22 字段签名，发送表单 data 使用同一字符串；时间、设备 ID、四个安全字段重新生成并核对。登录请求不带旧 x-sid/x-uid 或 Cookie，后两项只使用本次成功登录响应的 returnValue.sid/hid，同时进入新签名串和请求头。目的地、API/版本、方法、表单正文、精确头白名单、无 Cookie、无跳转和请求时间均在发送前再次检查，没有应用层自动重试。

HTTP 200 / SUCCESS 仍只是第一层：登录须有非空 sid/hid（hid 为数值时仅接受整数文本，拒绝布尔值），资料须有身份字段，运行订单须明确 fail=false 且 urgentOrderListResponse 为数组，才能分别判定该阶段通过。正常空数组可以验收，业务失败或缺字段不能显示“暂无订单”。报告只展示固定步骤、HTTP/白名单业务码、必要数值错误、订单数量和是否通过，不展示手机号、授权码、sid/hid、Cookie、订单内容、请求地址或安全字段。登录与查询完成后不持久化会话，也不写原 SDK 的账号状态。

回调只消费一次，取消、错误与迟到回调不能重复交换同一授权码；每进程只执行一次本人登录检查。离线/综合网络检查仍保持原有行为。此版本没有接入课表客户端、设备启动、订单创建、支付或取消订单。运行订单查询若因 UCC/Cookie 或其它会话协议差异失败，会保留实际阶段结果，不用网页返回或空页面替代验收。

新增 macOS 原生桩覆盖官方授权域及欺骗域、主页面/子框架、重复回调参数、授权码形状、原模型对象 setter、旧账号字段清除、嵌套 JSON 字符串、注册设备 ID 对照、POST 冻结正文与 MD5、sid/hid 在签名中的位置、登录与只读头隔离、发送前越界拒绝、有效会话解析、资料脱敏、正常空运行列表和业务失败阻断。发送测试只使用必须在建连前拒绝的请求，不访问服务器、不发送短信。Windows 未运行本次 Xcode 原生编译、WKWebView 或真实登录网络验收，仍需用户构建并操作新诊断包。


## 诊断版本 9：本人会话后的整批洗衣只读验收

版本 8 真机已验证本次新授权码的 snslogin 会话交换及本人资料均为 HTTP 200 / SUCCESS，sid/hid 和资料身份字段通过。运行订单为 HTTP/业务码通过，但当前结构校验未通过；不能据此声称洗衣查询通过，也不能视为正常空订单。

版本 9 对齐 Android JSONObject.optBoolean 的字符串 true/false 兼容规则。它同时保持缺字段、null、未知值和明确业务失败为失败；不通过放宽为“所有 SUCCESS 都为空订单”。失败报告新增固定字段的类型诊断，区分 fail 是布尔、字符串、缺失，以及内层对象和数组是否存在，不输出任意键名或业务值。真实原因需版本 9 报告确认，字符串 false 目前只是代码差异支持的假设。

本人登录按钮后最多七个串行网络任务：会话交换、本人资料、运行订单、历史订单第一页（10 条）、本人关联楼栋、常用设备第一页（20 条）、列表中首个合法设备的详情与开放程序。没有合法列表设备时正常跳过详情。所有接口、requestType 和 JSON 字符串封装沿用 Android CampusClient 现有只读流程，每阶段重新生成 iOS 原签名；设备详情禁用自动领券。首台设备详情必须与列表中的 resNo/deviceId 一致才能验收。

运行订单或其它单项只读结构失败后继续其它独立只读项，报告逐项通过/失败；“本批结束”不代表全项成功。每请求限时仍为 20 秒，七项综合等待提示为 180 秒。只取第一页，不遍历整个楼栋或设备库，不创建订单、不付款、不启动机器。报告展示记录数、可用状态和开放程序数量，不展示位置、设备标识、订单内容或价格。会话仅本次内存使用；未提供重启恢复，未把原组件独立移植进课表应用。

构建继续使用 fix/ios-campus-sdk-init 分支的 ios-campus-original-probe 工作流。本地 Windows 可检查打包工具测试及 Bash 语法，macOS 原生桩编译和 iOS 链接需构建验证；真机各项只读结果尚待用户验收。


## 诊断版本 10：订单详情及机器编号直查

用户版本 9 真机报告已确认：初始化、签名、匿名查询、设备注册、返回 ID 复用、新授权码 snslogin、本人资料、运行订单（0 条）及历史订单（10 条）通过。楼栋和常用设备返回 HTTP 200 / UNKNOWN_CODE，详情因没有合法列表设备而跳过；不能认为其已通过，也尚未确认具体错误原因。

固定错误码白名单补入当前原二进制实际含有的 FAIL_SYS_API_NOT_FOUNDED、接口未授权、HTTP 方法/参数/协议错误等名称，只报告已核对的固定错误名称，:: 后内容及未知名称仍不展示。两个列表与 Android 使用相同 API、版本和 POST 封装；不能仅凭 UNKNOWN_CODE 断言 iOS 缺乏接口授权。

新版最多八次串行任务：会话交换、资料、运行订单、历史订单、首个有效本人列表订单详情、楼栋、常用设备、设备详情。订单详情只用本次列表返回的三个有界身份字段，不猜测 ID；服务端 bizOrderId 必须和选中列表订单一致，并检查支付/履约字段完整性。没有有效订单时跳过详情。

在“本人登录及洗衣综合只读检查”之前可选填实际机器编号（1–128 位字母、数字、下划线或横线，不填整条二维码链接）。该编号只保留本次内存，优先用于 DEVICE_INFO_GET 查询，允许省略 deviceId，与 Android 原有直查入口一致；因此楼栋和常用列表失败不会阻断手填机器直查。未填写时仍使用本次合法常用设备列表来源。详情返回的机器编号必须与查询来源一致；存在来源 deviceId 时同时核对该 ID。needAutoSendCoupon=false，未创建、支付或启动订单。未持久化本人会话、未接入课表运行组件。

本地仅能执行 Python 打包测试、脚本语法和源码结构检查；新增原生请求与响应测试需用户的 macOS 构建运行。综合等待提示 210 秒，每请求 20 秒仍不变。各项结果待新 IPA 真机验收。
