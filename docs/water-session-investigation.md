# 用水会话调查（2026-09-20）

本文仅记录脱敏元数据，不保存 HAR 原文、Cookie、openid 或签名值。

## 已验证

- 电脑微信携带 `_sop_session_` 请求学校短链，取得带签名参数的一卡通入口跳转。
- 一次性代理实验只在 `GET /home/openHomePageXH` 将 JSESSIONID 替换为测试值；返回 302 和新的 JSESSIONID（32 字符、Path=/、HttpOnly），随后用水页面返回 200。无需等待自然过期。
- iPhone Reqable 记录 468：扫码回调设置 `_sop_session_`（Path=/、HttpOnly，无 Expires/Max-Age）；469 携带该 Cookie 取得签名跳转；470 收到 JSESSIONID；478、484–487 业务成功。
- App 重启后，554 请求学校短链不带 Cookie，被 301 重定向到二维码页。此时 544–547 的业务请求仍携带 JSESSIONID。

因此，本次可复现的问题是学校会话 Cookie 未跨 iOS 进程重启保留，不能据此认定服务器已撤销该学校会话。

## 实现与边界

iOS 仅对学校域名、根路径的 `_sop_session_` 使用 Keychain 备份，在加载认证入口前恢复到 WKHTTPCookieStore；监听轮换和删除，成功返回业务层前再完成一次备份。保留服务端有效期，不人为延长。显式清除凭据时删除备份；仅 JSESSIONID 失效时仍保留学校会话和设备信息。

学校会话的服务端有效期尚未测定，不能承诺永久免扫码。App 修复后的重启恢复与失效恢复仍需真机验证。Android 自动恢复仍未启用。

## 真机验收

1. 覆盖安装修复版，扫码一次以建立 Keychain 备份。
2. 强制关闭并重启 App，通过官方认证入口验证无需扫码。
3. 将表单 JSESSIONID 改为 `invalid-test-session`，保留其他字段后保存；确认自动恢复、读取余额成功，且只有一次重试。
4. 学校会话确实失效时应回退扫码；不使用真实水阀开关进行验收。
