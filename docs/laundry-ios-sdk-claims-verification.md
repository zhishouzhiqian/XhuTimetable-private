# iOS 校园安全组件：静态分析结论复核

日期：2026-10-02。范围仅限 iOS 洗衣功能。本文复核另一份 `laundry-ios-securityguard-204-2404-rootcause.md`，不把其中的推断直接作为修复依据。

## 当前结论

真机阻塞仍未解决：候选 SDK `5.6.231002` 下 AppKey 返回空值并记录 `204`，统一签名初始化返回 `2404`，尚未生成可用签名，也未验证校园服务端登录及设备注册。校园原程序包含的组件版本是 `6.8.260603`。

**「图片内容代际不兼容」这一推断已被修订 `6f5eb65` 的真机数据证伪**，不要再作为工作假设：

- 八组对照按「主图是否存在」重排后，分界线是**存在性**而非内容——真实校园图片、同长度全零、同长度随机、截断一半、仅前 16 字节，五种完全不同的字节内容**一律返回 204**；只有主图缺失才是 203。
- 11 条宿主通道全部自检命中，但 `open`/`fopen` = 0、`fd` 通道（lseek/fstat）= 0 → **窗口内没有打开过任何文件的内容**；`stat` 150 次但目标命中 0 → **从未按名访问过 `yw_1222*.jpg`**；目录内 = 0 → **从未访问 `customBundelPath` 指向的对照目录**。
- 已排除「字节码直接发原始 syscall 绕过 interpose」：AVMP 解压字节码（139,708 字节）里 `svc`/`brk`/`hvc`/`smc` 命中 0，原生 IR 的 1611 个内联汇编块里也没有。

因此图片内容**根本没有进入任何解析器**，204 不可能是内容校验的结果。SDK 版本差异仍然存在，但「6.8 图片喂 5.6 SDK 导致内容不兼容」不再是被支持的机制。

**当前唯一未解开的矛盾**：对照目录里主图的存在性影响错误码（203↔204），而 SDK 从未通过任何已覆盖通道访问过该目录。三个候选解释与检验方式见实验协议「尚未解开的矛盾」一节；本轮已补「目录外访问归类/扩展名/安全资源命名」三条报告行，用于先定位 SDK 究竟在哪找图。

本节其余内容来自候选静态库的可解析 LLVM IR 与当前检查代码，不代表完整机器码覆盖；本机无 Xcode，未进行 iOS 原生编译。

## 文件读取结论的修正

LLVM 的 Darwin 外部符号采用 `@"\01_fopen"`、`@"\01_open"`。仅搜索普通 `@fopen(` 或 `@open(` 会漏掉它们。

在 `SGMain-SGMain99999999.o.ll` 中，按函数体内实际 `call/invoke` 指令统计，得到如下静态调用点数。它们不是运行次数，也不是 JPG 读取次数。

| 入口 | 直接调用点 |
| --- | ---: |
| fopen | 27 |
| open | 2 |
| stat | 36 |
| access | 17 |
| fread | 22 |
| fseek | 18 |
| syscall | 3 |

原报告的若干计数混入声明或全局引用。`open` 两处出现在 `CMa02WYChp8Bw4`，参数包含写入相关标志，不能作为安全图片读取证据。

三个直接 `syscall` 的首参数都是 `372`。Apple XNU 定义该编号为 `thread_selfid`，属于线程 ID 查询。因此这三个调用不能解释文件跟踪未命中。反过来，这也不能排除其他对象、内联汇编或未解析代码里的文件访问。[Apple XNU syscall 定义](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/syscalls.master)

找到的 Foundation 文件读取用途如下。仅对这些函数中引用的文件名及格式字符串进行解码，没有解密安全图片、输出其负载或提取密钥。

| 函数 | 可确认的用途 |
| --- | --- |
| `CMa02kZPR0uumS` | `mainBundle` 下查找 `embedded.mobileprovision`；读取文本、扫描 `<plist` 与 `</plist>`、解析 plist |
| `-[SecurityGuardOpenInitialize getInitConfig:withAppPath:]` | 读取 `init.config/update.config`；按 `app_%ld` 组织配置缓存目录 |
| `CMa02HzfCarffo` | 注册到 `zlib_filefunc64_def_s` 的 ZIP 文件打开回调；最终调用 `fopen` |

