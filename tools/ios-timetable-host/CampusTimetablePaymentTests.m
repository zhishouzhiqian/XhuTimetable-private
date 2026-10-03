#import "CampusTimetablePaymentFixtures.h"
// 桩网络与内存存储验证业务顺序；不调用真实 SDK、Keychain 或业务服务。
static NSDictionary *Run(CampusTimetablePayment *payment, NSString *action, NSDictionary *input, NSString *owner) {
    __block NSDictionary *response;
    [payment perform:action input:input owner:owner completion:^(id value, NSString *error) {
        NSCAssert(response == nil, @"付款操作重复回调");
        response = @{@"result": value ?: NSNull.null, @"error": error ?: NSNull.null};
    }];
    NSCAssert(response != nil, @"桩付款操作未回调");
    return response;
}
static void Expect(NSDictionary *response, NSString *error) {
    NSCAssert(error ? [response[@"error"] isEqual:error] : response[@"error"] == NSNull.null, @"付款状态机结果不符");
}
int main(void) {
    @autoreleasepool {
        __block NSDictionary *saved = @{};
        __block BOOL storageFails = NO, creationTimesOut = NO, changedPrice = NO, historyHasOrder = YES;
        __block NSString *status = @"INIT";
        __block NSUInteger creates = 0, sequences = 0, clears = 0;
        __block NSUInteger checkouts = 0, methods = 0;
        __block NSNumber *orderNumber = @123;
        NSMutableArray *dismissed = [NSMutableArray array];
        CampusPaymentQuery query = ^(CampusOriginalPurpose purpose, NSDictionary *input, CampusPaymentCompletion done) {
            if (purpose == CampusOriginalPurposeDeviceInfo) { done(PaymentDevice(), nil); return; }
            if (purpose == CampusOriginalPurposeRender) {
                NSMutableDictionary *quote = [PaymentQuote() mutableCopy];
                if (changedPrice) { quote[@"discountAmount"] = @0; quote[@"actualPayAmount"] = @400; }
                done(@{@"response": quote}, nil); return;
            }
            if (purpose == CampusOriginalPurposeSequence) { sequences++; done(@{@"data": @{@"response": orderNumber}}, nil); return; }
            if (purpose == CampusOriginalPurposeCreate) {
                NSCAssert(saved.count && !saved[@"checkoutId"], @"未持久化意图就创建");
                creates++;
                if (creationTimesOut) { done(nil, @"网络失败"); return; }
                done(@{@"orderParamDto": @{@"createFailed": @NO, @"businessType": @"WASH_AND_CARE", @"isvOrderId": orderNumber,
                    @"isvResNo": @"M1", @"paymentAmount": @300, @"checkoutId": @88}}, nil); return;
            }
            if (purpose == CampusOriginalPurposeCheckout) { checkouts++; done(PaymentCheckout(status), nil); return; }
            if (purpose == CampusOriginalPurposePaymethod) { methods++; done(@{@"cashierPayMethodList": PaymentMethods()}, nil); return; }
            if (purpose == CampusOriginalPurposeHistory) {
                done(@{@"data": @{@"orderListResponses": historyHasOrder ? @[@{@"bizOrderIdStr": @"456", @"isvOrderId": @123, @"mixBuyerId": @"789"}] : @[]}}, nil); return;
            }
            if (purpose == CampusOriginalPurposeOrderDetail) {
                done(@{@"data": @{@"response": @{@"bizOrderIdStr": @"456", @"isvOrderId": @123, @"isvResNo": @"M1", @"paymentAmount": @300, @"checkoutId": @88}}}, nil); return;
            }
            NSCAssert(NO, @"付款桩收到未列举请求");
        };
        CampusTimetablePayment *(^newEngine)(void) = ^CampusTimetablePayment *{
            return [[CampusTimetablePayment alloc] initWithQuery:query load:^NSDictionary *{ return saved; }
                save:^(NSDictionary *intent) {
                    if (storageFails) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
                    if (saved.count && !intent[@"checkoutId"]) CampusPaymentFail(@"PAYMENT_PENDING");
                    saved = [intent copy];
                } clear:^{ saved = @{}; clears++; } dismiss:^(NSDictionary *intent) {
                    if (storageFails) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
                    NSCAssert([saved isEqual:intent] && intent[@"checkoutId"], @"退出了不同或身份不明的订单");
                    [dismissed addObject:[intent copy]]; saved = @{};
                }];
        };
        NSDictionary *preview = @{@"resNo": @"M1", @"key": @"standard"}, *confirm = @{@"amount": @"3.00"};
        CampusTimetablePayment *engine = newEngine();
        Expect(Run(engine, @"preview", preview, @"owner-a"), nil);
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), nil);
        NSCAssert(creates == 1 && sequences == 1 && saved[@"checkoutId"], @"完整创建流程顺序错误");
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), @"PAYMENT_PENDING");
        NSCAssert(creates == 1, @"重复点击重新创建");
        Expect(Run(engine, @"paymentCheckout", @{}, @"owner-a"), nil);
        NSDictionary *wechat = Run(engine, @"wechatPayment", @{}, @"owner-a"); Expect(wechat, nil);
        NSCAssert([wechat[@"result"][@"uri"] hasPrefix:@"weixin://dl/business/"], @"微信入口未生成");
        Expect(Run(engine, @"acknowledgePayment", @{}, @"owner-a"), @"PAYMENT_PENDING");
        status = @"PAYING";
        Expect(Run(engine, @"wechatPayment", @{}, @"owner-a"), @"PAYMENT_NOT_INIT");
        Expect(Run(engine, @"acknowledgePayment", @{}, @"owner-a"), @"PAYMENT_PENDING");
        NSCAssert(saved.count && clears == 0, @"非终态清除了意图");
        Expect(Run(newEngine(), @"pendingPayment", @{}, @"owner-b"), @"PAYMENT_ACCOUNT_MISMATCH");
        status = @"SUCCESS";
        Expect(Run(newEngine(), @"acknowledgePayment", @{}, @"owner-a"), nil);
        NSCAssert(!saved.count && clears == 1, @"新实例终态核验未清理");

        engine = newEngine(); changedPrice = NO; status = @"INIT";
        Expect(Run(engine, @"preview", preview, @"owner-a"), nil); changedPrice = YES;
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), @"PRICE_CHANGED");
        NSCAssert(creates == 1 && sequences == 1 && !saved.count, @"金额变化后继续创建");
        changedPrice = NO; storageFails = YES;
        Expect(Run(engine, @"preview", preview, @"owner-a"), nil);
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), @"PAYMENT_STORAGE_FAILED");
        NSCAssert(creates == 1 && !saved.count, @"存储失败仍创建");
        storageFails = NO; creationTimesOut = YES;
        Expect(Run(engine, @"preview", preview, @"owner-a"), nil);
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), @"CREATE_UNCERTAIN");
        NSCAssert(creates == 2 && saved.count && !saved[@"checkoutId"], @"超时意图未保留");
        engine = newEngine(); // 模拟被终止后的重新启动，只有加密意图，没有旧报价。
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), @"PAYMENT_PENDING");
        historyHasOrder = NO;
        Expect(Run(engine, @"paymentCheckout", @{}, @"owner-a"), @"CREATE_UNCERTAIN");
        Expect(Run(engine, @"dismissUnpaidPayment", @{@"reference": @"123"}, @"owner-a"), @"CREATE_UNCERTAIN");
        NSCAssert(dismissed.count == 0, @"创建不明时释放了付款槽位");
        NSCAssert(creates == 2 && saved.count && !saved[@"checkoutId"], @"恢复失败重建或清理了意图");
        historyHasOrder = YES;
        Expect(Run(engine, @"paymentCheckout", @{}, @"owner-a"), nil);
        NSCAssert([saved[@"checkoutId"] isEqual:@"88"] && creates == 2, @"没有按原订单恢复收银台");
        status = @"CLOSE";
        Expect(Run(engine, @"acknowledgePayment", @{}, @"owner-a"), nil);
        NSCAssert(!saved.count && clears == 2, @"关闭终态未清理");
        for (NSString *field in @[@"resNo", @"businessType", @"serviceItemDTOList"]) {
            CampusTimetablePayment *diagnostic = [[CampusTimetablePayment alloc] initWithQuery:^(CampusOriginalPurpose purpose, NSDictionary *selection, CampusPaymentCompletion done) {
                if (purpose == CampusOriginalPurposeDeviceInfo) { done(PaymentDevice(), nil); return; }
                NSCAssert(purpose == CampusOriginalPurposeRender, @"失败报价继续执行创建阶段");
                NSMutableDictionary *quote = [PaymentQuote() mutableCopy]; [quote removeObjectForKey:field];
                quote[@"privateField"] = @"private-response-value";
                done(@{@"response": quote}, nil);
            } load:^NSDictionary *{ return @{}; } save:^(NSDictionary *intent) { NSCAssert(NO, @"失败报价写入付款记录"); }
                clear:^{} dismiss:^(NSDictionary *intent) { NSCAssert(NO, @"失败报价退出付款记录"); }];
            NSString *error = Run(diagnostic, @"preview", preview, @"owner-a")[@"error"];
            NSCAssert([error hasPrefix:@"CAMPUS_PAYMENT_FAILED\n报价字段核对："] && [error containsString:field] && ![error containsString:@"private-response-value"], @"报价检查点丢失或泄漏原始响应");
        }
        creationTimesOut = NO; status = @"INIT"; engine = newEngine();
        Expect(Run(engine, @"preview", preview, @"owner-a"), nil);
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), nil);
        NSDictionary *original = saved;
        NSDictionary *closeInput = @{@"reference": @"123"};
        NSUInteger beforeCheckout = checkouts, beforeCreate = creates, beforeSequence = sequences, beforeMethods = methods;
        Expect(Run(engine, @"dismissUnpaidPayment", closeInput, @"owner-b"), @"PAYMENT_ACCOUNT_MISMATCH");
        Expect(Run(engine, @"dismissUnpaidPayment", @{@"reference": @"old-page"}, @"owner-a"), @"PAYMENT_MISMATCH");
        NSCAssert(checkouts == beforeCheckout && [saved isEqual:original], @"身份不一致仍查询或释放");
        for (NSString *nonUnpaid in @[@"PAYING", @"SUCCESS", @"CLOSE"]) {
            status = nonUnpaid;
            NSDictionary *kept = Run(engine, @"dismissUnpaidPayment", closeInput, @"owner-a"); Expect(kept, nil);
            NSCAssert([kept[@"result"][@"dismissed"] isEqual:@NO] && [saved isEqual:original] && !dismissed.count, @"非未支付状态被当成本地退出");
        }
        status = @"UNKNOWN";
        Expect(Run(engine, @"dismissUnpaidPayment", closeInput, @"owner-a"), @"PAYMENT_MISMATCH");
        NSCAssert([saved isEqual:original] && !dismissed.count, @"未知状态仍释放");
        status = @"INIT"; storageFails = YES;
        Expect(Run(engine, @"dismissUnpaidPayment", closeInput, @"owner-a"), @"PAYMENT_STORAGE_FAILED");
        NSCAssert([saved isEqual:original] && !dismissed.count, @"退出存储失败后丢失订单");
        storageFails = NO;
        NSDictionary *ended = Run(engine, @"dismissUnpaidPayment", closeInput, @"owner-a"); Expect(ended, nil);
        NSCAssert([ended[@"result"][@"dismissed"] isEqual:@YES] && !saved.count && [dismissed.firstObject isEqual:original], @"本地退出未保存原订单或释放槽位");
        NSCAssert(creates == beforeCreate && sequences == beforeSequence && methods == beforeMethods && clears == 2 && checkouts == beforeCheckout + 6,
            @"本地退出发起了创建、付款或终态清理，或未实时查询");
        orderNumber = @124;
        engine = newEngine();
        Expect(Run(engine, @"preview", preview, @"owner-a"), nil);
        Expect(Run(engine, @"createPayment", confirm, @"owner-a"), nil);
        NSCAssert([saved[@"isvOrderId"] isEqual:@"124"] && creates == beforeCreate + 1, @"本地退出后新订单未使用新身份");
        Expect(Run(engine, @"dismissUnpaidPayment", closeInput, @"owner-a"), @"PAYMENT_MISMATCH");
        NSCAssert([saved[@"isvOrderId"] isEqual:@"124"] && dismissed.count == 1, @"旧页面退出覆盖了新订单");
        puts("付款状态机测试通过：完整流程、超时恢复、终态核验、未支付本地退出、存储失败保留、旧订单隔离；未真实下单。");
    }
    return 0;
}
