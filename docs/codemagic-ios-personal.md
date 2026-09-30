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

本地 YAML 解析、Codemagic 官方 JSON schema 校验、5 个 Bash 步骤及内嵌 Python 语法检查均通过。未改应用源码，因此本轮没有重复运行 Android 构建。Codemagic 控制台连接在本次会话中失败（浏览器连接工具返回 `nodeRepl.fetch request failed`），因此尚未确认应用导入、环境变量或云端构建成功。

配置参考：[Codemagic YAML](https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/)、[加密环境变量与变量组](https://docs.codemagic.io/yaml-basic-configuration/configuring-environment-variables/)、[Xcode 26.2 环境](https://docs.codemagic.io/specs-macos/xcode-26-2/)。
