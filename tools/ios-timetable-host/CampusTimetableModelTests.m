#import "CampusTimetableClient.h"
int main(void) {
    @autoreleasepool {
        NSDictionary *row = @{@"bizOrderIdStr": @"123", @"isvOrderId": @"456", @"urgentOrderType": @"RUNNING_ORDER", @"remainSeconds": @60};
        NSDictionary *detail = @{@"bizOrderIdStr": @"123", @"payStatus": @"SUCCEED", @"fulfilStatus": @"FULFILLING"};
        NSDictionary *order = CampusTimetableOrder(row, detail);
        NSCAssert([order[@"running"] boolValue] && [order[@"seconds"] isEqual:@60] && ![order[@"completed"] boolValue], @"已付款运行状态或剩余秒数错误");
        NSMutableDictionary *changed = [detail mutableCopy]; changed[@"bizOrderIdStr"] = @"124";
        NSCAssert(CampusTimetableOrder(row, changed) == nil, @"串单详情被接受");
        changed = [detail mutableCopy]; changed[@"payStatus"] = @"INIT";
        NSCAssert(![CampusTimetableOrder(row, changed)[@"running"] boolValue], @"未付款误判运行");
        changed = [detail mutableCopy]; changed[@"fulfilStatus"] = @"COMPLETED";
        NSCAssert([CampusTimetableOrder(row, changed)[@"completed"] boolValue] &&
            CampusTimetableOrder(row, changed)[@"seconds"] == NSNull.null, @"完成状态仍使用倒计时");
        NSMutableDictionary *badTime = [row mutableCopy]; badTime[@"remainSeconds"] = @YES;
        NSCAssert(CampusTimetableOrder(badTime, detail)[@"seconds"] == NSNull.null, @"布尔值当作剩余秒数");
        badTime[@"remainSeconds"] = @604801;
        NSCAssert(CampusTimetableOrder(badTime, detail)[@"seconds"] == NSNull.null, @"过大倒计时被接受");
        NSCAssert(CampusTimetableDevice(@{@"data": NSNull.null}, @"M1") == nil, @"缺失设备结构被接受");
        NSDictionary *price = @{@"key": @"standard", @"isOpen": @"true", @"desc": @"标准洗", @"price": @400, @"priceYuan": @"4.00"};
        NSDictionary *device = @{@"deviceCode": @"M1", @"deviceCanUse": @"true", @"deviceWorkingModelDTOS": @[@{@"isSupport": @YES, @"priceModelList": @[price]}]};
        NSDictionary *projected = CampusTimetableDevice(@{@"data": @{@"deviceResponse": device}}, @"M1");
        NSCAssert([projected[@"canUse"] boolValue] && [projected[@"programs"][0][@"price"] isEqual:@"4.00"], @"布尔兼容或明确元价错误");
        NSCAssert(CampusTimetableDevice(@{@"data": @{@"deviceResponse": device}}, @"M2") == nil, @"错误机器被接受");
        NSMutableDictionary *noYuan = [price mutableCopy]; [noYuan removeObjectForKey:@"priceYuan"];
        NSMutableDictionary *noPrice = [device mutableCopy]; noPrice[@"deviceWorkingModelDTOS"] = @[@{@"isSupport": @YES, @"priceModelList": @[noYuan]}];
        NSDictionary *without = CampusTimetableDevice(@{@"data": @{@"deviceResponse": noPrice}}, @"M1");
        NSCAssert([without[@"programs"][0][@"price"] isEqual:@""], @"把未知原始单位强制当作元");
        puts("课表整合模型测试通过；未访问服务器或厂商组件。");
    }
    return 0;
}
