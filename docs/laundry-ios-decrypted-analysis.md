# iOS 洗衣破壳 IPA 核对（2026-10-01）

## 范围与样本

用户提供天猫校园 5.7.2 破壳 IPA，SHA-256 为 `b6d5ca8dac4b328f6a416e0e69be5b7b58b43fa7fa41919fad897bda8904f76a`，大小 179,286,250 字节，Bundle ID 为 `com.tmall.campus4iphone`。主程序是 arm64 `MH_EXECUTE`，加密标志 `cryptid=0`。这与早期调查中的加密样本不同；本轮可以读取其实现，但没有运行官方 App。

本轮仅核对公开 SDK 版本、Objective-C 入口、初始化参数和 MTOP 字段组装；不解密安全图片、不提取密钥、不输出 AppKey、账号、签名或会话。IPA、候选 SDK、反汇编与本地报告保存在忽略的 `build/`，不随源码或 CI 上传。

## 已确认的差异

### SDK 版本

主程序 `OpenSecurityGuardManager.getSDKVersion`（`0x10507f828`）和 `SecurityGuardManager.getSDKVersion`（`0x105089dd4`）的公开版本常量均为 `6.8.260603`。这里只还原版本字符串，不处理安全资源或密钥。

既有真机报告中的公开候选 SDK 版本是 `5.6.231002`。截至本轮核对，[官方 SDK 下载页](https://developer.alibaba.com/docs/doc.htm?articleId=106383&docType=1&treeId=129) 仍列出百川 iOS 旗舰版 `5.0.0.18`，与项目固定 SHA-256 的候选包相同；没有由这份页面找到校园主程序所用的 6.8 组件下载。产品 SDK 版本与 SecurityGuard 内部版本不能混为一谈。

版本不同是已确认事实，尚不能据此证明 `2404` 的原因、资源格式不兼容或不同 Bundle ID 下必定不可用。没有自动替换候选 SDK，也没有把主 App 可执行文件当作 framework 加入课表。

### AppKey 与初始化入口

校园入口的只读调用链：

```text
TCSyncLauncher.setupMTOP (0x1002ac348)
  → AppInfo.appKey (0x100d6dc80)
  → TBSecretMgr.getAppKeyWithIos (0x1059196a4)
  → TBSecretMgr.getAppKeyWithIndex: (0x10591b314)
  → SecurityGuardManager.getInstance
  → getStaticDataStoreComp
  → getAppKey:
```

`TBSecretMgr.sharedInstance`（`0x10591b81c`）初始设置 `environmentID=0`。这解释了校园读取的索引来源，不表示 Open 入口的同一索引一定能读取相同配置。

现有检查使用 `OpenSecurityGuardManager.getInstance:withCustomBundlePath:error:` 与 `getAppKey:authCode:`，不能直接把其空值等同于校园内部入口失败。候选包中可找到内部管理器的类标记，但本轮只报告类是否链接，没有额外初始化该管理器：官方内部入口只有无参数 `getInstance`，没有已核验的自定义资源路径入口。

统一签名由 `TBSDKSecurity.UnifiedTier`（`0x104bc8628`）取得 `ISecurityGuardOpenUnifiedSecurity` 接口。主程序 `SecurityGuardOpenUnifiedSecurity.init:error:`（`0x104ff9ce4`）明确读取 `authCode`、`flag` 和 `customBundelPath`。其中 `Bundel` 是厂商实现的原始拼写；已有路径修正得到当前样本的再次确认。

官方 MTOP 调用者向初始化字典放入 `auth_code`，实现读取的是 `authCode`；本轮保留候选 SDK 头文件与实现核对后的 `authCode`，不为了逐字复制调用者而改成另一个拼写。未证明官方该值在实际运行时会被其他代码转换。

### iOS MTOP 签名输入

`TBSDkSignUtility.getSecurityFactors:...withInstanceId:`（`0x104bcaa34`）将正文序列化后取 UTF-8 MD5，按以下顺序用 `&` 连接。可选字段缺失时保留空字段，不预先 URL 编码：

| 位置 | 来源 |
| --- | --- |
| 1–4 | UTDID、`x-uid`、`x-reqbiz-ext`、AppKey |
| 5–8 | 正文 MD5 小写十六进制、`x-t`、API、版本 |
| 9–11 | `x-sid`、`x-ttid`、`x-devid` |
| 12–13 | `x-location` 按逗号分割后的第二项、第一项；不是两项时均为空 |
| 14–17 | `x-extdata`、`x-features`、`x-router-id`、`x-place-id` |
| 18–22 | `x-open-biz`、`x-mini-appkey`、`x-req-appkey`、`x-act`、`x-open-biz-data` |

`TBSDKSecurity.factorSign:input:extendParas:isUseWua:api:requestId:`（`0x104bc8ccc`）把组装结果作为 `data`，并传入 `appkey`、`env`、`api`、`extendParas`、`useWua`、`requestId`。这是传给统一签名组件的输入结构，不是对签名算法或服务端权限的复现。

## 本轮代码调整

- `CampusMtopProbeInput.h` 组装上述离线输入，使用同一份正文 UTF-8 字节的 MD5；拒绝毫秒时间、时间类型错误和可选字段类型错误。
- 组件检查的两次调用使用新生成的无账号诊断标识、秒级时间、设备注册 API 的字段形状及当次请求编号。没有发送设备注册请求，也没有取得真实设备 ID。
- 报告增加 SDK 版本对照、校园内部 AppKey 入口与 Open 入口的差异说明。
- 只有 `x-sign`、`x-mini-wua`、`x-umt`、`x-sgext` 均为非空字符串且 SDK 未返回错误，才判定本地字段齐全。残缺字典、错误伴随的字段不进入有效签名比较；输入变化但签名相同会单独提示。
- macOS 原生桩测试由 4 个流程场景扩展为 7 个，并补充字段顺序、独立 MD5 夹具、空字段、时间、location、类型和脱敏断言。
- 新增 `audit_campus_ios_signing.py`，只导出白名单类及方法的实现地址；支持绝对、相对和直接 selector 方法列表，拒绝加密样本、越界指针和异常列表。

复核元数据的命令：

```shell
python tools/audit_campus_ios_signing.py --ipa <本地破壳IPA> --output build/laundry-ios-analysis/signing-entry-points.json
```

## 验证与下一步

本轮实际执行的 Python 测试共 18 项通过：新增元数据核对 7 项、既有 IPA 审计 6 项、候选资源准备 5 项。新工具已对用户提供的 IPA 执行成功。Windows 受限令牌与 Python 3.14 临时目录 ACL 冲突时，测试以普通权限执行，夹具限定在工作区 `build/`。

初次提交 `da96324` 已同步到 `feature/water-service`。用户手动启动轻量构建后，macOS 原生测试程序编译成功，执行停在“不完整签名”场景，尚未进入 iPhone 编译或生成 IPA。`CC_MD5` 的弃用警告不是本次退出原因；MD5 用于匹配既有 MTOP 正文摘要契约，不能直接替换成 SHA-256。

失败断言先将报告数组转成 `rows.description`，再匹配中文。Foundation 集合的调试表示可能转义 Unicode，不能当作原始报告正文使用。修复直接按 `step` 读取 `result`，对两次生成结果和比较结果分别作精确断言；脱敏检查也直接拼接原始字段。没有放宽安全字段完整性判断，也没有跳过失败场景。修复后的 7 个原生场景及 iPhone 编译仍待用户重新运行轻量工作流；组件初始化、签名生成与服务端仍待真机验证。

下一阶段先用修正版轻量包确认 `customBundelPath` 后的初始化结果、版本和字段完整性。如果仍返回 `2404`，继续比较 Open / 内部入口与 5.6 / 6.8 的资源加载分支，不能反复填写 AppKey 或直接跳到付款。可用签名还须经过规范新请求的服务端只读核验，随后才接入授权码转换、本人资料、订单查询及真实 `IosLaundryLoginGateway`。当前 iOS 洗衣业务入口仍显示未开放。

## afdf401 真机结果与默认认证参数核对

用户提供检查修订 `afdf401`、版本 60 的完整报告：资源 Bundle 可识别，两个文件可查找、可读取且完整性一致；三个插件已链接；SDK 初始化成功，版本仍为 `5.6.231002`。内部管理器类未找到，Open 静态配置组件可获取但索引 0 的 AppKey 为空；统一签名接口可获取，显式传入 `customBundelPath` 后初始化仍返回 `2404`。没有执行安全字段、签名或服务端设备注册。由此只能排除“统一签名路径参数遗漏是唯一原因”，不能证明厂商底层已正确加载或接受资源。

继续核对校园主程序发现，`SecurityGuardStaticDataStore.getAppKey:`（`0x104ef2254`）实际委托给 `OpenSecurityGuardManager.getInstance`、`getInterface:` 和 `getAppKey:authCode:`，最后的 authCode 参数为 `nil`。因此内部类未链接本身也不能直接解释 Open 入口空值，内部入口不能简单视为完全独立的密钥实现。

固定校验的公开候选 SDK 中，`OpenSecurityGuardManager.getInstance` 的 LLVM bitcode 向双参数入口传入两个空指针，默认 authCode 为 `nil`；静态配置和统一初始化包装则把收到的 authCode 转为 UTF-8 指针传给底层。未提供值产生空指针，显式 `@""` 产生非空的零长度字符串指针。这确认了调用输入差异，但尚未证明底层是否归一化它们，也未证明该差异导致 `2404`。

下一版诊断采用厂商默认值：管理器、静态配置和登录安全字段传 `nil`，统一初始化及离线签名字典省略可选 `authCode`；仍保留已校验资源路径。报告明确标出认证参数模式，原生桩测试检查所有入口使用同一默认模式。没有更换 SDK、绕过资源校验、补入认证码或密钥、请求登录或订单。原生编译、修正版初始化及签名结果仍待云端与真机验证；如果默认模式仍失败，不能将其描述为已解决版本或资源兼容问题。

## b8a9642 真机复核：默认认证参数未解决初始化失败

用户提供检查修订 `b8a9642`、版本 59 的完整报告，确认默认 authCode 模式已执行。资源、插件、管理器与接口的结果与 `afdf401` 一致：SDK `5.6.231002`，AppKey 索引 0 为空，统一初始化仍报 `2404`，签名及服务端注册未执行。两次报告的版本号受构建提交历史影响，应以修订编号区分，不能因版本 59 小于 60 就认定安装了旧代码。

两项有静态依据的修正（补充自定义路径、采用默认 authCode）在真机均未使当前候选组件可用，不再以重复构建或填写 AppKey 作为解决初始化失败的下一步。报告与界面提示已改为明确：手工 AppKey 只能在统一初始化成功后辅助核对，不能修复初始化失败。

继续检查候选 MiddleTier 的 LLVM 控制流，`CMi02Tqa0lTIP5` 在底层桥接返回无结果或有效长度不足时将错误值 `4` 映射为 `2404`。现有包装层未提供该值的官方语义；不能把它直接称为文件缺失、Bundle ID 不匹配或版本不兼容。应用层文件可读也不证明底层安全组件已加载并接受其内容。

当前可用的官方百川下载页仍提供 [iOS 旗舰版 5.0.0.18](https://developer.alibaba.com/docs/doc.htm?articleId=106383&docType=1&treeId=129)，本轮未找到校园 `6.8.260603` 的可链接发行包。[官方 iOS 安全组件集成说明](https://developer.alibaba.com/docs/doc.htm?articleId=105603&docType=1&treeId=243) 将 framework 与安全资源作为独立集成材料；这不证明校园必须申请新的资源，也不能把完整 `MH_EXECUTE` 主程序直接作为 framework 链接。

后续进度取决于能验证 SDK 资源加载失败原因的证据，或能在本应用环境读取配置并初始化统一签名的可链接 iOS 组件。优先核对厂商组件发行版本、插件组合及资源加载契约；取得新的可验证材料后再设计一次具有区分能力的检查。当前没有兼容组件、可用新签名或真实校园网关，不开放 iOS 登录、订单创建和付款。本轮只有报告提示与文档调整，不要求用户再次构建；原生改动留待下一次有实际组件变更时一并编译验证。

## 继续定位：获取 AppKey 失败时被遗漏的数字错误

进一步核对校园主程序：内部 `SecurityGuardStaticDataStore.getAppKey:` 最终委托 Open 管理器与 `getAppKey:authCode:`，认证参数为 nil。因此，检查宿主没有内部管理器类本身不足以解释失败。候选 SGMain 的初始化包装也会归一化空认证参数；真机结果与此相符。项目的 `tmall-campus-sms-protocol.md` 已记录普通 H5 登录无法完成校园 App 会话转换，不能将 H5 重定向当作已验证替代方案。

候选 SGMain 的 `getAppKey:authCode:` 在底层失败后计算 `原始错误 + 200`，通过 `NSLog` 输出 `SG ERROR: %d\n`。其原始错误 2 的分支追加固定诊断：应用 Bundle ID 与 SecurityGuardSDK 的 yw_1222 图片不匹配。因此 **该候选版本的 SG ERROR 202** 有静态代码依据；这不是对 MiddleTier 2404 的解释，也不是已在用户设备观察到 202。分析仅还原这些 SDK 日志格式常量，未解密导入的安全图片。

轻量构建新增独立宏 `CAMPUS_COMPONENT_CAPTURE_SDK_ERRORS`：宿主观察静态库的 NSLog 调用，继续通过 Foundation 的 NSLogv 输出原有日志；只在当前线程同步读取 AppKey 的期间解析严格的数字错误格式，报告仅保留数字，不保存或展示日志正文。结束或抛出异常都关闭观察，其他线程、前后调用和格式不符的日志不作为诊断依据。完整课表构建不启用此宏。未捕获日志不代表 SDK 成功；异步日志或其他日志通道也可能无法观察。

增加原生桩场景验证 202、203、错误格式、其他线程、前次结果清空与报告脱敏。Windows 无 Foundation/Xcode，尚不能执行这些原生测试；`ios-component-check` 在编译 IPA 前执行全部 10 个场景。下一次真机报告重点是“AppKey 底层错误”：若为 202，应取得匹配本应用身份的授权资源与兼容 SDK，不能靠手填 AppKey 或改路径修复绑定；其他数字需继续对照对应分支。此次是补足有区分能力的诊断，并非已经修复 2404 或打通 iOS 洗衣。

## 23cee65 真机复核：AppKey 返回 204（2026-10-02）

用户报告检查版本 57、修订 `23cee65`：两个导入文件保持完整，SDK 仍为 `5.6.231002`，AppKey 日志明确为 `SG ERROR: 204`，统一初始化仍为 `2404`。新的日志观察器已在真机捕获数字错误。这不是 202，不能据此要求修改应用 Bundle ID；也不是索引不存在对应的 209。

[阿里官方安全错误码表](https://jaq-doc.alibaba.com/docs/doc.htm?articleId=104308&docType=1&treeId=129) 定义 204 为 `SEC_ERROR_STA_STORE_INCORRECT_DATA_FILE`，即安全图片格式不正确；常见原因包括二方/三方资源混用或 SDK 与图片版本不配套。该表更新于 2017 年，列举的具体版本是历史示例，不能机械套用为当前 5.6/6.8 的兼容矩阵。结合真机完整性检查，当前应优先验证候选 SDK 与校园资源的格式兼容性，而非反复修改 authCode、手填 AppKey 或重复导入相同文件。完整性校验只证明导入未改变文件，不证明 SDK 实际选中的资源或原始文件必然有效。

已核对静态包装层中 AppKey 的原始错误 4 加 200 得到 204，MiddleTier 的资源获取失败分支将原始错误 4 映射为 2404。二者与共同的资源处理问题相符，但仍不足以证明两条调用在底层使用同一文件、同一错误来源或确定具体不兼容类别。

可执行的解决方向是取得与校园安全资源相兼容的可链接 iOS SDK/插件组合，或取得与候选 SDK、应用身份及目标校园业务相配套的授权资源。随意申请普通百川资源不保证可调用校园接口；单纯换成版本号较新的公开 SDK 也不保证兼容。现有 IPA 中相关实现静态链接在完整主程序内，尚无已验证的独立 framework 可直接替换；此前已核对的公开下载包仍是失败的候选组合。当前尚未取得替代组件，不能宣称已修复或要求用户重复构建验证。

检查报告新增 204 的准确解释，新增第 11 个原生桩场景；原生测试留待下一次具有实际组件变更的 macOS 构建执行，本机 Windows 无法运行。仅此报告与文档修订无需再次打包。iOS 登录、订单及付款仍未开放。

## 资源路径与组件来源复核（2026-10-02）

继续核对已固定 SHA-256 的候选 SDK bitcode，`SecurityGuardOpenInitialize.privateInitialize:withCustomBundlePath:` 的实际目录分支如下：

1. 通过 `bundleForClass:` 取得初始化组件所在 Bundle；仅当其路径以 `.xctest` 结尾时使用该 Bundle 目录。字符串来自 `CMa02zrMMdolgt` 指向的 `CMa02Uj8cpN7hS`，按函数中的常量恢复得到 `.xctest`。不是 `.framework` 或 `.bundle`。
2. 不属于测试 Bundle 时，非空的 `withCustomBundlePath:` 参数直接进入路径选择结果；参数为 nil 才退回主应用 Bundle 目录。
3. 所选路径转成 UTF-8，作为 `__sbuf` 写入 `InitializeParameterContext` 第 2 号字段，传入原生命令 `10501`。这说明当前宿主的普通应用路径分支会向原生层传递导入目录，而非包装层无条件改用主 Bundle。

以上是静态控制流证据，不等于观察到了真机最终打开的资源文件；底层的文件选择、缓存或其他 I/O 行为仍没有运行时路径记录。此前报告中的“显式使用导入目录”只能证明调用参数，不能扩大为文件访问已验证。进一步动态验证应观察成功打开的目标资源文件及其摘要，并与导入文件比较，不能仅打印传入路径或用目录存在代替。

同时复核资源准备与导入：Python 只接受 IPA 的 `Payload/<主应用>.app/` 根目录下唯一同名资源，按原始字节 Base64 编码；Swift 解码后使用 `Data.write` 原样写入，未经过 UIImage、JPEG 编码或图像压缩；manifest 与文件摘要用于验证导入后完整性。因此当前没有“导入时图片转码”或“仅凭 basename 误选嵌套资源”的代码证据。

再次访问[官方 SDK 下载页](https://jaq-doc.alibaba.com/docs/doc.htm?articleId=106383&docType=1&treeId=129)，页面标注更新于 2026/04/08，iOS 旗舰版仍列出 `5.0.0.18`（即目前已测试的发行包）。本轮对校园 `6.8.260603` 及 iOS 安全组件的公开检索未找到可核验的对应发行包；检索无结果不代表该组件不存在。其他阿里产品的同名 framework 不构成校园兼容性证明，不据此替换项目依赖。

下一步所需材料：可合法用于本项目及校园业务的 iOS 安全 SDK 发行包，至少包含 SecurityGuardSDK、SGMain、SGMiddleTier、SGSecurityBody 的配套版本、头文件及 arm64 库，并说明配套资源、authCode 和应用身份要求。交付的资源应能服务于校园目标业务，不能以普通百川示例资源代替。拿到材料后先进行离线包完整性/架构/协议检查，再测试读取 AppKey、统一初始化和完整的新签名，最后才做服务端只读验证。当前尚未获得该材料；本轮没有 SDK 替换或已验证修复，不要求重新构建。