这几处均没有建立到两个 `yw_1222*.jpg` 的实际调用链。因此应撤回“Foundation 读取安全图片就是 fopen/open 为零的原因”这一确定结论。

## 初始化顺序与缓存

已核对以下调用链：

1. `OpenSecurityGuardManager getInstance:withCustomBundlePath:error:` 在单例初始化时保存认证参数及自定义路径，并请求初始化组件。
2. `OpenInterfaceLibrary` 取得并缓存组件，加载 MainPlugin。
3. `MainPlugin initializePlugin:` 使用 `dispatch_once`；块函数 `CMa02A4931DAj5` 调用 `initialize:withCustomBundlePath:`，记录初始化结果。
4. `SecurityGuardOpenInitialize privateInitialize:withCustomBundlePath:` 选择资源路径，把 UTF-8 路径装入初始化参数，并调用底层命令 `10501`。

因此，当前管理器入口并非仅创建一个接口对象而完全遗漏底层初始化。不要在没有证据时额外调用另一套初始化入口。

`privateInitialize` 中特殊 Bundle 后缀为 `.xctest`；普通应用情况下，非空自定义路径优先于 mainBundle 路径。当前代码给管理器和统一签名初始化传入同一份已校验的导入目录，统一签名参数键仍采用厂商实现中的 `customBundelPath`。

`dispatch_once` 证明首次初始化具有缓存语义；但没有真机首次入口时间的证据，不能认定其导致本次问题。稳定返回 `204` 不能排除早先缓存状态。每次改变资源或参数后必须使用新的应用进程进行对照。

## 错误码可以和不可以证明什么

AppKey 包装层命令为 `10902`；底层错误加 `200`，所以 `204` 对应这条接口的底层值 `4`。统一签名初始化的另一条桥接接口也把其底层值 `4` 映射为 `2404`。

两个独立接口中的值恰好相同，不能独立证明它们读取同一个文件、进入同一个解析器或具有同一个根因。也不能仅凭 `204` 推断本次已经打开、读取了导入目录下的目标图片。

已有错误提示仍可保留“安全数据文件格式问题，需要核对资源类别与版本兼容性”。不能升级成“已经证明只有代际不兼容”，不能据此排除选错文件、缓存、初始化环境或其他解析失败。

图片负载中的常量、字段偏移与 SDK 版本之间尚未建立解析代码或官方格式文档的对应关系；不应给它们直接赋予“魔数/格式版本”的已确认含义。

## 下一步实验应回答的问题

现有 `fopen/open` 自检证明宿主跟踪入口可用，不能证明完整覆盖 SDK 与系统库，也不能证明调用窗口之外没有发生读取。继续增加未经定位的入口不足以解决问题。

下一次需要真机验证时，应先设计新进程下的最小对照，记录每个阶段的结果，而不是继续重复原样构建：

| 对照 | 能回答的问题 | 不能据此下的结论 |
| --- | --- | --- |
| SDK 调用前启用观察，记录初始化阶段与 AppKey 阶段分别发生的访问 | 是否在 AppKey 请求前已读取并缓存；宿主可见调用的时序 | 零命中不能证明 SDK 没读文件 |
| 独立新进程使用缺少主图的目录，再与完整目录比较 | 结果是否受所选目录/主图存在性影响 | 即使错误码变化，也不单独证明实际读取路径或格式代际 |
| 使用厂商明确配套的 SDK 与资源进行对照 | 当前集成方式能否处理已知配套组合 | 成功不能证明校园资源失败只有版本一个原因 |

缺图对照需要诊断专用入口，因为当前检查在资源不完整时会主动跳过 SDK；简单移走图片不会执行到待调查的失败点。不得为此削弱正式应用的资源完整性校验。

