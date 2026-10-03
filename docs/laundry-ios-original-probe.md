# 校园原配本地诊断

本实验使用用户已有的校园 5.7.2 破壳 IPA 中的原 SDK 和原资源，不依赖下载独立配套 SDK。诊断版本 1 已在用户的 LiveContainer 环境成功读取 AppKey，并完成 6.8.260603 统一签名初始化；尚未将签名能力接入课表。诊断版本 2 增加两次离线签名生成检查。

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
- AppKey 为空或统一签名失败：保留具体阶段与错误码，进一步核对安装环境和初始化依赖；不能仅归因于公开 5.6 与原 6.8 的版本差异。
- 类/方法类型不匹配：诊断拒绝调用，不能伪造成功；需核对实际安装的样本和签名后的二进制。
- 无法启动：先检查新增 dylib 递归签名、系统版本和签名工具对原包依赖的处理。没有报告时不能推断 SDK 初始化结果。

## 已完成与未验证

本地 Python 回归验证补丁范围、源样本固定校验、头部保持不变、模拟容器插入加载命令、函数边界、加载符号、ARM64 失败跳转、输出保护、资源和 Bundle ID 保留。原样本指令离线反汇编确认，启动代码为 92 字节，原函数边界为 164 字节。

macOS 原生桩测试覆盖默认索引/认证参数、空初始化字典、AppKey 空仍继续初始化、初始化失败不调用签名、22 字段输入与两次正文摘要变化、完整签名、部分字典、错误伴随完整字典、非字符串字段及非字典返回、数值错误保留、报告脱敏以及缺资源/缺清单阻断。它们不会执行真实 SDK。

用户已提供第一版工作流编译的诊断库，本机已生成未签名诊断 IPA。旧包的头部字符串覆盖风险修复后，用户在 LiveContainer 中运行成功，原配 6.8.260603 本地初始化通过。现在需重新构建诊断版本 2 的 dylib，再制作 IPA；不能用旧 dylib 验证新增签名检查。Windows 未运行本次 Xcode 原生编译及桩测试，版本 2 的真实 SDK 签名生成尚未验证。
