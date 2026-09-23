# 天猫校园短信登录协议调查（2026-09-23）

本记录只包含用户提供的 `登录数据 root.har` 的脱敏元数据和本仓库代码现状。原始 HAR 含手机号、验证码、Cookie、会话及设备凭据，不进入仓库，也不作为可重放的测试夹具。

## 验证结论

- 抓包确认天猫校园自身的手机号验证码路径使用 `mtop.taobao.mloginservice.smssend` 和 `mtop.taobao.mloginservice.smslogin`。接口名包含 `taobao` 不表示用户选择了淘宝账号授权。
- `smssend` 返回的 `data.returnValue.extMap.smsSid` 被两次 `smslogin` 的 `data.loginInfo.smsSid` 原值复用；两次登录提交使用同一短信验证码。同一流程中的 `deviceId` 和 `utdid` 保持一致。
- 第一次 `smslogin` 返回 HTTP 419、`FAIL_SYS_USER_VALIDATE`，接着发生 `_____tmd_____/punish` 及图形验证请求。第二次返回 HTTP 200，`ret` 含成功结果，业务层 `actionType=SUCCESS`、`code=3000`，并下发 `sid`、自动登录令牌和设备令牌。HTTP 状态本身不是登录成功判据。
- 登录后的 `mtop.tmall.campus.member.app.user.get` 请求把上述 `sid` 放在 `x-sid` 中，返回本人账号资料。**这仅证明官方 App 的会话传递，尚未证明独立客户端能产生相同会话。**
- `mtop.tmall.campus.member.wechat.user.ucc.token.get` 返回的 `linkToken` 被后续 `mtop.alibaba.ucc.oauthlogin` 的 `authorizationRequest.userToken` 使用。该 OAuth 响应的 `sid` 与前一步短信登录的 `sid` 不同。抓包没有洗衣请求，无法判断此交换是否为洗衣所必需。
- `x-sign`、`x-mini-wua`、`x-sgext` 在发送短信、两次登录和后续资料请求中均变化；`x-appkey`、`x-utdid`、`x-devid` 在该流程中保持一致。HAR 只记录结果，不能据此生成下一次请求的签名或安全校验值。

## 对应 APK 的静态核对

用户补充的天猫校园 Android APK 包名为 `com.tmall.campus.and`，版本 `5.7.0`（`versionCode=50007000`）；HAR 中 `x-app-ver` 与之相符。本机雷电模拟器也安装了相同版本。这些核对没有使用或导出账号资料。

APK 含九份 DEX、`libsgcore.so`、`libsgmain.so`、`libsgmainso-6.8.260602.so` 及 `yw_1222.jpg`。静态方法引用表明 `mtopsdk.security.InnerSignImpl`、`ProductSignImpl`、`OpenSignImpl` 的 `getMtopApiSign` 最终调用 `SecurityGuardManager.getSecureSignatureComp().signRequest(...)`；相关实现还调用安全组件产生附加请求字段。这证明 APK 中存在原生签名链路，但**尚未证明该 SDK 能在西瓜课表的包名、签名证书和设备环境中独立初始化，也不能据此得出签名算法或将 APK 组件直接搬入项目**。

另用全新、无 Cookie 的临时客户端对公开 H5 路径做了空数据探测：`mtop.common.getTimestamp` 返回 `SUCCESS`，同一路径形式的 `mtop.taobao.mloginservice.smssend` 返回 `RGV587_ERROR`。探测不携带手机号、验证码或既有会话，未触发短信。此结果不足以证明 H5 登录路径可用，也不能证明它永久不可用；不应把该路径作为已经验证的替代实现。

## 已观察的请求结构

| 步骤 | 请求数据的顶层字段 | 关键关联字段 | 响应检查 |
| --- | --- | --- | --- |
| 发送短信 | `ext`、`loginInfo`、`riskControlInfo`，均为 JSON 字符串 | `loginInfo.loginId`、`deviceId`、`utdid` | 检查 `ret`、业务 `actionType/code`，保存本次 `smsSid` |
| 提交验证码 | 同上 | `loginInfo.smsCode`、`smsSid`，同一设备上下文 | 处理安全验证，成功时检查业务结果及 `sid` |
| 账号资料 | URL 参数 `data` | 请求头 `x-sid` | 检查 `ret` 和资料结构，不能只看 HTTP 200 |
| UCC 令牌 | URL 参数 `data` | 请求头 `x-sid` | 返回 `linkToken` |
| UCC 会话交换 | `authorizationRequest`、`riskControlInfo`，均为 JSON 字符串 | `authorizationRequest.userToken=linkToken` | 返回另一组会话及有效期字段；洗衣必要性未验证 |

短信请求的 `loginInfo` 还包含应用版本、登录类型、地区、设备名称、SDK 版本、时间和 `ttid` 等字段；`riskControlInfo` 包含设备/系统及 `umidToken`、`wua` 等安全上下文。它们的来源、可由第三方客户端合法生成的方式以及哪些字段为服务端必填，仍需独立实验确认。不要把本次抓包里的常量或动态值复制到应用中。

## 尚未通过的验收项

1. 在西瓜课表自己的客户端中生成新请求的动态签名和设备安全字段。
2. 用新的验证码完成一次本人账号登录，包括服务端要求的图形验证；不能跳过或把验证页面返回当作成功。
3. 使用新会话查询本人资料，随后验证重启恢复、过期判断和正常续登。
4. 分别验证有无 UCC 交换时的洗衣业务只读查询，以确定其必要性。
5. 获取真实洗衣二维码、设备详情、订单、付款后运行状态和完成状态的脱敏抓包，再确定设备识别与剩余时间字段。现有 HAR 不包含这些请求。

现有 Android 洗衣实现使用官方 WebView 登录页及页面内 `lib.mtop` 查询，当前分支中的该登录已失败，且不符合独立短信登录的目标。`mtop.tmall.campus.share.applet.general.user.urgent.order.list` 和 `mtop.tmall.campus.share.applet.general.order.detail.get` 仅是已有代码中的候选接口，本 HAR 未验证。iOS 洗衣功能仍未启用。按“先验证协议，再接入业务”的顺序，本次调查不把现有 WebView 路径改称为独立登录，也不接入未经验证的洗衣请求。

## 下一次验证所需材料

- 已取得对应版本的 Android APK 和可连接的本机模拟器。下一步需在不依赖官方 App 已登录状态的隔离客户端中，验证签名组件可否初始化并为新请求产生有效签名；若失败，应记录具体包名或资源约束，而不是重放旧签名。
- 本人账号的一次新验证码登录测试环境；验证码由用户在设备上输入，不写入文件或日志。
- 完成独立资料查询后，再补充洗衣业务的脱敏抓包。支付和启动设备只由用户手动操作；自动测试仅做只读查询。
