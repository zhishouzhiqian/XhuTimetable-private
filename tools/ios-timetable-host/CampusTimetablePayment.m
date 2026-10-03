#import "CampusTimetablePayment.h"
@interface CampusTimetablePayment ()
@property(nonatomic, copy) CampusPaymentQuery query;
@property(nonatomic, copy) NSDictionary *(^load)(void);
@property(nonatomic, copy) void (^save)(NSDictionary *);
@property(nonatomic, copy) void (^clear)(void);
@property(nonatomic, copy) NSString *owner;
@property(nonatomic, copy) NSString *resNo;
@property(nonatomic, copy) NSString *programKey;
@property(nonatomic, copy) NSDictionary *renderInput;
@property(nonatomic, copy) NSDictionary *renderQuote;
@end
@implementation CampusTimetablePayment
- (instancetype)initWithQuery:(CampusPaymentQuery)query load:(NSDictionary *(^)(void))load
    save:(void (^)(NSDictionary *))save clear:(void (^)(void))clear {
    if ((self = [super init])) { _query = [query copy]; _load = [load copy]; _save = [save copy]; _clear = [clear copy]; }
    return self;
}
- (void)resetQuote { self.resNo = nil; self.programKey = nil; self.renderInput = nil; self.renderQuote = nil; }
- (NSString *)safeError:(NSException *)exception {
    NSSet *codes = [NSSet setWithArray:@[@"PAYMENT_STORAGE_FAILED", @"PAYMENT_ACCOUNT_MISMATCH", @"PAYMENT_PENDING", @"QUOTE_REQUIRED",
        @"QUOTE_MISMATCH", @"QUOTE_AMOUNT_INVALID", @"PRICE_CHANGED", @"DEVICE_UNAVAILABLE", @"UNSUPPORTED_DEVICE", @"DEVICE_MISMATCH",
        @"PROGRAM_UNAVAILABLE", @"CREATE_UNCERTAIN", @"PAYMENT_MISMATCH", @"PAYMENT_NOT_INIT", @"WECHAT_CHANNEL_UNAVAILABLE"]];
    return [codes containsObject:exception.name] ? exception.name : @"PAYMENT_MISMATCH";
}
- (void)ask:(CampusOriginalPurpose)purpose input:(NSDictionary *)input completion:(CampusPaymentCompletion)completion {
    self.query(purpose, input, ^(id payload, NSString *error) {
        if (error) { completion(nil, error); return; }
        @try { completion(payload, nil); }
        @catch (NSException *exception) { completion(nil, [self safeError:exception]); }
    });
}
- (NSDictionary *)pending {
    NSDictionary *pending = self.load();
    if (![pending isKindOfClass:NSDictionary.class]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    if (!pending.count) return pending;
    if (![pending[@"version"] isEqual:@1]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    if (![pending[@"owner"] isKindOfClass:NSString.class] || ![pending[@"owner"] isEqual:self.owner]) CampusPaymentFail(@"PAYMENT_ACCOUNT_MISMATCH");
    for (NSString *key in @[@"isvOrderId", @"resNo", @"device", @"program", @"location"]) {
        if (![pending[key] isKindOfClass:NSString.class] || [pending[key] length] > 256) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    }
    if (CampusPaymentCents(pending[@"isvOrderId"]) <= 0 || ![CampusOriginalMachineNumber(pending[@"resNo"]) isEqual:pending[@"resNo"]]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    CampusPaymentCents(pending[@"amount"]);
    if (pending[@"checkoutId"] && !CampusPaymentBody(CampusOriginalPurposeCheckout, @{@"checkoutId": pending[@"checkoutId"]})) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    return pending;
}
- (NSDictionary *)display:(NSDictionary *)pending {
    return pending.count ? @{@"device": pending[@"device"], @"location": pending[@"location"], @"program": pending[@"program"],
        @"amount": CampusPaymentYuan(CampusPaymentCents(pending[@"amount"])), @"reference": pending[@"isvOrderId"]} : @{};
}
- (void)preview:(NSString *)resNo key:(NSString *)key completion:(CampusPaymentCompletion)completion {
    [self resetQuote];
    if (![resNo isKindOfClass:NSString.class] || ![CampusOriginalMachineNumber(resNo) isEqual:resNo] || ![key isKindOfClass:NSString.class] || !key.length || key.length > 128) CampusPaymentFail(@"QUOTE_MISMATCH");
    [self ask:CampusOriginalPurposeDeviceInfo input:@{@"resNo": resNo} completion:^(id devicePayload, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *input = CampusPaymentRenderInput(devicePayload, resNo, key);
        [self ask:CampusOriginalPurposeRender input:input completion:^(id payload, NSString *renderError) {
            if (renderError) { completion(nil, renderError); return; }
            NSDictionary *quote = payload[@"response"];
            NSMutableDictionary *result = [CampusPaymentQuote(input, quote) mutableCopy];
            NSDictionary *device = devicePayload[@"data"][@"deviceResponse"];
            NSString *(^text)(id) = ^NSString *(id value) { return [value isKindOfClass:NSString.class] && [value length] <= 256 ? value : @""; };
            result[@"device"] = text(device[@"deviceName"]);
            result[@"location"] = [[NSString stringWithFormat:@"%@ %@", text(device[@"buildingName"]), text(device[@"floorName"])] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            self.resNo = resNo; self.programKey = key; self.renderInput = input; self.renderQuote = quote;
            completion(result, nil);
        }];
    }];
}
- (void)create:(NSString *)confirmed completion:(CampusPaymentCompletion)completion {
    if ([self pending].count) CampusPaymentFail(@"PAYMENT_PENDING");
    if (!self.renderInput) CampusPaymentFail(@"QUOTE_REQUIRED");
    NSString *resNo = self.resNo, *key = self.programKey;
    [self preview:resNo key:key completion:^(id latest, NSString *error) {
        if (error) { completion(nil, error); return; }
        if (![confirmed isKindOfClass:NSString.class] || ![latest[@"pay"] isEqual:confirmed]) CampusPaymentFail(@"PRICE_CHANGED");
        [self ask:CampusOriginalPurposeSequence input:@{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE", @"sequenceType": @"ORDER_CREATE_OUT_ID_SEQUENCE"}
            completion:^(id payload, NSString *sequenceError) {
                if (sequenceError) { completion(nil, sequenceError); return; }
                NSDictionary *input = CampusPaymentCreateInput(self.renderInput, self.renderQuote, payload[@"data"][@"response"]);
                NSMutableDictionary *pending = [@{@"version": @1, @"owner": self.owner, @"isvOrderId": [input[@"isvOrderId"] stringValue],
                    @"amount": input[@"paymentAmount"], @"resNo": resNo, @"device": latest[@"device"], @"location": latest[@"location"], @"program": latest[@"program"]} mutableCopy];
                // 必须先成功持久化并回读，再发唯一一次创建；失败结果也不能清掉该意图。
                self.save(pending);
                [self resetQuote];
                [self ask:CampusOriginalPurposeCreate input:input completion:^(id created, NSString *createError) {
                    if (createError) {
                        NSString *failure = [createError hasPrefix:@"CAMPUS_PAYMENT_FAILED\n"] ?
                            [@"CAMPUS_PAYMENT_FAILED\n创建结果待确认，付款记录已保留；不会再次创建。\n" stringByAppendingString:[createError substringFromIndex:[@"CAMPUS_PAYMENT_FAILED\n" length]]] :
                            [createError isEqual:@"SESSION_EXPIRED"] ? createError : @"CREATE_UNCERTAIN";
                        completion(nil, failure); return;
                    }
                    pending[@"checkoutId"] = CampusPaymentCreated(input, created[@"orderParamDto"]);
                    self.save(pending);
                    completion(@{}, nil);
                }];
            }];
    }];
}
- (void)recover:(CampusPaymentCompletion)completion {
    NSDictionary *pending = [self pending];
    if (!pending.count) CampusPaymentFail(@"PAYMENT_PENDING");
    if (pending[@"checkoutId"]) { completion(pending, nil); return; }
    [self ask:CampusOriginalPurposeHistory input:nil completion:^(id payload, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *matched = nil;
        for (NSDictionary *row in payload[@"data"][@"orderListResponses"]) {
            if (![CampusPaymentIdentifier(row[@"isvOrderId"]) isEqual:pending[@"isvOrderId"]]) continue;
            if (matched) CampusPaymentFail(@"PAYMENT_MISMATCH");
            matched = row;
        }
        if (!matched) { completion(nil, @"CREATE_UNCERTAIN"); return; }
        NSString *biz = CampusPaymentIdentifier(matched[@"bizOrderIdStr"] ?: matched[@"bizOrderId"]), *buyer = CampusPaymentIdentifier(matched[@"mixBuyerId"]);
        if (!biz.length || !buyer.length) CampusPaymentFail(@"PAYMENT_MISMATCH");
        [self ask:CampusOriginalPurposeOrderDetail input:@{@"bizOrderId": biz, @"mixBuyerId": buyer, @"isvOrderId": pending[@"isvOrderId"]}
            completion:^(id detailPayload, NSString *detailError) {
                if (detailError) { completion(nil, detailError); return; }
                NSDictionary *detail = detailPayload[@"data"][@"response"];
                if (![CampusPaymentIdentifier(detail[@"bizOrderIdStr"] ?: detail[@"bizOrderId"]) isEqual:biz] ||
                    CampusPaymentCents(detail[@"paymentAmount"]) != CampusPaymentCents(pending[@"amount"]) ||
                    (detail[@"isvOrderId"] && ![CampusPaymentIdentifier(detail[@"isvOrderId"]) isEqual:pending[@"isvOrderId"]]) ||
                    (detail[@"isvResNo"] && ![detail[@"isvResNo"] isEqual:pending[@"resNo"]])) CampusPaymentFail(@"PAYMENT_MISMATCH");
                NSMutableDictionary *recovered = [pending mutableCopy];
                if (!detail[@"checkoutId"] || !CampusPaymentBody(CampusOriginalPurposeCheckout, @{@"checkoutId": CampusPaymentIdentifier(detail[@"checkoutId"]) ?: @""})) CampusPaymentFail(@"CREATE_UNCERTAIN");
                recovered[@"checkoutId"] = CampusPaymentIdentifier(detail[@"checkoutId"]);
                self.save(recovered); completion(recovered, nil);
            }];
    }];
}
- (void)checkout:(CampusPaymentCompletion)completion {
    [self recover:^(id pending, NSString *error) {
        if (error) { completion(nil, error); return; }
        [self ask:CampusOriginalPurposeCheckout input:@{@"checkoutId": pending[@"checkoutId"]} completion:^(id payload, NSString *checkoutError) {
            if (checkoutError) { completion(nil, checkoutError); return; }
            CampusPaymentCheckout(pending, payload);
            completion(payload, nil);
        }];
    }];
}
- (void)perform:(NSString *)action input:(NSDictionary *)input owner:(NSString *)owner completion:(CampusPaymentCompletion)completion {
    @try {
        self.owner = owner;
        if (!owner.length) { completion(nil, @"SESSION_EXPIRED"); return; }
        if ([action isEqual:@"preview"]) {
            if (input.count != 2) CampusPaymentFail(@"QUOTE_MISMATCH");
            [self preview:input[@"resNo"] key:input[@"key"] completion:completion]; return;
        }
        if ([action isEqual:@"pendingPayment"]) { completion([self display:[self pending]], nil); return; }
        if ([action isEqual:@"createPayment"]) {
            if (input.count != 1) CampusPaymentFail(@"QUOTE_MISMATCH");
            [self create:input[@"amount"] completion:completion]; return;
        }
        if ([action isEqual:@"paymentCheckout"]) {
            [self checkout:^(id payload, NSString *error) { completion(payload ? @{@"status": payload[@"status"]} : nil, error); }]; return;
        }
        if ([action isEqual:@"wechatPayment"]) {
            [self checkout:^(id checkout, NSString *error) {
                if (error) { completion(nil, error); return; }
                if (![checkout[@"status"] isEqual:@"INIT"]) CampusPaymentFail(@"PAYMENT_NOT_INIT");
                NSDictionary *pending = [self pending];
                NSData *extra = [NSJSONSerialization dataWithJSONObject:@{@"bizOrderId": pending[@"checkoutId"]} options:0 error:nil];
                [self ask:CampusOriginalPurposePaymethod input:@{@"checkoutId": pending[@"checkoutId"], @"extraAttr": [[NSString alloc] initWithData:extra encoding:NSUTF8StringEncoding]}
                    completion:^(id payload, NSString *methodError) {
                        completion(payload ? @{@"uri": CampusPaymentWechat(pending, checkout, payload[@"cashierPayMethodList"])} : nil, methodError);
                    }];
            }]; return;
        }
        if ([action isEqual:@"acknowledgePayment"]) {
            [self checkout:^(id payload, NSString *error) {
                if (error) { completion(nil, error); return; }
                if (![@[@"SUCCESS", @"CLOSE"] containsObject:payload[@"status"]]) CampusPaymentFail(@"PAYMENT_PENDING");
                self.clear(); completion(@{}, nil);
            }]; return;
        }
        completion(nil, @"PAYMENT_MISMATCH");
    } @catch (NSException *exception) { completion(nil, [self safeError:exception]); }
}
@end
