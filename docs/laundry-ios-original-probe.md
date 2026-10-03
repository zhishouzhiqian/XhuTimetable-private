# 校园原配本地诊断

本实验使用用户已有的校园 5.7.2 破壳 IPA 中的原 SDK 和原资源，不依赖下载独立配套 SDK。用户已在 LiveContainer 中验证 6.8.260603 初始化成功，诊断版本 2 两次签名均具备四个必需字段，改变正文后 x-sign 不同。尚未将签名能力接入课表。诊断版本 3 增加手动匿名配置联网检查。

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

### 诊断版本 3 的联网检查

启动不会自动发送诊断请求。离线按钮仍要求断网。要执行新的联网阶段，请连接网络，手动点击“联网检查（仅匿名配置）”；每个进程只创建一个检查任务，不能在同一进程重试。不要以飞行模式下的网络错误判断签名失败。

联网阶段先重新核对资源及初始化。版本 5 使用原 MTOP 的 TBSDKNetworkSDKUtil.utdid，并对照 UTDevice.utdid；不使用随机标识或 uniqueGlobalDeviceIdentifier。请求 AppKey 来自原 AppInfo.appKey，报告仅比较其与索引 0 是否相同。TTID 按原 TCSyncLauncher.setupMTOP 的形式，以 AppInfo.channel、bundleName、version 组装 `%@@%@_iPhone_%@`。原主程序 TBSDKRequest.setHTTPRequestHeader 使用 x-pv=6.3；编码由原 TBSDKMTOPEnvConfig.urlEncodeString: 执行，并用合成特殊字符向量及逐项解码一致性验证。

只允许 HTTPS GET 到 acs.m.taobao.com 的 mtop.tmall.campus.guide.advertising.config.list/1.0，正文固定为 `{}`。秒级时间、UTDID、TTID、AppKey 和正文在签名前固定，签名使用同一份输入；新生成的四个安全字段检查完整后只编码一次。不使用 Cookie、x-sid、x-devid、账号、旧抓包签名或历史注册值。此精简请求尚未完成服务端验收，不能称为已经验证的完整 iOS MTOP 客户端。

请求使用 ephemeral NSURLSession，关闭 Cookie、凭据存储和缓存，拒绝跳转，保持系统 TLS 校验。请求/资源超时为 15/20 秒，响应最大 1 MiB。没有应用层重试或后续请求；系统传输层的连接处理由 NSURLSession 管理，不能据此保证底层只有一次连接尝试。原程序加载期代码和第三方运行时修改仍不在诊断控制范围内。

报告仅展示 HTTP 状态、白名单业务码、固定错误说明及数字错误码，不展示 URL、头值、设备标识、响应正文或响应数据。只有 HTTP 200 且非空 ret 列表全部为 SUCCESS 才通过；未知业务码统一显示 UNKNOWN_CODE。不跟随验证码/风控跳转，不继续设备注册、短信、登录、订单或付款。设备注册应在匿名查询成功后单独验证。

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
