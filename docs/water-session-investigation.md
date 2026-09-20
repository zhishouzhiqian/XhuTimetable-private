# 用水会话调查（2026-09-20）

本文仅记录脱敏元数据，不保存 HAR 原文、Cookie、openid 或签名值。

## 已验证

- 电脑微信携带 `_sop_session_` 请求学校短链，取得带签名参数的一卡通入口跳转。
- 一次性代理实验只在 `GET /home/openHomePageXH` 将 JSESSIONID 替换为测试值；返回 302 和新的 JSESSIONID（32 字符、Path=/、HttpOnly），随后用水页面返回 200。无需等待自然过期。
- iPhone Reqable 记录 468：扫码回调设置 `_sop_session_`（Path=/、HttpOnly，无 Expires/Max-Age）；469 携带该 Cookie 取得签名跳转；470 收到 JSESSIONID；478、484–487 业务成功。
- App 重启后，554 请求学校短链不带 Cookie，被 301 重定向到二维码页。此时 544–547 的业务请求仍携带 JSESSIONID。

以上早期实验验证了学校会话 Cookie 未跨 iOS 进程重启保留；后续实验还发现独立的服务端失效问题，不能将持久化修复等同于长期免登录。

## 后续抓包：已保存学校会话仍失效

以下记录号属于后续 Reqable 会话，与上面的早期记录号不通用。

- 用户确认安装 `11a0cfe` 对应 IPA 并重新扫码后，记录 72 携带 `_sop_session_` 访问短链，仍被 301 转到二维码页；响应还下发该 Cookie 的过期删除指令。说明本地恢复 Cookie 不足以恢复服务端认证。
- 电脑微信记录 121 不带学校会话 Cookie，短链返回 301，进入 `api.szszcloud.cn/v1/wechat/oauth2`；122 观察到 OAuth 回调。
- 125 学校短链设置新的 `_sop_session_`，126 携带新 Cookie 取得一卡通签名入口，127 在没有 JSESSIONID 的情况下收到 302 和新的 JSESSIONID。随后首页、用水页面返回 200。
- 因此观察到的最小链为：短链 → 微信 OAuth（中间请求存在抓包缺口）→ OAuth 回调 → 学校短链建立学校会话 → 一卡通签名入口建立 JSESSIONID → 业务页面。微信成功依赖重新认证，不是同一个 JSESSIONID 永久有效。
- `_sop_session_` 未声明 Expires/Max-Age；服务端生命周期未知。没有发现可供 App 独立使用的长期 refresh token，也没有证据支持复制微信客户端身份到 WKWebView。
- 官方二维码页面使用 clientId、二维码和 SSE 等待扫码结果，再跳转完成认证。检查到的页面脚本未提供直接唤起微信或返回 App 的逻辑；同机返回流程仍需真机验证。

## 实现与边界

iOS 仅对学校域名、根路径的 `_sop_session_` 使用 Keychain 备份，在加载认证入口前恢复到 WKHTTPCookieStore；监听轮换和删除，成功返回业务层前再完成一次备份。保留服务端有效期，不人为延长。显式清除凭据时删除备份；仅 JSESSIONID 失效时仍保留学校会话和设备信息。

学校会话的服务端有效期尚未测定，不能承诺永久免扫码。App 修复后的重启恢复与失效恢复仍需真机验证。Android 自动恢复仍未启用。

后续调整：iOS 自动恢复不再把 OAuth 入口本身判为交互失败；页面完成导航后，仅对已知二维码页或绑定页立即回退。其他未完成认证的页面仍由现有 45 秒总超时结束恢复。既有单次恢复、单次重试和设备信息保留逻辑不变。这是纠正过早中断，不代表已证明 App 能像微信一样长期静默续登。

## 真机验收

1. 覆盖安装修复版，扫码一次以建立 Keychain 备份。
2. 强制关闭并重启 App，通过官方认证入口验证无需扫码。
3. 将表单 JSESSIONID 改为 `invalid-test-session`，保留其他字段后保存；确认自动恢复、读取余额成功，且只有一次重试。
4. 学校会话确实失效时应回退扫码；不使用真实水阀开关进行验收。

## 完美校园授权链与非官方客户端候选（2026-09-20）

来源：用户提供的 `bb95db2df5bb84ff4a9f61f8bf159070.har`，仅记录路径和字段名。原始 HAR 不进入仓库。

- 11:28:11.293 UTC：`GET open.17wanxiao.com/api/authorize` 携带 `token`、`client_id`、`redirect_uri`、`response_type`、`state` 等参数，返回 302；Location 指向 `ecard.xhu.edu.cn/homedwapp/openHomePage`，包含 `code`、`state` 等参数。
- 11:28:11.882 UTC：一卡通回调请求未观察到请求 Cookie，响应原始 Set-Cookie 头设置 JSESSIONID（Path=/、HttpOnly，无 Expires/Max-Age），并 302 到首页。HAR 的 response.cookies 数组为空，不能仅凭该数组判断没有设置 Cookie。
- 随后访问用水首页、设备列表及其他业务接口。HTTP 200 本身不能等同于业务成功，仍需业务返回码和真机页面确认。
- 授权请求的 token 与所携带的 8 个 Cookie 值均不相同。此结果不能证明原生注入方式、哪项凭据是必要条件、token 的有效期，或 Cookie 单独能否完成授权。
- HAR 未包含 token 的签发或刷新响应；`app.17wanxiao.com` 记录仅有 CONNECT/status 0，无法据此断言证书固定。`code` 是否一次性、有效期多久也没有通过本次记录验证。

