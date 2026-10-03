#import "OriginalQuoteProbe.h"
#import "../ios-timetable-host/CampusTimetablePaymentFixtures.h"
int main(void) {
    @autoreleasepool {
        NSCAssert(CampusOriginalAccountAPI(CampusOriginalPurposeRender) != nil, @"轻量诊断缺少报价入口");
        for (NSNumber *purpose in @[@(CampusOriginalPurposeSequence), @(CampusOriginalPurposeCreate), @(CampusOriginalPurposeCheckout), @(CampusOriginalPurposePaymethod)])
            NSCAssert(CampusOriginalAccountAPI(purpose.integerValue) == nil, @"轻量诊断开放了创建或付款入口");
        NSDictionary *input = CampusPaymentRenderInput(PaymentDevice(), @"M1", @"standard");
        NSDictionary *identity = @{@"x-appkey": @"test-key", @"x-utdid": @"YWJjZGVmZ2hpamtsbW5vcHFy", @"x-ttid": @"test@campus_iPhone_5.7.2", @"deviceID": @"test-device"};
        NSDictionary *factors = @{@"x-sign": @"test/sign+", @"x-mini-wua": @"test-wua", @"x-umt": @"test-umt", @"x-sgext": @"test-ext"};
        NSString *(^encode)(NSString *) = ^NSString *(NSString *text) {
            return [text stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
        };
        NSString *reason = nil, *body = CampusPaymentBody(CampusOriginalPurposeRender, input);
        NSURLRequest *request = CampusOriginalAccountRequest(identity, @"1234567890", body, factors, @{@"sid": @"test-session", @"uid": @"123"}, CampusOriginalPurposeRender, encode, &reason);
        NSCAssert(request && CampusOriginalAccountRequestInScope(request, CampusOriginalPurposeRender), @"轻量报价 POST 未通过：%@", reason);
        NSCAssert(!CampusOriginalAccountRequestInScope(request, CampusOriginalPurposeCreate), @"轻量报价请求可改为创建");
        NSMutableURLRequest *unsafe = [request mutableCopy]; unsafe.HTTPShouldHandleCookies = YES;
        NSCAssert(!CampusOriginalAccountRequestInScope(unsafe, CampusOriginalPurposeRender), @"轻量报价允许 Cookie");
        for (NSString *missing in @[@"", @"resNo", @"businessType", @"serviceItemDTOList", @"totalAmount", @"discountAmount", @"actualPayAmount"]) {
            NSMutableDictionary *quote = [PaymentQuote() mutableCopy];
            if (missing.length) [quote removeObjectForKey:missing];
            quote[@"privateField"] = @"private-response-value";
            NSArray *rows = CampusOriginalQuoteAudit(input, quote);
            NSData *bytes = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
            NSString *report = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
            NSCAssert(![report containsString:@"private-response-value"] && ![report containsString:@"standard"], @"报价诊断泄漏值");
            NSCAssert([report containsString:@"报价金额计算"] && [report containsString:@"整合版报价契约"], @"报价诊断未完成独立检查");
            NSCAssert([rows.lastObject[@"result"] hasPrefix:missing.length ? @"未通过" : @"通过"], @"诊断契约结论错误");
        }
        NSCAssert(CampusOriginalQuoteAudit(input, NSNull.null).count == 1, @"非对象报价没有停止结构扫描");
        puts("轻量报价诊断测试通过：字段缺失、独立金额核验、脱敏与禁止创建/付款入口；未联网。");
    }
    return 0;
}
