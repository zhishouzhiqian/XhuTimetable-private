#import "CampusTimetablePayment.h"
#import <Security/Security.h>

static NSDictionary *Key(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"vip.mystery0.xhu.timetable.laundry.campus-host-payment",
        (__bridge id)kSecAttrAccount: @"intent-v1", (__bridge id)kSecAttrSynchronizable: @NO};
}
NSDictionary *CampusPaymentLoad(void) {
    NSMutableDictionary *query = [Key() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    id data = CFBridgingRelease(result);
    if (status == errSecItemNotFound) return @{};
    if (status != errSecSuccess || ![data isKindOfClass:NSData.class] || [data length] > 16384) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    id state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:NSDictionary.class]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    return state;
}
void CampusPaymentSave(NSDictionary *intent) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:intent options:0 error:nil];
    if (!data.length || data.length > 16384) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    NSDictionary *value = @{(__bridge id)kSecValueData: data};
    OSStatus status;
    if (!intent[@"checkoutId"]) {
        // 原子新增保留唯一付款槽位，两个进程竞争时第二个不能覆盖后再次创建。
        NSMutableDictionary *item = [Key() mutableCopy];
        [item addEntriesFromDictionary:value];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (status == errSecDuplicateItem) CampusPaymentFail(@"PAYMENT_PENDING");
    } else {
        NSDictionary *current = CampusPaymentLoad();
        NSMutableDictionary *before = [current mutableCopy], *after = [intent mutableCopy];
        [before removeObjectForKey:@"checkoutId"]; [after removeObjectForKey:@"checkoutId"];
        if (!current.count || ![before isEqual:after] || (current[@"checkoutId"] && ![current[@"checkoutId"] isEqual:intent[@"checkoutId"]])) CampusPaymentFail(@"PAYMENT_MISMATCH");
        status = SecItemUpdate((__bridge CFDictionaryRef)Key(), (__bridge CFDictionaryRef)value);
    }
    // LiveContainer/签名环境不支持 Keychain 时拒绝创建，不降级到临时内存或偏好设置。
    if (status != errSecSuccess || ![CampusPaymentLoad() isEqual:intent]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
}
void CampusPaymentClear(void) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)Key());
    if (status != errSecSuccess && status != errSecItemNotFound) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
}
