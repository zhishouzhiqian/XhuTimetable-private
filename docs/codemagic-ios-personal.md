# Codemagic iOS 个人测试构建

仓库根目录的 `codemagic.yaml` 定义 `ios-personal-unsigned`，沿用 GitHub Actions 的 JDK 21、Xcode 26.2、共享 iOS 状态测试、Debug 无签名设备构建和 `PERSONAL_TEST_BUILD`。仅手动启动，不上传 App Store 或 TestFlight。

## 首次连接

1. 在 Codemagic 的 Applications 中添加 GitHub 私有仓库 `zhishouzhiqian/XhuTimetable-private`，选择使用 `codemagic.yaml`。如仓库列表为空，需要用户在 GitHub 完成 Codemagic 的该仓库访问授权。
2. 在该应用的 Environment variables 创建应用级变量组 `private_maven`，添加以下两项，并勾选 **Secret**。无需把凭据发到聊天或提交到仓库。

| Codemagic 名称 | 值的来源 |
| --- | --- |
| `GITHUB_USERNAME` | 原 GitHub Actions `NEXUS_USER` 使用的用户名 |
| `GITHUB_PASSWORD` | 原 GitHub Actions `NEXUS_PASSWORD` 使用的 GitHub Packages 读取 token |

GitHub Actions 已保存的 secret 不能读取后自动迁移；需要使用原始值。私有 Maven 包读取权限沿用项目既有要求，仓库连接的权限不能替代 Maven 凭据。

也兼容原名称 `NEXUS_USER` / `NEXUS_PASSWORD`：准备步骤映射为 Gradle 使用的 `GITHUB_USERNAME` / `GITHUB_PASSWORD`，通过 Codemagic 的 `CM_ENV` 供后续步骤使用，不输出值。用户已在应用变量组保存 `GITHUB_USERNAME` 与 `NEXUS_PASSWORD`，无需更改密钥名称。

3. 点击 Start new build，选择 `feature/water-service` 分支、`ios-personal-unsigned` 工作流，再启动构建。
4. 构建完成后从 Artifacts 下载 `XhuTimetable-personal-unsigned.ipa`。失败时查看准备、测试和 Xcode 日志，以及共享测试报告。

## 范围与验证状态

构建采用 mac_mini_m2，最长 60 分钟，缓存 Gradle 依赖、wrapper 和 Kotlin/Native 依赖。完整 git 历史用于原项目版本号；缺少凭据时立即失败，不打印凭据。IPA 在独立暂存目录打包，去掉个人测试不使用的扩展及旧签名。

未签名 IPA 需要用户自己的签名安装方式，不能直接安装到 iPhone。iOS 真实校园登录和支付客户端尚未接通；成功构建也不代表这些功能已完成。

本地 YAML 解析、Codemagic 官方 JSON schema 校验、5 个 Bash 步骤及内嵌 Python 语法检查均通过。后续修复 iOS 源码划分后，本地 `composeApp:compileAndroidMain` 通过（使用已有 Android SDK 路径作为当前命令的环境变量，没有改本机配置文件）。

后续已成功连接应用并确认两项 Secret 位于 `private_maven`；直接点击分支文字可打开分支列表，选择 `feature/water-service` 后已识别 YAML。首次构建 [6abcd3a5083ff0a9a53aa5dd](https://codemagic.io/app/6abcc2cd6c98472e80a8cc91/build/6abcd3a5083ff0a9a53aa5dd) 已进入运行器，环境检查、依赖准备及 Apple 版本更新成功。共享 iOS 测试在编译时发现 `iosMain` 与 `iosSimulatorArm64Main` 重复声明 `isDebug`，尚未运行测试或生成 IPA。已将设备声明移至 `iosArm64Main`，保留设备 false、模拟器 true，等待云端重新验证。

修复提交 `08f3ecf` 的第二次构建 [6abcd8ac083ff0a9a53aa753](https://codemagic.io/app/6abcc2cd6c98472e80a8cc91/build/6abcd8ac083ff0a9a53aa753) 已完成，共享 `iosSimulatorArm64Test` 编译与执行成功（8 分 42 秒），设备 Xcode 构建显示 `BUILD SUCCEEDED`，IPA 打包和 ZIP 内容/完整性校验成功。Artifacts 已提供 `XhuTimetable-personal-unsigned.ipa`（页面显示 32.24 MB）及日志/测试报告压缩包。Swift 宿主及扫码控制器可编译；这不替代真机运行、相机、授权和支付验收。真实校园客户端仍未接通，不能把此测试包当作已可下单的 iOS 版本。Android 继续本地构建，Codemagic 仅负责 iOS。

配置参考：[Codemagic YAML](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/)、[加密环境变量与变量组](https://docs.codemagic.io/yaml-basic-configuration/configuring-environment-variables/)、[Xcode 26.2 环境](https://docs.codemagic.io/specs-macos/xcode-26-2/)。
