#import "CampusTimetablePaymentProtocol.h"
#import <CoreFoundation/CoreFoundation.h>
#include <limits.h>

void CampusPaymentFail(NSString *code) { @throw [NSException exceptionWithName:code reason:code userInfo:nil]; }
static void QuoteMismatch(NSString *stage) {
    @throw [NSException exceptionWithName:@"QUOTE_MISMATCH" reason:stage userInfo:nil];
}
static BOOL Text(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] && [value length] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL Short(id value) {
    return [value isKindOfClass:NSString.class] && [value length] <= 256 &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL Flag(id value, BOOL expected) {
    return ([value isKindOfClass:NSNumber.class] && [value isEqual:expected ? @YES : @NO]) ||
        ([value isKindOfClass:NSString.class] && [value caseInsensitiveCompare:expected ? @"true" : @"false"] == NSOrderedSame);
}
static NSString *ID(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
        value = [value stringValue];
    }
    if (!Text(value, 128)) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? value : nil;
}
NSString *CampusPaymentIdentifier(id value) { return ID(value); }
NSString *CampusPaymentProgramIdentifier(id value) {
    // 程序 key 是服务端原样返回的字符串，可含标点；不是订单/机器编号。
    // 与设备页面保持同样的有界字符串契约，不裁剪、不替换、不转换类型。
    return Text(value, 128) && ![value containsString:@"&"] ? value : nil;
}
long long CampusPaymentCents(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) CampusPaymentFail(@"QUOTE_AMOUNT_INVALID");
        value = [value stringValue];
    }
    if (!Text(value, 19) || [value rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound)
        CampusPaymentFail(@"QUOTE_AMOUNT_INVALID");
    // 逐位检查溢出；禁止浮点舍入和 NSNumber 布尔金额。
    long long result = 0;
    for (NSUInteger i = 0; i < [value length]; i++) {
        int digit = [value characterAtIndex:i] - '0';
        if (result > (LLONG_MAX - digit) / 10) CampusPaymentFail(@"QUOTE_AMOUNT_INVALID");
        result = result * 10 + digit;
    }
    return result;
}
NSString *CampusPaymentYuan(long long value) {
    if (value < 0) CampusPaymentFail(@"QUOTE_AMOUNT_INVALID");
    return [NSString stringWithFormat:@"%lld.%02lld", value / 100, value % 100];
}
BOOL CampusPaymentPurpose(CampusOriginalPurpose purpose) {
    return purpose >= CampusOriginalPurposeRender && purpose <= CampusOriginalPurposePaymethod;
}
static BOOL Keys(NSDictionary *input, NSArray *keys) {
    return [input isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:input.allKeys] isEqual:[NSSet setWithArray:keys]];
}
static void ValidateScope(NSDictionary *input) {
    if (![input[@"isv"] isEqual:@"CAMPUS"] || ![input[@"businessType"] isEqual:@"WASH_AND_CARE"])
        CampusPaymentFail(@"PAYMENT_MISMATCH");
}
static void ValidateItems(id items) {
    if (![items isKindOfClass:NSArray.class] || [items count] != 1 ||
        ![items[0] isKindOfClass:NSDictionary.class] || !CampusPaymentProgramIdentifier(items[0][@"serviceItemId"])) CampusPaymentFail(@"QUOTE_MISMATCH");
}
NSString *CampusPaymentBody(CampusOriginalPurpose purpose, NSDictionary *input) {
    @try {
        NSString *type = nil;
        if (purpose == CampusOriginalPurposeRender || purpose == CampusOriginalPurposeCreate) {
            NSArray *keys = purpose == CampusOriginalPurposeRender ? @[@"isv", @"businessType", @"orderTypeCode", @"resNo", @"deviceId", @"campusAreaCode", @"paymentChannel", @"deviceType", @"modelType", @"serviceItemDTOList", @"promotionDetailDTOList"] :
                @[@"isv", @"businessType", @"orderTypeCode", @"paymentChannel", @"resNo", @"deviceId", @"modelType", @"campusAreaCode", @"isvOrderId", @"totalAmount", @"discountAmount", @"paymentAmount", @"serviceItemDTOList", @"promotionDetailDTOList"];
            if (!Keys(input, keys)) return nil;
            ValidateScope(input);
            if (![input[@"orderTypeCode"] isEqual:@"SERVICE_ORDER"] || ![input[@"paymentChannel"] isEqual:@"TMXY_APP"] ||
                ![input[@"modelType"] isEqual:@"FIXED_TIME_CHARGE"] || !ID(input[@"resNo"]) || !ID(input[@"deviceId"]) ||
                ![input[@"campusAreaCode"] isKindOfClass:NSNumber.class]) return nil;
            CampusPaymentCents(input[@"campusAreaCode"]);
            ValidateItems(input[@"serviceItemDTOList"]);
            if (![input[@"promotionDetailDTOList"] isKindOfClass:NSArray.class] || [input[@"promotionDetailDTOList"] count] > 100) return nil;
            if (purpose == CampusOriginalPurposeRender) {
                if (![input[@"deviceType"] isEqual:@"WASHING_MACHINE"] || [input[@"promotionDetailDTOList"] count]) return nil;
                NSDictionary *item = input[@"serviceItemDTOList"][0];
                if (!Keys(item, @[@"serviceItemId", @"serviceItemName", @"buyAmount", @"unitPrice", @"linePriceFee", @"attrName"]) || !Text(item[@"serviceItemName"], 256) ||
                    ![item[@"buyAmount"] isEqual:@"1"] || !Short(item[@"attrName"]) ||
                    CampusPaymentCents(item[@"unitPrice"]) != CampusPaymentCents(item[@"linePriceFee"])) return nil;
            } else {
                if (CampusPaymentCents(input[@"isvOrderId"]) <= 0) return nil;
                long long total = CampusPaymentCents(input[@"totalAmount"]), discount = CampusPaymentCents(input[@"discountAmount"]);
                if (discount > total || CampusPaymentCents(input[@"paymentAmount"]) != total - discount) return nil;
            }
            type = purpose == CampusOriginalPurposeRender ? @"RENDER_ORDER" : @"CREATE_ORDER";
        } else if (purpose == CampusOriginalPurposeSequence) {
            if (!Keys(input, @[@"isv", @"businessType", @"sequenceType"]) || ![input[@"sequenceType"] isEqual:@"ORDER_CREATE_OUT_ID_SEQUENCE"]) return nil;
            ValidateScope(input); type = @"OUT_UUID_SEQUENCE_GET";
        } else if (purpose == CampusOriginalPurposeCheckout) {
            if (!Keys(input, @[@"checkoutId"]) || !ID(input[@"checkoutId"])) return nil;
        } else if (purpose == CampusOriginalPurposePaymethod) {
            if (!Keys(input, @[@"checkoutId", @"extraAttr"]) || !ID(input[@"checkoutId"]) || !Text(input[@"extraAttr"], 512)) return nil;
            id extra = [NSJSONSerialization JSONObjectWithData:[input[@"extraAttr"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![extra isEqual:@{@"bizOrderId": input[@"checkoutId"]}]) return nil;
        } else return nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
        if (!data || data.length > 32768) return nil;
        NSDictionary *outer = type ? @{@"requestType": type, @"requestJson": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]} : input;
        data = [NSJSONSerialization dataWithJSONObject:outer options:0 error:nil];
        return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    } @catch (NSException *exception) { return nil; }
}
BOOL CampusPaymentDataValid(NSDictionary *data, CampusOriginalPurpose purpose) {
    if (![data isKindOfClass:NSDictionary.class]) return NO;
    if (purpose == CampusOriginalPurposeRender) return [data[@"response"] isKindOfClass:NSDictionary.class];
    if (purpose == CampusOriginalPurposeSequence) {
        @try { return Flag(data[@"fail"], NO) && [data[@"data"] isKindOfClass:NSDictionary.class] && CampusPaymentCents(data[@"data"][@"response"]) > 0; }
        @catch (NSException *exception) { return NO; }
    }
    if (purpose == CampusOriginalPurposeCreate) return [data[@"orderParamDto"] isKindOfClass:NSDictionary.class];
    if (purpose == CampusOriginalPurposeCheckout) return Flag(data[@"success"], YES) && Flag(data[@"failed"], NO) && ID(data[@"checkoutId"]);
    if (purpose == CampusOriginalPurposePaymethod) return [data[@"cashierPayMethodList"] isKindOfClass:NSArray.class] && [data[@"cashierPayMethodList"] count] <= 64;
    return NO;
}
NSDictionary *CampusPaymentRenderInput(NSDictionary *payload, NSString *resNo, NSString *key) {
    if (!CampusPaymentProgramIdentifier(key)) CampusPaymentFail(@"PROGRAM_UNAVAILABLE");
    NSDictionary *device = payload[@"data"][@"deviceResponse"];
    if (![device isKindOfClass:NSDictionary.class] || ![device[@"deviceCode"] isEqual:resNo]) CampusPaymentFail(@"DEVICE_MISMATCH");
    if (!Flag(device[@"deviceCanUse"], YES)) CampusPaymentFail(@"DEVICE_UNAVAILABLE");
    if (![device[@"deviceType"] isEqual:@"WASHING_MACHINE"] || ![device[@"modelType"] isEqual:@"FIXED_TIME_CHARGE"]) CampusPaymentFail(@"UNSUPPORTED_DEVICE");
    NSDictionary *selected = nil; NSString *attrName = nil;
    for (NSDictionary *mode in device[@"deviceWorkingModelDTOS"]) {
        if (!Flag(mode[@"isSupport"], YES)) continue;
        for (NSDictionary *price in mode[@"priceModelList"]) {
            if (!Flag(price[@"isOpen"], YES) || ![price[@"key"] isEqual:key]) continue;
            if (selected) CampusPaymentFail(@"PROGRAM_UNAVAILABLE");
            selected = price; attrName = [mode[@"attrName"] isKindOfClass:NSString.class] ? mode[@"attrName"] : @"";
        }
    }
    if (!selected) CampusPaymentFail(@"PROGRAM_UNAVAILABLE");
    long long price = CampusPaymentCents(selected[@"price"]);
    if (!ID(device[@"deviceId"])) QuoteMismatch(@"QUOTE_DEVICE_ID");
    if (!Text(selected[@"desc"], 256) || !Short(attrName)) QuoteMismatch(@"QUOTE_PROGRAM_DESCRIPTION");
    NSDictionary *input = @{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE", @"orderTypeCode": @"SERVICE_ORDER", @"resNo": resNo,
        @"deviceId": ID(device[@"deviceId"]), @"campusAreaCode": @(CampusPaymentCents(device[@"campusAreaId"])), @"paymentChannel": @"TMXY_APP",
        @"deviceType": device[@"deviceType"], @"modelType": device[@"modelType"], @"promotionDetailDTOList": @[],
        @"serviceItemDTOList": @[@{@"serviceItemId": key, @"serviceItemName": selected[@"desc"], @"buyAmount": @"1",
            @"unitPrice": @(price), @"linePriceFee": @(price), @"attrName": attrName}]};
    if (!CampusPaymentBody(CampusOriginalPurposeRender, input)) QuoteMismatch(@"QUOTE_RENDER_BODY");
    return input;
}
NSDictionary *CampusPaymentQuote(NSDictionary *input, NSDictionary *quote) {
    if (![quote isKindOfClass:NSDictionary.class]) QuoteMismatch(@"QUOTE_RESPONSE_OBJECT");
    if (!ID(quote[@"resNo"])) QuoteMismatch(@"QUOTE_RESOURCE_MISSING");
    if (![ID(input[@"resNo"]) isEqual:ID(quote[@"resNo"])]) QuoteMismatch(@"QUOTE_RESOURCE_DIFFERENT");
    if (!quote[@"businessType"] || quote[@"businessType"] == NSNull.null) QuoteMismatch(@"QUOTE_BUSINESS_MISSING");
    if (![quote[@"businessType"] isEqual:@"WASH_AND_CARE"]) QuoteMismatch(@"QUOTE_BUSINESS_DIFFERENT");
    NSArray *items = quote[@"serviceItemDTOList"];
    if (![items isKindOfClass:NSArray.class] || items.count != 1 || ![items[0] isKindOfClass:NSDictionary.class]) QuoteMismatch(@"QUOTE_ITEMS_SHAPE");
    if (!CampusPaymentProgramIdentifier(items[0][@"serviceItemId"])) QuoteMismatch(@"QUOTE_PROGRAM_MISSING");
    if (![CampusPaymentProgramIdentifier(input[@"serviceItemDTOList"][0][@"serviceItemId"]) isEqual:CampusPaymentProgramIdentifier(items[0][@"serviceItemId"])]) QuoteMismatch(@"QUOTE_PROGRAM_DIFFERENT");
    long long total = CampusPaymentCents(quote[@"totalAmount"]), discount = CampusPaymentCents(quote[@"discountAmount"]), pay = CampusPaymentCents(quote[@"actualPayAmount"]);
    if (discount > total || pay != total - discount) CampusPaymentFail(@"QUOTE_AMOUNT_INVALID");
    return @{@"program": input[@"serviceItemDTOList"][0][@"serviceItemName"], @"total": CampusPaymentYuan(total),
        @"discount": CampusPaymentYuan(discount), @"pay": CampusPaymentYuan(pay)};
}
NSDictionary *CampusPaymentCreateInput(NSDictionary *input, NSDictionary *quote, id sequence) {
    CampusPaymentQuote(input, quote);
    if (Flag(quote[@"onlyWalletPay"], YES)) CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
    long long serial = CampusPaymentCents(sequence);
    if (serial <= 0) CampusPaymentFail(@"PAYMENT_MISMATCH");
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"isv", @"businessType", @"orderTypeCode", @"paymentChannel", @"resNo", @"deviceId", @"modelType", @"campusAreaCode"]) result[key] = input[key];
    result[@"isvOrderId"] = @(serial); result[@"totalAmount"] = @(CampusPaymentCents(quote[@"totalAmount"]));
    result[@"discountAmount"] = @(CampusPaymentCents(quote[@"discountAmount"])); result[@"paymentAmount"] = @(CampusPaymentCents(quote[@"actualPayAmount"]));
    result[@"serviceItemDTOList"] = quote[@"serviceItemDTOList"]; result[@"promotionDetailDTOList"] = quote[@"promotionDetailDTOList"];
    if (!CampusPaymentBody(CampusOriginalPurposeCreate, result)) CampusPaymentFail(@"QUOTE_MISMATCH");
    return result;
}
NSString *CampusPaymentCreated(NSDictionary *input, NSDictionary *order) {
    if (![order isKindOfClass:NSDictionary.class] || !Flag(order[@"createFailed"], NO) || ![order[@"businessType"] isEqual:@"WASH_AND_CARE"] ||
        ![ID(input[@"isvOrderId"]) isEqual:ID(order[@"isvOrderId"])] || ![ID(input[@"resNo"]) isEqual:ID(order[@"isvResNo"])] ||
        CampusPaymentCents(input[@"paymentAmount"]) != CampusPaymentCents(order[@"paymentAmount"]) || !ID(order[@"checkoutId"])) CampusPaymentFail(@"PAYMENT_MISMATCH");
    return ID(order[@"checkoutId"]);
}
NSString *CampusPaymentCheckout(NSDictionary *pending, NSDictionary *data) {
    if (!Flag(data[@"success"], YES) || !Flag(data[@"failed"], NO) || ![pending[@"checkoutId"] isEqual:ID(data[@"checkoutId"])] ||
        CampusPaymentCents(pending[@"amount"]) != CampusPaymentCents(data[@"orderAmount"])) CampusPaymentFail(@"PAYMENT_MISMATCH");
    if (![@[@"INIT", @"PAYING", @"SUCCESS", @"CLOSE"] containsObject:data[@"status"]]) CampusPaymentFail(@"PAYMENT_MISMATCH");
    return data[@"status"];
}
static NSString *Encode(NSString *value) {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
}
NSString *CampusPaymentWechat(NSDictionary *pending, NSDictionary *checkout, NSArray *methods) {
    if (![CampusPaymentCheckout(pending, checkout) isEqual:@"INIT"]) CampusPaymentFail(@"PAYMENT_NOT_INIT");
    NSDictionary *selected = nil;
    for (id method in methods) {
        if (![method isKindOfClass:NSDictionary.class]) CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
        if ([method[@"payOption"] isEqual:@"WECHAT"] && [method[@"useStatus"] isEqual:@"USING"] &&
            [method[@"prePayModel"] isEqual:@"REDIRECT_PAY"] && [method[@"jumpType"] isEqual:@"SCHEME"]) { selected = method; break; }
    }
    id extra = selected[@"extraAttr"];
    if ([extra isKindOfClass:NSString.class]) {
        if ([extra length] == 0) extra = nil;
        else if ([extra length] <= 512) {
            extra = [NSJSONSerialization JSONObjectWithData:[extra dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![extra isKindOfClass:NSDictionary.class]) CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
        } else CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
    }
    if (!selected || (extra && extra != NSNull.null && (![extra isKindOfClass:NSDictionary.class] || [extra count]))) CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
    NSArray *keys = @[@"payMethodConfigId", @"optionalChannelId", @"bizOrderId", @"amount", @"prePayModel", @"payType", @"payTool"];
    NSArray *values = @[ID(selected[@"payMethodConfigId"]) ?: @"", ID(selected[@"optionalChannelId"]) ?: @"", pending[@"checkoutId"],
        [checkout[@"orderAmount"] description], @"REDIRECT_PAY", selected[@"payTool"] ?: @"", selected[@"payOptionDesc"] ?: @""];
    NSMutableArray *query = [NSMutableArray array];
    for (NSUInteger i = 0; i < keys.count; i++) {
        if (!Text(values[i], 512)) CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
        [query addObject:[NSString stringWithFormat:@"%@=%@", keys[i], Encode(values[i])]];
    }
    NSString *uri = [@"weixin://dl/business/?appid=wx48eea1ea40d67ab0&path=pages/commonAggregateCashier/miniAppPay/index&query=" stringByAppendingString:Encode([query componentsJoinedByString:@"&"])];
    uri = [uri stringByAppendingString:@"&env_version=release"];
    if (uri.length > 8192) CampusPaymentFail(@"WECHAT_CHANNEL_UNAVAILABLE");
    return uri;
}