如要区分“读取了错误文件”与“读对文件但解析拒绝”，需要取得实际命中的文件身份与失败阶段证据。仅有错误码及完整性校验不能完成这一判断。

同代 SDK、配套资源和校园服务端授权属于不同条件；取得某一条件不代表其他条件自动满足。Android 签名或后端代理也尚未验证 iOS 会话建立，不能作为已经可交付的修复。

## AppKey 分发链的进一步核对

在候选 SGMain 的可解析 bitcode 中，命令入口 `CMa02JYdt11b9o` 把 `10902` 拆成 `(1, 9, 2)`，以标志 `1` 交给 `CMa02G3LDtYwUT`。初始化命令 `10501` 对应 `(1, 5, 1)`。

该分发函数包含两种路径：虚拟化方法查询与原生注册表查询。虚拟化查询编号的计算式为 `66000000 + group * 10000 + middle * 100 + sub`；AppKey 对应 `66010902`。如果虚拟化查询标记为已处理，函数直接返回该结果；否则查询对应标志的原生函数表。存在这些分支不等于已经证明本次真机运行选择了哪一条。

AppKey 原生注册 `(1, 9, 2, 1)` 对应 `CMa02WYLvRCbzL`，其继续转发到 `(1, 6, 43, 0)`。相同编号但标志为 `0` 的 `(1, 9, 2, 0)` 对应 `CMa02XmFtsZTeQ`，它是索引提供器调用，不能把它误当作 AppKey 的图片解析器。

目前 `(1, 6, 43, 0)` 在**四个 framework 的原生注册表里都没有处理器**（`tools/audit_sg_appkey_dispatch.py` 复核，注册形状 `(i32 1, i32 6, i32 43, i32 [01], ptr @CM…)` 零命中）。结合 `CMa02G3LDtYwUT` 的分发结构——先做虚拟化查询（AppKey 对应合成键 `66010643`），命中即返回，未命中才查原生表——可判定：`(1, 6, 43, 0)` 的实现**只可能来自 AVMP/uvm 字节码**，不是原生函数。直接全文搜索到的 fread/fopen 辅助函数因此接不进这条链。

### 底层错误 3/4 的产生位置（本轮闭环）

`raw` 小码的产生分两层，均已用 IR 行号确认：

- **统一签名侧（SGMiddleTier）**：`CMi02Tqa0lTIP5` 经 `(1, 6, 8, 0)` 取得底层结果后，用一张 `switch` 把 `raw` 映射进 2400 段：`1→2401, 2→2402, 3→2403, 4→2404, 6→2405, 8→2409, 12→2406, default→2407`。真机观测「缺主图→2403 / 主图存在但损坏→2404」正好落在 `raw=3`（无文件）与 `raw=4`（格式/解析失败）两档。
- **AppKey 侧（SGMain）**：`-[SecurityGuardOpenStaticDataStore getAppKey:authCode:]` 把底层 `raw` 加 `200`（IR `add nsw i32 %local36.0, 200`），故 `raw=4 → 204`。

两处数值同源（`raw=4`），是同一底层错误在两个出口的视图。**但 `raw=3/4` 本身的判定分支位于 AVMP 字节码内部**：SGMain 内嵌一段 zlib 压缩的 uvm 程序（`@CMa02JaGysSpgl`，65,119 B，解压后 139,708 B，香农熵 6.15），其中**既无 `66xxxxxx` 合成键明文，也无 `(1,6,43)` 的 i32 编码**——注册键由 VM 在运行时构造，静态 IR 层不可见。因此「产生 3/4 的具体校验指令」无法只凭静态分析定位，只能靠真机宿主通道观察 + 错误码对照间接收敛（见实验协议本轮补充）。这是**边界，不是已定位**。

### 为什么 fopen/open 零命中不能证明「没读文件」（本轮机制解释）

审计候选 SGMain 的 AVMP/uvm 宿主函数注册表 `@CMa02yPs7JVQ0W`（165 项，`tools/audit_sg_appkey_dispatch.py` 第 3 节）：

