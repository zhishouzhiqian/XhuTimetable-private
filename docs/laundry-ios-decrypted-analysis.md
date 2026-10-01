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
