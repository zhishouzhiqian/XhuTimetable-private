#import "OriginalQuoteProbe.h"
#import "../ios-timetable-host/CampusTimetablePaymentProtocol.h"
#import <CoreFoundation/CoreFoundation.h>
static NSString *Shape(id value) {
    if (!value) return @"缺失";
    if (value == NSNull.null) return @"null";
    if ([value isKindOfClass:NSString.class]) return @"字符串";
    if ([value isKindOfClass:NSNumber.class]) return CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? @"布尔" : @"数字";
    if ([value isKindOfClass:NSDictionary.class]) return @"对象";
    if ([value isKindOfClass:NSArray.class]) return @"数组";
    return @"其它类型";
}
NSArray *CampusOriginalQuoteAudit(NSDictionary *input, id response) {
    NSMutableArray *rows = [NSMutableArray array];
    void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) { [rows addObject:@{@"step": step, @"result": result}]; };
    emit(@"报价 response 类型", Shape(response));
    if (![response isKindOfClass:NSDictionary.class]) return rows;
    NSDictionary *quote = response;
    for (NSString *key in @[@"resNo", @"isvResNo", @"deviceId", @"businessType", @"serviceItemDTOList", @"totalAmount", @"discountAmount", @"actualPayAmount", @"promotionDetailDTOList", @"onlyWalletPay"])
        emit([@"报价字段 / " stringByAppendingString:key], Shape(quote[key]));
    for (NSString *key in @[@"resNo", @"isvResNo", @"deviceId"]) {
        NSString *actual = CampusPaymentIdentifier(quote[key]);
        NSString *expected = CampusPaymentIdentifier(input[[key isEqual:@"deviceId"] ? @"deviceId" : @"resNo"]);
        emit([@"报价身份对照 / " stringByAppendingString:key], !actual ? @"缺失或类型未通过" : [actual isEqual:expected] ? @"与本次请求一致" : @"与本次请求不同");
    }
    emit(@"报价业务对照", [quote[@"businessType"] isEqual:@"WASH_AND_CARE"] ? @"与洗衣业务一致" : @"缺失或与洗衣业务不同");
    id items = quote[@"serviceItemDTOList"];
    if ([items isKindOfClass:NSArray.class]) {
        emit(@"报价程序项数量", [NSString stringWithFormat:@"%lu 项", (unsigned long)[items count]]);
        if ([items count] == 1 && [items[0] isKindOfClass:NSDictionary.class]) {
            NSString *actual = CampusPaymentIdentifier(items[0][@"serviceItemId"]);
            emit(@"报价程序字段 / serviceItemId", Shape(items[0][@"serviceItemId"]));
            emit(@"报价程序对照", !actual ? @"缺失或类型未通过" : [actual isEqual:CampusPaymentIdentifier(input[@"serviceItemDTOList"][0][@"serviceItemId"])] ? @"与所选程序一致" : @"与所选程序不同");
        }
    }
    BOOL amountsValid = YES; long long total = 0, discount = 0, pay = 0;
    for (NSString *key in @[@"totalAmount", @"discountAmount", @"actualPayAmount"]) {
        @try {
            long long value = CampusPaymentCents(quote[key]);
            if ([key isEqual:@"totalAmount"]) total = value;
            else if ([key isEqual:@"discountAmount"]) discount = value;
            else pay = value;
            emit([@"报价金额格式 / " stringByAppendingString:key], @"非负整数分通过（值隐藏）");
        } @catch (NSException *exception) { amountsValid = NO; emit([@"报价金额格式 / " stringByAppendingString:key], @"未通过非负整数分契约（值隐藏）"); }
    }
    emit(@"报价金额计算", !amountsValid ? @"金额格式未通过，跳过计算" : discount <= total && pay == total - discount ? @"总额减优惠等于应付，通过（值隐藏）" : @"总额、优惠与应付不一致（值隐藏）");
    @try { CampusPaymentQuote(input, quote); emit(@"整合版报价契约", @"通过；此诊断不会创建订单"); }
    @catch (NSException *exception) { emit(@"整合版报价契约", @"未通过；具体缺失、类型和对照结果见以上检查"); }
    return rows;
}
