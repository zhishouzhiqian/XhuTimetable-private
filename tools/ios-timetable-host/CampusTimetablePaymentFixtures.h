#import "CampusTimetablePayment.h"
#include <limits.h>
static NSDictionary *PaymentDevice(void) {
    return @{@"data": @{@"deviceResponse": @{@"deviceCode": @"M1", @"deviceId": @"42", @"campusAreaId": @7,
        @"deviceType": @"WASHING_MACHINE", @"modelType": @"FIXED_TIME_CHARGE", @"deviceCanUse": @YES,
        @"deviceName": @"测试洗衣机", @"buildingName": @"测试楼", @"floorName": @"1楼",
        @"deviceWorkingModelDTOS": @[@{@"isSupport": @YES, @"attrName": @"洗衣",
            @"priceModelList": @[@{@"key": @"standard", @"isOpen": @YES, @"desc": @"标准洗", @"price": @400}]}]}}};
}
static NSDictionary *PaymentQuote(void) {
    return @{@"resNo": @"M1", @"businessType": @"WASH_AND_CARE", @"totalAmount": @400, @"discountAmount": @100,
        @"actualPayAmount": @300, @"serviceItemDTOList": @[@{@"serviceItemId": @"standard", @"serviceItemName": @"标准洗"}], @"promotionDetailDTOList": @[]};
}
static NSDictionary *PaymentCheckout(NSString *status) {
    return @{@"success": @YES, @"failed": @NO, @"checkoutId": @"88", @"orderAmount": @300, @"status": status};
}
static NSArray *PaymentMethods(void) {
    return @[@{@"payOption": @"WECHAT", @"useStatus": @"USING", @"prePayModel": @"REDIRECT_PAY", @"jumpType": @"SCHEME",
        @"payMethodConfigId": @12, @"optionalChannelId": @34, @"payTool": @"WECHAT", @"payOptionDesc": @"微信支付"}];
}
static void RejectPayment(void (^action)(void), NSString *code) {
    BOOL rejected = NO;
    @try { action(); } @catch (NSException *error) { rejected = [error.name isEqual:code]; }
    NSCAssert(rejected, @"付款边界未按预期拒绝");
}
