# AGP 9 模块迁移实施计划

> 在当前会话按 executing-plans 流程执行，完成后使用 requesting-code-review 独立审查。

**目标：** 消除 KMP 与 Android Application 同模块冲突，保持 Android 渠道和 iOS Framework 行为。

**架构：** androidApp 依赖 composeApp。前者负责应用入口、Manifest、JNI、签名和渠道；后者使用 Android KMP library 插件，保留共享 UI、平台 actual、Android 功能实现和多平台许可证收集。

**技术栈：** Kotlin Multiplatform、Compose Multiplatform、AGP 9.4.0、Kotlin 2.4.20、JDK 21。

## 约束与设计

- 保留用户已有的依赖与 Gradle 升级，不引入额外依赖版本。
- 应用 namespace 保持 vip.mystery0.xhu.timetable，共享库使用 vip.mystery0.xhu.timetable.shared。
- 共享层通过 AndroidAppConfiguration 接收版本号、渠道开关、调试标记、应用名称、Feature SDK 配置及启动 Activity 类型；在日志、Koin、MMKV 初始化前设置。
- 共享资源保留于共享库；应用名称及构建生成的资源由应用模块提供。
- iOS 的 ComposeApp Framework 名称和 composeApp 模块路径不变。
- 不修改 Room 实体或 schema，运行 KSP 验证新 Android 目标。
- 不提交签名、推送配置和构建产物；相对签名路径保持原 composeApp 基准。
- 实测华为 AGConnect 1.9.1.301 调用旧 applicationVariants，使用 AGP 9.4 的 android.newDsl.optOut=:androidApp 做局部兼容；共享库不退出新 DSL，内置 Kotlin 保持启用。华为插件升级前不宣称兼容 AGP 10。

## 执行与验收

- [x] 调整 settings.gradle.kts、版本目录、根与 composeApp 构建脚本，新增 androidApp/build.gradle.kts，移除全局 builtInKotlin/newDsl 退出开关。
  - 共享目标使用 kotlin.android，启用 androidResources，保持 JVM 21 和 kspAndroid。
  - 应用依赖通过 implementation(project(":composeApp")) 引入共享库，并声明启动入口直接使用的依赖。
  - 原 android 块、版本计算及华为插件迁入应用模块；aboutLibraries 保留在共享模块，覆盖 iOS 专属依赖。
- [x] 迁移 Application、StartActivity、Manifest、JNI 和 ProGuard 配置。
  - 共享 Application 基类接收配置，actual 使用 getter 读取，小组件通过配置中的类型启动 Activity。
  - 保留组件全限定名和 JNI 方法签名。
- [x] 更新 CI、.gitignore、README.md、AGENTS.md 中的路径和命令，将本机忽略的推送配置复制到新模块。
- [x] 使用 JDK 21 验证 Gradle 配置、共享 Android 编译、两个渠道的 debug APK、许可证导出和 Apple 版本任务。
  - 检查 BuildConfig、合并 Manifest、APK 中的 JNI 与 KSP 输出。
  - 独立审查并修复发现的问题。
  - 如环境阻塞，记录实际错误；Windows 无法执行 Xcode 构建。

## 验证记录

- JDK 21 下 Gradle `help` 通过，未再出现 KMP 与 Application 同模块的弃用提示。
- `standardDebug`、`storeDebug`、`standardRelease`、`storeRelease` 的 BuildConfig 生成通过；核对了应用 ID、提交计数版本号及更新检查开关。
- `composeApp:updateAppleBuildVersion` 通过。
- Manifest、StartActivity、JNI、混淆字典和规则与迁移前内容逐文件比较一致；本机推送配置处于 Git 忽略范围。
- 独立审查提出的 iOS 许可证遗漏问题已修复并复核关闭：aboutLibraries 继续在共享模块收集多平台配置。
- 初次验证遇到 Google Maven TLS 失败和私有仓库 HTTP 401。用户更新本机 token 后，身份认证及依赖下载恢复，最终构建未使用临时插件映射脚本。
- 凭据读取已按用户要求改为逐项优先读取 `local.properties`，缺失或为空白时回退环境变量；验证时仅输出来源和认证状态，未输出凭据内容。
- 修复了组合任务中的许可证导出顺序：资源复制任务通过 `mustRunAfter` 保证先导出后复制，普通构建不会被强制触发导出。
- 移除旧的 Ktorfit 编译插件 `2.3.3` 覆盖。现有 Ktorfit Gradle 插件 `2.7.5` 自动为 Kotlin `2.4.20` 选择兼容的 `2.3.5`，消除了编译插件加载时的 ClassCastException；未额外调整版本目录。
- `composeApp:compileAndroidMain`、`androidApp:assembleDebug` 通过，生成 standard 和 store 两个 debug APK。
- Android KSP 生成了数据库实现与构造器，Room schema 文件哈希与迁移前一致。
- 核对两个 APK 的应用 ID、合并 Manifest 中的 Application/StartActivity、BuildConfig 更新开关，以及 arm64-v8a/armeabi-v7a 的 libbspatch.so。
- 许可证导出成功，输出和 APK 资源均包含 iOS 专属依赖，未遗漏 ktor-client-darwin、multiplatform-settings、sqlite-bundled。
- 独立审查已复核任务顺序、凭据读取和 Ktorfit 兼容性修复，未发现新增问题。`git diff --check` 通过，密钥与构建产物未进入版本控制。
- Windows 下未执行 Xcode/iOS Framework 构建，也未执行 release 打包或设备运行验证。