### 新候选：本人账号直接登录完美校园

开源实现：https://github.com/ReaJason/17wanxiaoCheckin ，核对文件 `login/campus.py`：

- 实现密码登录 `loginnew.action`、短信登录 `registerUsersByTelAndLoginNew.action`，以及此前的通信密钥交换。
- 登录成功后将响应 `sessionId` 作为 token 返回；需要设备标识。项目 README 提示设备验证及多端登录冲突。
- 未实现 `/api/authorize`，也未发现 refresh 逻辑。项目已归档，不能据此承诺当前版本可用。
- 尚未验证该 sessionId 与本次 HAR 的 authorize token 属于同一凭据类型，也未验证能完成西华大学用水授权。

由此不能断言独立客户端必须先获得开发者 AppKey，也不能宣称已经实现长期免登录。可行方向是复现用户本人正常登录及授权流程，验证当前协议，不伪造身份或跳过验证码/设备验证。

### 最小补充实验

1. 在完美校园本人正常登录之前开始捕获；如不愿退出当前账号，先做冷启动并重新进入用水页面的捕获，检查是否出现会话恢复接口。
2. 保存登录或会话恢复请求的字段名、响应结构及后续 `/api/authorize`、一卡通回调的完整重定向链。敏感值仅由本机受控诊断程序处理，不显示、不提交、不发送到公共分析服务。
3. 先确认登录返回凭据与 authorize token 的关系，再判断是否值得实现独立登录。只做本人账号的正常验证，不猜测密码或批量请求。
4. 在隔离测试会话中去掉一卡通 JSESSIONID，保留该测试会话的上游登录态，重新走授权入口并验证只读余额；不必等一小时，不执行开关水阀。
5. 即使第四步成功，也只证明上游凭据有效时可重建 JSESSIONID；还须验证上游过期后的正常重新登录，才能承诺自动恢复。

调查阶段没有执行账号登录、短信发送或真实水阀请求。后续实现仅复现本人账号的正常短信登录与授权交换，不绕过验证码或设备校验。

### TLS 对照与客户端静态检查

- Reqable 导出的 `app.17wanxiao.com_2026_09_20_17_02_40.har` 含 15 条记录。完美校园 iOS 的统计、日志、Bugly、阿里云等 HTTPS 请求可以被正常解密；`app.17wanxiao.com` 的三次请求均只留下 CONNECT/status 0，代理端记录 Secure Transport `-9806`（`errSSLClosedAbort`）。
- 同一设备、代理和证书环境下，Safari 可以访问 `https://app.17wanxiao.com/`。这组对照将原因收敛到完美校园 App 对该域名的专用 TLS 校验或连接实现；`-9806` 本身只表示连接因错误中断，不能单独证明具体的证书固定算法。
- 本机 Android APK 包名为 `com.newcapec.mobile.ncp`，入口由 `com.stub.StubApp` 接管，并包含 `libjiagu_vip`，属于加固包；常规 JADX 只恢复出壳代码和资源，无法直接审查登录实现。
- Android manifest 的基础 network security config 仅允许明文流量，没有公开的 pin-set。该结果不排除 Java/native 动态证书校验，因为真实业务代码被加固隐藏。
- 公开旧版登录实现把密钥交换建立的 session 写入 `sessionId`，登录成功后将同一字段作为 token 返回；其他 H5 接口也把该 token 放在参数中。它与当前 `/api/authorize?token=...` 的命名和使用方式一致，但仍需本人账号的本机测试证明两者当前可互换。

### 已实现的隔离验证路径

- 使用临时 RSA 密钥调用 `exchangeSecretkey.action`，服务端仍返回可由对应私钥解密的交换响应；测试未携带用户账号信息，也未显示或保存响应凭据。
- iOS 提供完美校园短信登录入口：手机号和验证码只保留在当前内存流程，成功后的上游 session 写入 Keychain。
- 通过抓包确认的 `/api/authorize` 公共客户端配置加载授权页，先删除旧的一卡通 JSESSIONID；回调建立新 JSESSIONID 后才保存并继续只读查询。
- 完美校园链中的用水请求以空 openid 成功，因此业务认证条件改为 JSESSIONID 必填、openid 可空；微信链仍保留并校验 64 位 openid。
- 完美校园链的设备、记录和水阀状态接口接受空 openid，但余额接口 `/home/openHomePageApp` 不接受：已有 HAR 中空 openid 返回 `success=false`，64 位 openid 返回 `success=true`。因此完美校园模式不能伪造微信 openid；开水前改为显示“余额未知”二次确认，只有用户明确确认后才发送开阀请求。
- JSESSIONID 失效时优先使用 Keychain 中的完美校园 session 交换新会话，只允许原操作重试一次。上游 session 失效或授权未建立 JSESSIONID 时删除该上游 session，并要求重新短信登录或学校页面认证。
- 清除短期认证不会删除设备号与组织编号；用户主动“清除本地凭据”时才同时删除完美校园 session。

该实现不能承诺永久免登录：完美校园 session 的服务端生命周期仍未知，且可能因设备校验、账号安全策略或服务端协议变更而失效。首次真机验收只验证登录、自动发现设备、余额及记录，不操作真实水阀。