| 类别 | 宿主表内可用的入口 |
|---|---|
| 路径/目录探测 | `access`、`opendir`、`readdir`、`closedir`、`lseek`、`fcntl`、`fstat`、`lstat` |
| 内容读取 | **只有 `objc_msgSend`**（调 Foundation：`NSData/NSString/NSFileManager/NSBundle` 的文件读方法） |
| 路径拼接 | `NSHomeDirectory`、`NSSearchPathForDirectoriesInDomains`、`_NSGetExecutablePath` |
| **不在表内** | `fopen`、`open`、`read`、`fread`、`stat` |

字节码 VM 想读安全图片，**只能经 `objc_msgSend` 调 Foundation，或用 `access/lstat/opendir/readdir` 探测路径**；它根本没有 `fopen/open` 宿主入口。app 级 `fopen/open` interposer 又只覆盖自身链接命名空间（Foundation 内部读取不经它）。两者叠加，**fopen/open 零命中是必然的，与「SDK 有没有读文件」无关**。这正是上一版观察方法的原理性缺口，也解释了自检通过却全程零命中。

据此本轮把诊断观察面从 `fopen/open` 扩到**宿主通道**：`ProbeResourceTrace` 新增 `CampusProbeTraceOptionsHostChannels`，用 method swizzle 拦截 `NSData dataWithContentsOfFile:`(+options:error:)、`NSString stringWithContentsOfFile:encoding:error:`、`NSFileManager contentsAtPath:/fileExistsAtPath:(isDirectory:)/attributesOfItemAtPath:error:`、`NSFileHandle fileHandleForReadingAtPath:`、`NSBundle pathForResource:ofType:`，并 interpose `access/opendir`。swizzle 对**任意调用方**（含字节码经 objc_msgSend 的调用）生效，不受链接命名空间限制——这是它比 app 级 `fopen/open` 更可能命中的根本原因。

### 该轮观察面不足，已被真机结果证伪（修正记录）

上一版本节还写着「`readdir/stat/lstat` 在 Darwin 有 `$INODE64` 符号重定向，拦截命中不可靠，故不列为可断言通道」，并据此移除了 `stat/lstat`。**这个判断是错的，且已被两处证据推翻**：

1. **IR 核对**：SGMain 的 target triple 是 `arm64-apple-ios9.0.0`，`stat`（36 处调用）、`lstat`（3 处）、`fopen`（27 处）全部是**纯符号，`$INODE64` 计数为 0**。`$INODE64` 重定向只存在于 x86_64 macOS 桩测试环境，真机 arm64 上 SGMain 的调用会直接绑定到探针定义。核对脚本 `build/laundry-ios-analysis/check_stat_symbol_binding.py`。
2. **计数旁证**：真机 `access` 命中 28 次、`opendir` 52 次，都**超过** IR 里的调用点（17 / 6），差额来自 AVMP 字节码经宿主表调用。既然同类的 C 原语能被抓到，`stat` 被移除就纯粹是覆盖面损失。

因此移除 `stat` 是本次调查中的一个实际失误：它是覆盖面最大的文件原语，却在唯一一轮真机运行里缺席。现已补回，并用 `PROBE_STAT_SYMBOL` 处理 x86_64 的同代符号（dlsym 必须取与定义同代的 `stat`/`stat$INODE64`，否则 `struct stat` 布局不一致会读到垃圾值）。

另一处不足是只 swizzle 了**类方法**。字节码经 `objc_msgSend` 可以直接调 `[[NSData alloc] initWithContentsOfFile:]` 绕过 `+dataWithContentsOfFile:`，故实例 `init` 族必须单独拦截。已补齐 NSData/NSString 的 `initWithContentsOfFile:`、`initWithContentsOfFile:options:error:`、`initWithContentsOfURL:`，并新增 URL 形态、`fileExistsAtPath:isDirectory:`、`contentsOfDirectoryAtPath:error:`、`+[NSBundle bundleWithURL:]`、`-pathForResource:ofType:inDirectory:`，以及 fd 级 `lseek`/`fstat`（经 `fcntl(F_GETPATH)` 反查路径）。

