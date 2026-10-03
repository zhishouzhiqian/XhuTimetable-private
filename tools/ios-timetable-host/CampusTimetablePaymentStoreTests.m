#import "CampusTimetablePayment.h"
#import <Security/Security.h>

// 替换所有 SecItem 入口，只访问内存；不读写本人或系统 Keychain。
static NSMutableDictionary<NSString *, NSData *> *items;
static BOOL failArchiveWrite, failArchiveRead, failActiveDelete;
static NSString *ItemKey(CFDictionaryRef attributes) {
    NSDictionary *value = (__bridge NSDictionary *)attributes;
    return [NSString stringWithFormat:@"%@/%@", value[(__bridge id)kSecAttrService], value[(__bridge id)kSecAttrAccount]];
}
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSString *key = ItemKey(attributes);
    if (failArchiveWrite && [key containsString:@"payment-dismissed"]) return errSecInteractionNotAllowed;
    if (items[key]) return errSecDuplicateItem;
    items[key] = ((__bridge NSDictionary *)attributes)[(__bridge id)kSecValueData];
    return errSecSuccess;
}
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSString *key = ItemKey(query);
    if (failArchiveRead && [key containsString:@"payment-dismissed"]) return errSecInteractionNotAllowed;
    NSData *value = items[key];
    if (!value) return errSecItemNotFound;
    if (result) *result = CFBridgingRetain(value);
    return errSecSuccess;
}
OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    NSString *key = ItemKey(query);
    if (!items[key]) return errSecItemNotFound;
    items[key] = ((__bridge NSDictionary *)attributes)[(__bridge id)kSecValueData];
    return errSecSuccess;
}
OSStatus SecItemDelete(CFDictionaryRef query) {
    NSString *key = ItemKey(query);
    if (failActiveDelete && [key containsString:@"campus-host-payment/intent-v1"]) return errSecInteractionNotAllowed;
    if (!items[key]) return errSecItemNotFound;
    [items removeObjectForKey:key];
    return errSecSuccess;
}
void CampusPaymentFail(NSString *code) {
    @throw [NSException exceptionWithName:code reason:code userInfo:nil];
}
static void Reject(void (^action)(void), NSString *code) {
    BOOL rejected = NO;
    @try { action(); } @catch (NSException *error) { rejected = [error.name isEqual:code]; }
    NSCAssert(rejected, @"付款存储未按预期拒绝");
}
int main(void) {
    @autoreleasepool {
        items = [NSMutableDictionary dictionary];
        NSDictionary *intent = @{@"version": @1, @"owner": @"test-owner", @"isvOrderId": @"123",
            @"amount": @300, @"resNo": @"M1", @"device": @"测试", @"program": @"标准洗", @"location": @"测试楼"};
        CampusPaymentSave(intent);
        Reject(^{ CampusPaymentDismiss(intent); }, @"PAYMENT_MISMATCH");
        NSCAssert([CampusPaymentLoad() isEqual:intent] && items.count == 1, @"未知收银台被释放");
        NSMutableDictionary *ready = [intent mutableCopy]; ready[@"checkoutId"] = @"88";
        CampusPaymentSave(ready);
        failArchiveWrite = YES;
        Reject(^{ CampusPaymentDismiss(ready); }, @"PAYMENT_STORAGE_FAILED");
        NSCAssert([CampusPaymentLoad() isEqual:ready] && items.count == 1, @"存档失败丢失当前订单");
        failArchiveWrite = NO; failArchiveRead = YES;
        Reject(^{ CampusPaymentDismiss(ready); }, @"PAYMENT_STORAGE_FAILED");
        NSCAssert([CampusPaymentLoad() isEqual:ready] && items.count == 2, @"未回读存档就释放当前订单");
        failArchiveRead = NO; failActiveDelete = YES;
        Reject(^{ CampusPaymentDismiss(ready); }, @"PAYMENT_STORAGE_FAILED");
        NSCAssert([CampusPaymentLoad() isEqual:ready] && items.count == 2, @"删除失败却声称结束");
        failActiveDelete = NO;
        CampusPaymentDismiss(ready);
        NSCAssert(!CampusPaymentLoad().count && items.count == 1, @"重复存档不能恢复结束操作");
        NSDictionary *archived = [NSJSONSerialization JSONObjectWithData:items.allValues.firstObject options:0 error:nil];
        NSCAssert([archived[@"intent"] isEqual:ready] && [archived[@"localPaymentEnded"] isEqual:@YES] && !archived[@"status"], @"原订单身份丢失或伪造服务端关闭状态");
        Reject(^{ CampusPaymentSave(intent); }, @"PAYMENT_PENDING");
        NSCAssert(items.count == 1, @"结束过的原订单被再次创建");
        NSMutableDictionary *next = [intent mutableCopy]; next[@"isvOrderId"] = @"124";
        CampusPaymentSave(next);
        Reject(^{ CampusPaymentDismiss(ready); }, @"PAYMENT_MISMATCH");
        NSCAssert([CampusPaymentLoad() isEqual:next] && items.count == 2, @"旧记录清除了新订单");
        puts("本地付款存储测试通过：先存档后释放、写入/回读/删除失败保留、重试、旧订单拒绝重建与新订单隔离；仅使用内存 Keychain 桩。");
    }
    return 0;
}
