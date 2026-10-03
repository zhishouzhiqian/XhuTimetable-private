#import "CampusTimetableClient.h"
#import <CoreFoundation/CoreFoundation.h>

static NSString *Text(id value, NSString *fallback) {
    return [value isKindOfClass:NSString.class] && [value length] <= 256 &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound ? value : fallback;
}
static NSString *ID(id value) {
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) value = [value stringValue];
    NSString *text = Text(value, nil);
    return text.length && text.length <= 128 && ![text containsString:@"&"] ? text : nil;
}
static BOOL True(id value) { return [value isEqual:@YES] || ([value isKindOfClass:NSString.class] && [value caseInsensitiveCompare:@"true"] == NSOrderedSame); }
static NSString *Location(NSDictionary *item) {
    return [[NSString stringWithFormat:@"%@ %@", Text(item[@"buildingName"], @""), Text(item[@"floorName"], @"")]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}
NSDictionary *CampusTimetableDevice(NSDictionary *payload, NSString *number) {
    if (![payload isKindOfClass:NSDictionary.class] || ![payload[@"data"] isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *device = payload[@"data"][@"deviceResponse"];
    if (![device isKindOfClass:NSDictionary.class] || ![device[@"deviceCode"] isEqual:number]) return nil;
    if (![device[@"deviceWorkingModelDTOS"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *programs = [NSMutableArray array]; NSMutableSet *keys = [NSMutableSet set];
    for (NSDictionary *mode in device[@"deviceWorkingModelDTOS"]) {
        if (![mode isKindOfClass:NSDictionary.class]) return nil;
        if (!True(mode[@"isSupport"])) continue;
        if (![mode[@"priceModelList"] isKindOfClass:NSArray.class]) return nil;
        for (NSDictionary *price in mode[@"priceModelList"]) {
            if (![price isKindOfClass:NSDictionary.class]) return nil;
            if (!True(price[@"isOpen"])) continue;
            NSString *key = ID(price[@"key"]);
            if (!key || [keys containsObject:key] || programs.count >= 100) return nil;
            [keys addObject:key];
            id raw = price[@"priceYuan"];
            if ([raw isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)raw) != CFBooleanGetTypeID()) raw = [raw stringValue];
            NSString *yuan = Text(raw, @"");
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,6}(\\.[0-9]{1,2})?$" options:0 error:nil];
            if (![regex numberOfMatchesInString:yuan options:0 range:NSMakeRange(0, yuan.length)]) yuan = @"";
            [programs addObject:@{@"key": key, @"name": Text(price[@"desc"], @"洗衣程序"),
                @"details": Text(price[@"defaultDetails"], @"时长说明未提供"), @"price": yuan}];
        }
    }
    return @{@"resNo": number, @"name": Text(device[@"deviceName"], @"洗衣机"), @"location": Location(device),
        @"status": Text(device[@"workbenchStatusDESC"], @"状态未提供"), @"canUse": True(device[@"deviceCanUse"]) ? @YES : @NO, @"programs": programs};
}
NSDictionary *CampusTimetableOrder(NSDictionary *row, NSDictionary *detail) {
    if (![row isKindOfClass:NSDictionary.class] || (detail && ![detail isKindOfClass:NSDictionary.class])) return nil;
    NSString *pay = Text(detail ? detail[@"payStatus"] : row[@"payStatusEnum"], @"");
    NSString *fulfil = Text((detail ?: row)[@"fulfilStatus"], @"");
    if (detail && ![ID(detail[@"bizOrderIdStr"] ?: detail[@"bizOrderId"]) isEqual:ID(row[@"bizOrderIdStr"] ?: row[@"bizOrderId"])]) return nil;
    BOOL paid = [pay isEqual:@"SUCCEED"], completed = paid && [fulfil isEqual:@"COMPLETED"];
    BOOL running = detail && paid && [fulfil isEqual:@"FULFILLING"] && [row[@"urgentOrderType"] isEqual:@"RUNNING_ORDER"];
    NSString *status = [pay isEqual:@"CLOSED"] ? @"订单已关闭" : !paid ? @"付款尚未确认" : completed ? @"已付款 · 洗衣完成" :
        [fulfil isEqual:@"FULFILLING"] ? @"已付款 · 运行中" : [fulfil isEqual:@"ERROR_COMPLETE"] ? @"已付款 · 服务异常，请核对订单" : @"已付款 · 等待设备状态确认";
    id seconds = NSNull.null, raw = row[@"remainSeconds"];
    if (running && !([raw isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID())) {
        NSString *text = [raw isKindOfClass:NSNumber.class] ? [raw stringValue] : Text(raw, @"");
        NSRegularExpression *integer = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,6}$" options:0 error:nil];
        if ([integer numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)] && text.longLongValue <= 604800) seconds = @(text.longLongValue);
    }
    return @{@"name": Text(row[@"deviceName"], @"洗衣机"), @"program": Text((detail ?: row)[@"workModeName"], @"程序未提供"),
        @"location": Location(detail ?: row), @"status": status, @"running": running ? @YES : @NO, @"seconds": seconds,
        @"reference": ID(row[@"isvOrderId"]) ?: @"", @"completed": completed ? @YES : @NO, @"waitingForDevice": (paid && [fulfil isEqual:@"WAIT_FULFIL"]) ? @YES : @NO};
}