`readdir` 仍不拦截：它在 AVMP 宿主表里存在，但 x86_64 macOS 上确有 `$INODE64` 变体、桩测试命中不可靠，且目录枚举已可由 `opendir` + `contentsOfDirectoryAtPath:error:` 覆盖。`read/pread` 明确不拦截：宿主表里没有这两个入口（只有 `lseek/fstat/fcntl`），而它们是全进程最热路径。

不修改返回值、不跳过安全校验、不把非空但不完整的字典判定为签名成功，这些约束保持不变。

## 本轮验证与边界

- 只读调用点脚本运行成功；排除了声明和全局注册表引用对计数的干扰。
- 复核了 Foundation 调用点的资源文件名、MainPlugin 初始化块、自定义路径传递和两个错误码包装层。
- 仅检查可解析的 bitcode。部分对象不含有效 bitcode，间接调用和虚拟化代码不能由上述扫描完整还原。
- 已收到修订 `8234c06` 的七组设备对照与修订 `f615ff0` 的宿主通道第一轮（`main-zero`，103 次通道调用、目标命中 0），结果见实验协议；`204/2404` 尚未修复，签名和服务端注册尚未验证。
- 宿主通道第一轮**证伪了「只覆盖类方法即可」的判断**，并证明移除 `stat/lstat` 是失误（IR 核对：真机 arm64 无 `$INODE64` 变体，`stat` 有 36 处调用）。第二轮已补齐实例 `init` 族、`stat/lstat`、fd 级 `lseek/fstat`，并为每条通道加「自检命中」标注，使零命中可区分「SDK 没读」与「我没覆盖」。
- 已核对四个 framework 均为**静态库**（每个 slice 是 `ar` 归档、无 `LC_ID_DYLIB`），故 SGMain 的未定义文件符号在链接期绑定到探针定义；真机 `access` 28 次 / `opendir` 52 次均超过 IR 调用点（17 / 6），差额来自 AVMP 宿主表调用，反证 C 层 hook 对 SDK 有效、`fopen=0` 是真阴性。
- 已核对公开 SDK 包（2902 条目）**不含任何 `.jpg` 或 `yw_` 安全图片**，故「同代 SDK + 自有 appkey 图片」无法本地构造对照，须外部申请。
- 新增 `tools/audit_probe_source_consistency.py`：无 Xcode 环境下对 Objective-C 源码做文本级核对（括号平衡、`ProbeOriginal*` 声明与赋值配对、IMP 出参确被 `ProbeInstallInterceptor` 消费、通道名与报告一致、已移除符号无残留、自检判据、递归抑制）。Windows 上运行通过。
- 宿主通道观察（swizzle）与新增 C 拦截已在修订 `6f5eb65` 的真机运行中生效：11 条通道全部「自检命中」，且两轮通道合计与阶段「目录外」合计分别精确相等（254=254、255=255），说明观察器工作正常、数据可信。**本机仍无 Xcode**，Objective-C 侧只经逐行复核与静态检查，未在本地编译。
- 新增 `tools/audit_probe_report_parsing.py`：用 Python 复现 `ParseHostRow` 的扫描逻辑，对照 C 侧格式串逐字校验全部报告行标签（含本轮新增的归类行与扩展名行）、自检状态字面量、`%u` 个数与解析标签数的一致性，并核对隐私约束（命名匹配不得按图片扩展名）。ObjC 测试本机跑不了，这是提前发现「标签差一个字导致 CI 中止」的唯一手段。
- `raw=3/4` 的具体判定指令在 AVMP 字节码内，静态不可见。**修订 `6f5eb65` 的真机数据已推翻本节此前「根因收敛到字节码图片解析器拒绝校园图」的表述**：11 条通道全部自检命中，但 `open`/`fopen`/`fd` 全 0、目标命中 0、目录内 0，图片内容从未被读取，`raw=4` 只能产生于读取内容之前。第二轮的 H1/H2 判定矩阵结果为 **H2 成立且更极端**（`stat` 对目标也是 0 命中），矛盾未闭合，详见实验协议「尚未解开的矛盾」。
