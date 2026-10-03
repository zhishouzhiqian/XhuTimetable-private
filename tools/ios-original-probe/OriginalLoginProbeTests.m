#import "OriginalNetworkProbe.h"
#import <CommonCrypto/CommonDigest.h>

NSString *CampusOriginalProbeTestLoginBody(NSDictionary *, NSString *);
NSURLRequest *CampusOriginalProbeTestAccountRequest(NSDictionary *, NSString *, NSDictionary *, CampusOriginalPurpose);
NSString *CampusOriginalProbeTestLastInput(void);

@interface ALBBOAuthLoginInfo : NSObject
@property(nonatomic, copy) NSString *appName;
@property(nonatomic, copy) NSString *utdid;
@property(nonatomic, copy) NSString *ttid;
@property(nonatomic, copy) NSString *deviceId;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *snsType;
@property(nonatomic, copy) NSString *site;
@property(nonatomic, copy) NSString *locale;
@property(nonatomic, copy) NSString *hid;
@property(nonatomic, copy) NSString *deviceTokenKey;
@property(nonatomic, copy) NSString *deviceTokenSign;
@property(nonatomic, strong) NSNumber *useAcitonType;
@property(nonatomic, strong) NSNumber *useDeviceToken;
@property(nonatomic, strong) NSDictionary *ext;
- (NSDictionary *)testJSON;
@end
@implementation ALBBOAuthLoginInfo
- (instancetype)init {
    self = [super init];
    if (self) { self.hid = @"OLD_ACCOUNT_MUST_NOT_SEND"; self.ext = @{@"cookie": @"OLD_COOKIE_MUST_NOT_SEND"}; }
    return self;
}
- (NSDictionary *)testJSON {
    NSMutableDictionary *value = [@{@"sdkVersion": @"ios_mock", @"appVersion": @"5.7.2"} mutableCopy];
    for (NSString *key in @[@"appName", @"utdid", @"ttid", @"deviceId", @"token", @"snsType", @"site", @"locale",
        @"hid", @"deviceTokenKey", @"deviceTokenSign", @"ext", @"useAcitonType", @"useDeviceToken"]) {
        id item = [self valueForKey:key]; if (item) value[key] = item;
    }
    return value;
}
@end
@interface ALBBRiskControlInfo : NSObject
@property(nonatomic, copy) NSString *wua;
@property(nonatomic, copy) NSString *umidToken;
@property(nonatomic, copy) NSString *apdId;
@property(nonatomic, copy) NSString *t;
- (void)addDeviceInfo;
- (NSDictionary *)testJSON;
@end
@implementation ALBBRiskControlInfo
- (void)addDeviceInfo {}
- (NSDictionary *)testJSON {
    return @{@"wua": self.wua ?: @"", @"umidToken": self.umidToken ?: @"", @"apdId": self.apdId ?: @"", @"t": self.t ?: @"", @"osName": @"ios"};
}
@end
@interface ALBBJSON : NSObject
+ (NSString *)objectToJsonString:(id)object;
@end
@implementation ALBBJSON
+ (NSString *)objectToJsonString:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[object testJSON] options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
@end

static NSData *LoginTestData(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }

static NSDictionary *LoginTestObject(NSString *text) {
    NSCAssert([text isKindOfClass:NSString.class] && text.length > 0, @"测试前置条件：JSON 正文未构造成功；不能解析空数据");
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    NSCAssert(!error && [object isKindOfClass:NSDictionary.class], @"测试前置条件：正文必须为有效 JSON 对象");
    return object;
}

