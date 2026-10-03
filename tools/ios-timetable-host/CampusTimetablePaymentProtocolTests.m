#import "CampusTimetablePaymentFixtures.h"
static NSData *Data(id value) { return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; }
static void CheckProgramContract(NSString *key, NSDictionary *identity, NSDictionary *factors, NSString *(^encode)(NSString *)) {
    // 与真机报告一致：价格、校区和布尔标记均可由服务端以字符串返回。
    NSMutableDictionary *payload = [NSJSONSerialization JSONObjectWithData:Data(PaymentDevice()) options:NSJSONReadingMutableContainers error:nil];
    NSMutableDictionary *device = payload[@"data"][@"deviceResponse"];
    NSMutableDictionary *mode = device[@"deviceWorkingModelDTOS"][0], *price = mode[@"priceModelList"][0];
    device[@"campusAreaId"] = @"7"; device[@"deviceCanUse"] = @"true";
    mode[@"isSupport"] = @"true"; price[@"isOpen"] = @"true"; price[@"price"] = @"400"; price[@"key"] = key;
    NSDictionary *input = CampusPaymentRenderInput(payload, @"M1", key);
    NSMutableDictionary *quote = [PaymentQuote() mutableCopy];
    quote[@"serviceItemDTOList"] = @[@{@"serviceItemId": key, @"serviceItemName": @"标准洗"}];
    NSCAssert([CampusPaymentQuote(input, quote)[@"pay"] isEqual:@"3.00"], @"包含标点的程序报价被拒绝");
    NSMutableDictionary *wrong = [quote mutableCopy]; wrong[@"serviceItemDTOList"] = @[@{@"serviceItemId": [key stringByAppendingString:@"-other"]}];
    RejectPayment(^{ CampusPaymentQuote(input, wrong); }, @"QUOTE_MISMATCH");
    for (NSNumber *number in @[@(CampusOriginalPurposeRender), @(CampusOriginalPurposeCreate)]) {
        CampusOriginalPurpose purpose = number.integerValue;
        NSDictionary *selection = purpose == CampusOriginalPurposeRender ? input : CampusPaymentCreateInput(input, quote, @123);
        NSString *body = CampusPaymentBody(purpose, selection), *reason = nil;
        NSCAssert(body != nil, @"包含标点的程序正文未生成");
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSDictionary *inner = [NSJSONSerialization JSONObjectWithData:[envelope[@"requestJson"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSCAssert([inner[@"serviceItemDTOList"][0][@"serviceItemId"] isEqual:key], @"程序标识被修改或截断");
        NSURLRequest *request = CampusOriginalAccountRequest(identity, @"1234567890", body, factors, @{@"sid": @"test-session", @"uid": @"123"}, purpose, encode, &reason);
        NSCAssert(request && CampusOriginalAccountRequestInScope(request, purpose), @"程序标识 POST 契约失败：%@", reason);
        NSString *form = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        NSCAssert([[[form substringFromIndex:5] stringByRemovingPercentEncoding] isEqual:body], @"程序标识编码改变签名正文");
    }
}
int main(void) {
    @autoreleasepool {
        for (id invalid in @[@YES, @-1, @"1.1", @"9223372036854775808", @"", @"1e3", NSNull.null])
            RejectPayment(^{ CampusPaymentCents(invalid); }, @"QUOTE_AMOUNT_INVALID");
        NSCAssert(CampusPaymentCents(@"9223372036854775807") == LLONG_MAX, @"金额整数上限解析失败");
        NSCAssert([CampusPaymentYuan(300) isEqual:@"3.00"], @"分转元错误");
        NSDictionary *input = CampusPaymentRenderInput(PaymentDevice(), @"M1", @"standard"), *quote = PaymentQuote();
        NSCAssert([CampusPaymentQuote(input, quote)[@"pay"] isEqual:@"3.00"], @"报价计算错误");
        NSMutableDictionary *bad = [quote mutableCopy]; bad[@"actualPayAmount"] = @301;
        RejectPayment(^{ CampusPaymentQuote(input, bad); }, @"QUOTE_AMOUNT_INVALID");
        bad = [quote mutableCopy]; bad[@"resNo"] = @"M2";
        RejectPayment(^{ CampusPaymentQuote(input, bad); }, @"QUOTE_MISMATCH");
        NSMutableDictionary *wallet = [quote mutableCopy]; wallet[@"onlyWalletPay"] = @YES;
        RejectPayment(^{ CampusPaymentCreateInput(input, wallet, @123); }, @"WECHAT_CHANNEL_UNAVAILABLE");
        NSMutableDictionary *noAttr = [PaymentDevice()[@"data"][@"deviceResponse"] mutableCopy];
        NSMutableDictionary *mode = [noAttr[@"deviceWorkingModelDTOS"][0] mutableCopy]; [mode removeObjectForKey:@"attrName"];
        noAttr[@"deviceWorkingModelDTOS"] = @[mode];
        NSDictionary *optionalAttr = CampusPaymentRenderInput(@{@"data": @{@"deviceResponse": noAttr}}, @"M1", @"standard");
        NSCAssert([optionalAttr[@"serviceItemDTOList"][0][@"attrName"] isEqual:@""], @"可省略属性名没有对齐安卓");
        noAttr[@"deviceCanUse"] = @NO;
        RejectPayment(^{ CampusPaymentRenderInput(@{@"data": @{@"deviceResponse": noAttr}}, @"M1", @"standard"); }, @"DEVICE_UNAVAILABLE");
        NSDictionary *create = CampusPaymentCreateInput(input, quote, @123);
        NSCAssert(CampusPaymentBody(CampusOriginalPurposeCreate, create) != nil, @"固定创建正文被拒绝");
        NSMutableDictionary *extra = [create mutableCopy]; extra[@"url"] = @"https://example.invalid/";
        NSCAssert(CampusPaymentBody(CampusOriginalPurposeCreate, extra) == nil, @"任意创建字段进入请求");
        NSDictionary *created = @{@"createFailed": @NO, @"businessType": @"WASH_AND_CARE", @"isvOrderId": @123,
            @"isvResNo": @"M1", @"paymentAmount": @300, @"checkoutId": @88};
        NSCAssert([CampusPaymentCreated(create, created) isEqual:@"88"], @"创建订单对照失败");
        NSMutableDictionary *wrong = [created mutableCopy]; wrong[@"paymentAmount"] = @400;
        RejectPayment(^{ CampusPaymentCreated(create, wrong); }, @"PAYMENT_MISMATCH");
        NSDictionary *pending = @{@"checkoutId": @"88", @"amount": @300};
        for (NSString *status in @[@"INIT", @"PAYING", @"SUCCESS", @"CLOSE"])
            NSCAssert([CampusPaymentCheckout(pending, PaymentCheckout(status)) isEqual:status], @"服务器状态映射错误");
        RejectPayment(^{ CampusPaymentCheckout(pending, PaymentCheckout(@"UNKNOWN")); }, @"PAYMENT_MISMATCH");
        NSMutableDictionary *otherCheckout = [PaymentCheckout(@"SUCCESS") mutableCopy]; otherCheckout[@"checkoutId"] = @"89";
        RejectPayment(^{ CampusPaymentCheckout(pending, otherCheckout); }, @"PAYMENT_MISMATCH");
        otherCheckout = [PaymentCheckout(@"SUCCESS") mutableCopy]; otherCheckout[@"orderAmount"] = @299;
        RejectPayment(^{ CampusPaymentCheckout(pending, otherCheckout); }, @"PAYMENT_MISMATCH");
        NSString *uri = CampusPaymentWechat(pending, PaymentCheckout(@"INIT"), PaymentMethods());
        NSURLComponents *components = [NSURLComponents componentsWithString:uri];
        NSCAssert([components.scheme isEqual:@"weixin"] && [components.host isEqual:@"dl"], @"微信目的错误");
        NSString *query = nil;
        for (NSURLQueryItem *item in components.queryItems) if ([item.name isEqual:@"query"]) query = item.value;
        NSURLComponents *inner = [NSURLComponents componentsWithString:[@"https://example.invalid/?" stringByAppendingString:query]];
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in inner.queryItems) values[item.name] = item.value;
        NSCAssert([values[@"bizOrderId"] isEqual:@"88"] && [values[@"amount"] isEqual:@"300"] && [values[@"payTool"] isEqual:@"微信支付"], @"微信嵌套编码或收银台身份不一致");
        RejectPayment(^{ CampusPaymentWechat(pending, PaymentCheckout(@"SUCCESS"), PaymentMethods()); }, @"PAYMENT_NOT_INIT");
        RejectPayment(^{ CampusPaymentWechat(pending, PaymentCheckout(@"INIT"), @[]); }, @"WECHAT_CHANNEL_UNAVAILABLE");
        // 真实固定 POST 构造与发送前白名单检查，不调用 SDK、不发送网络。
        NSDictionary *identity = @{@"x-appkey": @"test-key", @"x-utdid": @"YWJjZGVmZ2hpamtsbW5vcHFy", @"x-ttid": @"test@campus_iPhone_5.7.2", @"deviceID": @"test-device"};
        NSDictionary *factors = @{@"x-sign": @"test/sign+", @"x-mini-wua": @"test-wua", @"x-umt": @"test-umt", @"x-sgext": @"test-ext"};
        NSString *(^encode)(NSString *) = ^NSString *(NSString *text) {
            return [text stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
        };
        for (NSString *key in @[@"mode.with.dot", @"mode:with/slash", @"mode+percent%=\"quoted\"", @"程序 标识"])
            CheckProgramContract(key, identity, factors, encode);
        for (id invalid in @[@"", @"bad\nkey", @"bad&key", @YES, @123, NSNull.null, [@"x" stringByPaddingToLength:129 withString:@"x" startingAtIndex:0]])
            NSCAssert(CampusPaymentProgramIdentifier(invalid) == nil, @"非法程序标识被接受");
        NSCAssert(CampusPaymentIdentifier(@"order.with.dot") == nil, @"程序标识修复放宽了订单编号契约");
        for (NSNumber *number in @[@(CampusOriginalPurposeRender), @(CampusOriginalPurposeSequence), @(CampusOriginalPurposeCreate), @(CampusOriginalPurposeCheckout), @(CampusOriginalPurposePaymethod)]) {
            CampusOriginalPurpose purpose = number.integerValue;
            NSDictionary *selection = purpose == CampusOriginalPurposeRender ? input : purpose == CampusOriginalPurposeCreate ? create :
                purpose == CampusOriginalPurposeSequence ? @{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE", @"sequenceType": @"ORDER_CREATE_OUT_ID_SEQUENCE"} :
                purpose == CampusOriginalPurposeCheckout ? @{@"checkoutId": @"88"} : @{@"checkoutId": @"88", @"extraAttr": @"{\"bizOrderId\":\"88\"}"};
            NSString *body = CampusPaymentBody(purpose, selection);
            NSCAssert(body != nil, @"测试前置条件：付款正文未生成");
            NSString *reason = nil;
            NSDictionary *session = @{@"sid": @"test-session", @"uid": @"123"};
            NSURLRequest *request = CampusOriginalAccountRequest(identity, @"1234567890", body, factors, session, purpose, encode, &reason);
            NSCAssert(request && CampusOriginalAccountRequestInScope(request, purpose), @"付款 POST 契约不通过：阶段 %@，原因 %@", number, reason);
            NSCAssert([[[[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] substringFromIndex:5].stringByRemovingPercentEncoding isEqual:body], @"付款正文编码变化");
            if (purpose <= CampusOriginalPurposeCreate) {
                // 固定排序与空白变化必须保持契约有效，且不能重建已准备的表单正文。
                NSMutableDictionary *envelope = [[NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] mutableCopy];
                NSData *sorted = [NSJSONSerialization dataWithJSONObject:selection options:NSJSONWritingSortedKeys error:nil];
                envelope[@"requestJson"] = [NSString stringWithFormat:@" %@ ", [[NSString alloc] initWithData:sorted encoding:NSUTF8StringEncoding]];
                NSString *reordered = [[NSString alloc] initWithData:Data(envelope) encoding:NSUTF8StringEncoding];
                NSURLRequest *equivalent = CampusOriginalAccountRequest(identity, @"1234567890", reordered, factors, session, purpose, encode, &reason);
                NSCAssert(equivalent && CampusOriginalAccountRequestInScope(equivalent, purpose), @"等价嵌套 JSON 被拒绝：%@，%@", number, reason);
                NSCAssert([[[[NSString alloc] initWithData:equivalent.HTTPBody encoding:NSUTF8StringEncoding] substringFromIndex:5].stringByRemovingPercentEncoding isEqual:reordered], @"等价正文被重建");
                envelope[@"extra"] = @"forbidden";
                NSString *invalid = [[NSString alloc] initWithData:Data(envelope) encoding:NSUTF8StringEncoding];
                NSCAssert(!CampusOriginalAccountRequest(identity, @"1234567890", invalid, factors, session, purpose, encode, NULL), @"付款接受额外外层字段");
                [envelope removeObjectForKey:@"extra"];
                NSString *type = envelope[@"requestType"]; envelope[@"requestType"] = @"UNKNOWN";
                invalid = [[NSString alloc] initWithData:Data(envelope) encoding:NSUTF8StringEncoding];
                NSCAssert(!CampusOriginalAccountRequest(identity, @"1234567890", invalid, factors, session, purpose, encode, NULL), @"付款接受错误请求类型");
                envelope[@"requestType"] = type;
                NSMutableDictionary *extraQuery = [selection mutableCopy]; extraQuery[@"extra"] = @"forbidden";
                envelope[@"requestJson"] = [[NSString alloc] initWithData:Data(extraQuery) encoding:NSUTF8StringEncoding];
                invalid = [[NSString alloc] initWithData:Data(envelope) encoding:NSUTF8StringEncoding];
                NSCAssert(!CampusOriginalAccountRequest(identity, @"1234567890", invalid, factors, session, purpose, encode, NULL), @"付款接受额外内层字段");
            }
            NSMutableURLRequest *foreign = [request mutableCopy]; foreign.URL = [NSURL URLWithString:@"https://example.invalid/"];
            NSCAssert(!CampusOriginalAccountRequestInScope(foreign, purpose), @"付款允许外部目的地");
            foreign = [request mutableCopy]; foreign.HTTPShouldHandleCookies = YES;
            NSCAssert(!CampusOriginalAccountRequestInScope(foreign, purpose), @"付款允许 Cookie");
            id response = purpose == CampusOriginalPurposeRender ? @{@"response": quote} : purpose == CampusOriginalPurposeSequence ? @{@"fail": @NO, @"data": @{@"response": @123}} :
                purpose == CampusOriginalPurposeCreate ? @{@"orderParamDto": created} : purpose == CampusOriginalPurposeCheckout ? PaymentCheckout(@"INIT") : @{@"cashierPayMethodList": PaymentMethods()};
            NSCAssert(CampusOriginalAccountEvidence(Data(@{@"data": response}), purpose) != nil, @"固定付款响应结构被拒绝");
        }
        puts("付款协议测试通过：整数金额、报价/订单身份、收银台、微信编码与固定 POST 范围；未下单或付款。");
    }
    return 0;
}