void CampusOriginalLoginProbeTests(void) {
    NSString *code = @"TEST_AUTHORIZATION_CODE_123456";
    NSString *callback = [NSString stringWithFormat:@"https://www.alipay.com/webviewbridge?action=taobao_auth_token&top_auth_code=%@", code];
    NSCAssert([CampusOriginalAuthorizationCode([NSURL URLWithString:callback], YES) isEqual:code], @"新主页面授权回调未通过");
    NSCAssert(CampusOriginalAuthorizationCode([NSURL URLWithString:callback], NO) == nil, @"子框架回调被消费");
    for (NSString *suffix in @[@"&top_auth_code=other", @"&action=other", @"#fragment"]) {
        NSCAssert(CampusOriginalAuthorizationCode([NSURL URLWithString:[callback stringByAppendingString:suffix]], YES) == nil, @"重复或歧义回调被消费");
    }
    for (NSString *url in @[@"https://taobao.com.attacker.invalid/", @"http://havanalogin.taobao.com/", @"https://user@taobao.com/", @"https://taobao.com:444/", @"taobao://login"]) {
        NSCAssert(!CampusOriginalAuthorizationNavigation([NSURL URLWithString:url]), @"授权目的地边界未生效");
    }
    NSCAssert(CampusOriginalAuthorizationNavigation([NSURL URLWithString:@"https://havanalogin.taobao.com/mini_login.htm"]), @"官方登录域被拒绝");
    NSString *deviceID = [@"D" stringByPaddingToLength:44 withString:@"D" startingAtIndex:0];
    NSMutableDictionary *identity = [@{@"x-appkey": @"TEST_APPKEY_MUST_NOT_APPEAR", @"x-utdid": @"AAAAAAAAAAAAAAAAAAAAAAAA",
        @"x-ttid": @"test@campus_iPhone_5.7.2", @"deviceID": deviceID} mutableCopy];
    identity[@"openManager"] = [NSClassFromString(@"OpenSecurityGuardManager") new];
    identity[@"unified"] = [NSClassFromString(@"ProbeOriginalUnified") new];
    NSString *body = CampusOriginalProbeTestLoginBody(identity, code);
    NSCAssert(body && ![body containsString:@"OLD_ACCOUNT"] && ![body containsString:@"OLD_COOKIE"], @"原模型构造失败或旧会话进入登录正文");
    NSDictionary *outer = LoginTestObject(body);
    NSCAssert([outer[@"snsLoginInfo"] isKindOfClass:NSString.class] && [outer[@"riskControlInfo"] isKindOfClass:NSString.class], @"外层登录字段未保持 JSON 字符串");
    NSDictionary *info = LoginTestObject(outer[@"snsLoginInfo"]);
    NSDictionary *risk = LoginTestObject(outer[@"riskControlInfo"]);
    NSCAssert([info[@"useAcitonType"] isEqual:@YES] && [info[@"useDeviceToken"] isEqual:@YES] &&
        [info[@"site"] isEqual:@"96"] && [risk[@"t"] length] == 13, @"原 iOS 开关对象、site 字符串或时间契约改变");
    NSMutableDictionary *wrong = [info mutableCopy]; wrong[@"deviceId"] = @"OLD_DEVICE";
    NSCAssert(CampusOriginalLoginBody(wrong, risk, identity, code) == nil, @"登录正文与本次注册 ID 不一致未阻断");
    NSCAssert(CampusOriginalLoginBody(info, risk, identity, @"short") == nil, @"无效授权码未在构造前阻断");
    NSString *(^encode)(NSString *) = ^NSString *(NSString *value) { return [value stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]]; };
    NSDictionary *factors = @{@"x-sign": @"SECRET_SIGN", @"x-mini-wua": @"SECRET_MINI", @"x-umt": @"SECRET_UMT", @"x-sgext": @"SECRET_SGEXT"};
    NSDictionary *session = @{@"sid": @"SECRET_SID+/=", @"uid": @"123456"};
    NSDictionary *listedDevice = @{@"resNo": @"TEST_DEVICE", @"deviceId": @"12345"};
    NSDictionary *listedOrder = @{@"bizOrderId": @"123", @"mixBuyerId": @"456", @"isvOrderId": @"789"};
    NSArray *bodies = @[body, @"{\"platForm\":\"ios\"}",
        CampusOriginalReadBody(CampusOriginalPurposeOrders, nil),
        CampusOriginalReadBody(CampusOriginalPurposeHistory, nil),
        CampusOriginalReadBody(CampusOriginalPurposeBuildings, nil),
        CampusOriginalReadBody(CampusOriginalPurposeDevices, nil),
        CampusOriginalReadBody(CampusOriginalPurposeDeviceInfo, listedDevice),
        CampusOriginalReadBody(CampusOriginalPurposeOrderDetail, listedOrder)];
    for (NSUInteger i = 0; i < bodies.count; i++) {
        CampusOriginalPurpose purpose = (CampusOriginalPurpose)(CampusOriginalPurposeLogin + i);
        NSString *reason = nil;
        NSURLRequest *request = CampusOriginalAccountRequest(identity, @"1800000000", bodies[i], factors, i ? session : nil, purpose, encode, &reason);
        NSCAssert(request && CampusOriginalAccountRequestInScope(request, purpose) && [request.HTTPMethod isEqual:@"POST"], @"合法本人登录/只读 POST 构造失败");
        NSURLRequest *signedRequest = CampusOriginalProbeTestAccountRequest(identity, bodies[i], i ? session : nil, purpose);
        NSCAssert(signedRequest != nil, @"原签名流程不能构造账号阶段 POST");
        NSArray *fields = [CampusOriginalProbeTestLastInput() componentsSeparatedByString:@"&"];
        NSCAssert(fields.count == 22 && [fields[10] isEqual:deviceID] &&
            [fields[1] isEqual:(i ? session[@"uid"] : @"")] && [fields[8] isEqual:(i ? session[@"sid"] : @"")], @"新会话未进入原 iOS 22 字段签名串");
        NSData *raw = [bodies[i] dataUsingEncoding:NSUTF8StringEncoding]; unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_MD5(raw.bytes, (CC_LONG)raw.length, digest);
#pragma clang diagnostic pop
        NSMutableString *md5 = [NSMutableString string];
        for (NSUInteger byte = 0; byte < sizeof(digest); byte++) [md5 appendFormat:@"%02x", digest[byte]];
        NSCAssert([fields[4] isEqual:md5], @"账号阶段正文与签名 MD5 来源不一致");
        NSString *form = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        NSCAssert([[[form substringFromIndex:5] stringByRemovingPercentEncoding] isEqual:bodies[i]], @"POST 正文改变或多编码");
        NSCAssert(!CampusOriginalDeviceRequestInScope(request, CampusOriginalPurposeReuse), @"账号请求混入匿名范围");
        if (i) NSCAssert([[[request valueForHTTPHeaderField:@"x-sid"] stringByRemovingPercentEncoding] isEqual:session[@"sid"]], @"会话编码回读失败");
        for (NSUInteger mutation = 0; mutation < 4; mutation++) {
            NSMutableURLRequest *bad = [request mutableCopy];
            if (mutation == 0) [bad setValue:@"old-account" forHTTPHeaderField:@"Cookie"];
            if (mutation == 1) bad.HTTPMethod = @"GET";
            if (mutation == 2) bad.URL = [NSURL URLWithString:@"https://example.invalid/gw/api/1.0/"];
            if (mutation == 3) { if (i) [bad setValue:nil forHTTPHeaderField:@"x-sid"]; else [bad setValue:@"OLD_SID" forHTTPHeaderField:@"x-sid"]; }
            NSCAssert(!CampusOriginalAccountRequestInScope(bad, purpose), @"账号请求范围拒绝错误被过期时间测试掩盖");
            __block BOOL rejected = NO;
            CampusOriginalAccountSend(bad, purpose, ^(NSDictionary *outcome, NSDictionary *evidence) {
                rejected = ![outcome[@"success"] boolValue] && !evidence && [outcome[@"summary"] containsString:@"未发送"];
            });
            NSCAssert(rejected, @"账号请求越界或会话不完整未在建连前拒绝");
        }
    }
    NSDictionary *loginEvidence = CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"returnValue": @{@"sid": @"SID", @"hid": @"123"}}}), CampusOriginalPurposeLogin);
    NSCAssert([loginEvidence[@"sid"] isEqual:@"SID"] && [loginEvidence[@"uid"] isEqual:@"123"], @"会话字段映射错误");
    NSDictionary *numericID = CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"returnValue": @{@"sid": @"SID", @"hid": @123}}}), CampusOriginalPurposeLogin);
    NSCAssert([numericID[@"uid"] isEqual:@"123"], @"数值 hid 未转换为签名使用的原始文本");
    NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"returnValue": @{@"sid": @"SID", @"hid": @YES}}}), CampusOriginalPurposeLogin) == nil,
        @"布尔值误当作账号 ID");
    NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"returnValue": @{}}}), CampusOriginalPurposeLogin) == nil, @"业务码成功但会话空被接受");
    NSDictionary *profile = CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"phone": @"SECRET_PHONE"}}), CampusOriginalPurposeProfile);
    NSCAssert([profile[@"verified"] boolValue] && ![profile.description containsString:@"SECRET"], @"本人资料未脱敏");
    NSDictionary *orders = CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @NO, @"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders);
    NSCAssert([orders[@"count"] isEqual:@0] && [orders[@"verified"] boolValue], @"成功的空运行列表误判失败");
    NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @YES, @"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders) == nil &&
        CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders) == nil,
        @"业务失败或缺少业务状态被误判为空订单");
    NSDictionary *stringFalse = CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @"false", @"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders);
    NSCAssert([stringFalse[@"verified"] boolValue] && [stringFalse[@"count"] isEqual:@0], @"安卓可解析的字符串 false 被拒绝");
    for (id invalid in @[@"true", @"unknown", NSNull.null, @2]) {
        NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": invalid, @"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders) == nil, @"失败、未知或 null 状态误判成功");
    }
    NSString *shape = CampusOriginalAccountShape(LoginTestData(@{@"data": @{@"fail": @"false", @"data": @{@"secret": @"SECRET_RESPONSE_BODY"}}}), CampusOriginalPurposeOrders);
    NSCAssert([shape containsString:@"字符串 false"] && [shape containsString:@"urgentOrderListResponse=缺失"] && ![shape containsString:@"SECRET"], @"结构诊断未区分缺字段或泄露业务正文");
    NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @"false", @"data": @{}}}), CampusOriginalPurposeOrders) == nil, @"缺失订单列表被误判为空数组");
    NSCAssert([CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @"FALSE", @"data": @{@"orderListResponses": @[]}}}), CampusOriginalPurposeHistory)[@"count"] isEqual:@0], @"历史空数组或布尔字符串不兼容");
    NSCAssert([CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @NO, @"data": @[]}}), CampusOriginalPurposeBuildings)[@"count"] isEqual:@0], @"楼栋空数组不兼容");
    NSDictionary *page = @{@"data": @{@"pageResult": @{@"success": @"true", @"data": @[@{@"deviceCode": @"TEST_DEVICE", @"deviceId": @12345, @"deviceName": @"SECRET_NAME"}]}}};
    NSDictionary *deviceEvidence = CampusOriginalAccountEvidence(LoginTestData(page), CampusOriginalPurposeDevices);
    NSCAssert([deviceEvidence[@"count"] isEqual:@1] && [deviceEvidence[@"device"] isEqual:listedDevice] && ![deviceEvidence.description containsString:@"SECRET"], @"列表设备筛选或脱敏未通过");
    NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"pageResult": @{@"success": @NO, @"data": @[]}}}), CampusOriginalPurposeDevices) == nil, @"失败的分页被接受");
    NSDictionary *detail = @{@"data": @{@"fail": @"false", @"data": @{@"deviceResponse": @{@"deviceCode": @"TEST_DEVICE", @"deviceId": @"12345", @"deviceCanUse": @"true",
        @"deviceWorkingModelDTOS": @[@{@"isSupport": @YES, @"priceModelList": @[@{@"key": @"TEST_PROGRAM", @"isOpen": @"true", @"price": @"SECRET_PRICE"}, @{@"key": @"CLOSED", @"isOpen": @NO}]}]}}}};
    NSDictionary *detailEvidence = CampusOriginalAccountEvidence(LoginTestData(detail), CampusOriginalPurposeDeviceInfo);
    NSCAssert([detailEvidence[@"programs"] isEqual:@1] && [detailEvidence[@"canUse"] boolValue] && ![detailEvidence.description containsString:@"SECRET"], @"开放洗衣程序统计或脱敏未通过");
    NSCAssert(CampusOriginalReadBody(CampusOriginalPurposeDeviceInfo, nil) == nil, @"没有列表设备仍构造详情");
    NSDictionary *history = LoginTestObject(bodies[3]);
    NSDictionary *query = LoginTestObject(history[@"requestJson"]);
    NSCAssert([query[@"pageNum"] isEqual:@1] && [query[@"pageSize"] isEqual:@10] && [query[@"isQueryToPayOrderList"] isEqual:@NO], @"只读历史范围扩大到额外分页或待支付查询");
    NSMutableDictionary *wrongDetail = [listedDevice mutableCopy]; wrongDetail[@"resNo"] = @"invalid&identifier";
    NSCAssert(CampusOriginalReadBody(CampusOriginalPurposeDeviceInfo, wrongDetail) == nil, @"无效列表设备未阻断");

    for (CampusOriginalPurpose purpose = CampusOriginalPurposeHistory; purpose <= CampusOriginalPurposeOrderDetail; purpose++) {
        // 订单详情需要订单身份，不能复用设备编号 fixture。
        NSDictionary *selection = purpose == CampusOriginalPurposeOrderDetail ? listedOrder : listedDevice;
        NSString *valid = CampusOriginalReadBody(purpose, selection);
        NSMutableDictionary *envelope = [LoginTestObject(valid) mutableCopy];
        NSMutableDictionary *payload = [LoginTestObject(envelope[@"requestJson"]) mutableCopy];
        if (purpose == CampusOriginalPurposeHistory || purpose == CampusOriginalPurposeDevices) payload[@"pageNum"] = @2;
        else if (purpose == CampusOriginalPurposeDeviceInfo) payload[@"needAutoSendCoupon"] = @YES;
        else payload[@"businessType"] = @"OTHER_BUSINESS";
        envelope[@"requestJson"] = [[NSString alloc] initWithData:LoginTestData(payload) encoding:NSUTF8StringEncoding];
        NSString *badBody = [[NSString alloc] initWithData:LoginTestData(envelope) encoding:NSUTF8StringEncoding];
        NSCAssert(CampusOriginalAccountRequest(identity, @"1800000000", badBody, factors, session, purpose, encode, nil) == nil,
            @"额外分页、其它业务或自动领券突破只读范围");
        envelope[@"requestType"] = @"CREATE_ORDER";
        badBody = [[NSString alloc] initWithData:LoginTestData(envelope) encoding:NSUTF8StringEncoding];
        NSCAssert(CampusOriginalAccountRequest(identity, @"1800000000", badBody, factors, session, purpose, encode, nil) == nil, @"创建请求混入只读范围");
    }

    NSDictionary *manualDevice = @{@"resNo": @"TEST_DEVICE"};
    NSString *manualBody = CampusOriginalReadBody(CampusOriginalPurposeDeviceInfo, manualDevice);
    NSDictionary *manualEnvelope = LoginTestObject(manualBody);
    NSDictionary *manualQuery = LoginTestObject(manualEnvelope[@"requestJson"]);
    NSCAssert([manualQuery[@"resNo"] isEqual:@"TEST_DEVICE"] && !manualQuery[@"deviceId"] && [manualQuery[@"needAutoSendCoupon"] isEqual:@NO], @"手填机器编号不能直查或自动领券未关闭");
    NSCAssert(CampusOriginalProbeTestAccountRequest(identity, manualBody, session, CampusOriginalPurposeDeviceInfo) != nil, @"手填机器编号未通过签名/发送核对");
    NSData *historyWithOrder = LoginTestData(@{@"data": @{@"fail": @NO, @"data": @{@"orderListResponses": @[
        @{@"bizOrderIdStr": @123, @"mixBuyerId": @"456", @"isvOrderId": @"789", @"deviceName": @"SECRET_DEVICE_NAME"}]}}});
    NSDictionary *historyEvidence = CampusOriginalAccountEvidence(historyWithOrder, CampusOriginalPurposeHistory);
    NSDictionary *selectedOrder = historyEvidence[@"order"];
    NSCAssert([selectedOrder isEqual:(@{@"bizOrderId": @"123", @"mixBuyerId": @"456", @"isvOrderId": @"789"})] && ![historyEvidence.description containsString:@"SECRET"], @"历史订单身份转换或最小字段选择错误");
    NSCAssert(CampusOriginalReadBody(CampusOriginalPurposeOrderDetail, selectedOrder) != nil && CampusOriginalReadBody(CampusOriginalPurposeOrderDetail, @{@"bizOrderId": @"123"}) == nil, @"详情缺少列表身份未阻断");
    NSDictionary *orderEvidence = CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @"false", @"data": @{@"response":
        @{@"bizOrderIdStr": @123, @"payStatus": @"SUCCEED", @"fulfilStatus": @"COMPLETED", @"address": @"SECRET_ADDRESS"}}}}), CampusOriginalPurposeOrderDetail);
    NSCAssert([orderEvidence[@"verified"] boolValue] && [orderEvidence[@"bizOrderId"] isEqual:@"123"] && ![orderEvidence.description containsString:@"SECRET"], @"订单详情身份或脱敏不正确");
    NSCAssert(CampusOriginalAccountEvidence(LoginTestData(@{@"data": @{@"fail": @NO, @"data": @{@"response": @{@"bizOrderId": @"123"}}}}), CampusOriginalPurposeOrderDetail) == nil, @"缺少支付/履约字段的详情被接受");

    NSString *qr = @"https://share.confong.cn/cf?biz=wash&isv=CAMPUS&id=TEST_DEVICE";
    NSCAssert([CampusOriginalMachineNumber(qr) isEqual:@"TEST_DEVICE"] && [CampusOriginalMachineNumber(@"  TEST_DEVICE  ") isEqual:@"TEST_DEVICE"], @"机器编号或官方二维码识别失败");
    NSURLComponents *wrapped = [NSURLComponents componentsWithString:@"https://share.confong.cn/app/tmall-xiaoyuan/tmxy-m-share/laundry/deviceDetail"];
    wrapped.queryItems = @[[NSURLQueryItem queryItemWithName:@"result" value:qr]];
    NSCAssert([CampusOriginalMachineNumber(wrapped.URL.absoluteString) isEqual:@"TEST_DEVICE"], @"官方嵌套二维码识别失败");
    for (NSString *invalid in @[@"http://share.confong.cn/cf?biz=x&isv=y&id=TEST_DEVICE", @"https://share.confong.cn.attacker.invalid/cf?biz=x&isv=y&id=TEST_DEVICE", @"https://user@share.confong.cn/cf?biz=x&isv=y&id=TEST_DEVICE", @"https://share.confong.cn/cf?biz=x&isv=y&id=A&id=B", @"https://share.confong.cn/cf?id=A", @"https://share.confong.cn:444/cf?biz=x&isv=y&id=A"]) {
        NSCAssert(CampusOriginalMachineNumber(invalid) == nil, @"不合格二维码目的地或歧义编号被接受");
    }
    NSArray *emptyDisplay = CampusOriginalReadDisplay(LoginTestData(@{@"data": @{@"fail": @"false", @"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders);
    NSCAssert(emptyDisplay.count == 1 && [emptyDisplay[0][@"detail"] isEqual:@"本次查询暂无记录"], @"正常空运行列表未显示清晰文案");
    NSCAssert(CampusOriginalReadDisplay(LoginTestData(@{@"data": @{@"fail": @YES, @"data": @{@"urgentOrderListResponse": @[]}}}), CampusOriginalPurposeOrders).count == 0, @"失败响应被展示为空订单");
    NSDictionary *displayBody = @{@"data": @{@"fail": @NO, @"data": @{@"deviceResponse": @{@"deviceCode": @"TEST_DEVICE", @"deviceId": @"12345", @"deviceCanUse": @YES,
        @"deviceName": @"测试洗衣机", @"buildingName": @"测试楼栋", @"floorName": @"2 层", @"sid": @"SECRET_SESSION",
        @"deviceWorkingModelDTOS": @[@{@"isSupport": @YES, @"priceModelList": @[@{@"key": @"PROGRAM", @"isOpen": @YES, @"price": @390, @"priceYuan": @"3.90", @"desc": @"标准洗", @"defaultDetails": @"约 40 分钟"}]}]}}}};
    NSArray *display = CampusOriginalReadDisplay(LoginTestData(displayBody), CampusOriginalPurposeDeviceInfo);
    NSCAssert(display.count == 2 && [display[1][@"detail"] containsString:@"3.90 元"] && ![display.description containsString:@"SECRET"] && ![display.description containsString:@"12345"], @"设备显示未保持明确元价格或泄露会话/内部 ID");
    NSMutableDictionary *invalidPrice = [displayBody[@"data"][@"data"][@"deviceResponse"] mutableCopy];
    invalidPrice[@"deviceWorkingModelDTOS"] = @[@{@"isSupport": @YES, @"priceModelList": @[@{@"key": @"PROGRAM", @"isOpen": @YES, @"price": @390}]}];
    NSArray *withoutYuan = CampusOriginalReadDisplay(LoginTestData(@{@"data": @{@"fail": @NO, @"data": @{@"deviceResponse": invalidPrice}}}), CampusOriginalPurposeDeviceInfo);
    NSCAssert([withoutYuan[1][@"detail"] containsString:@"标示价格未提供"], @"单位未经确认的原始价格被推算为元");

}
