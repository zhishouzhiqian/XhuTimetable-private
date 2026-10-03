#import "CampusTimetablePayment.h"
#import "CampusTimetableClient.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

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

// 会话与付款意图使用独立条目；退出登录不删除待确认订单。
static NSDictionary *SessionKey(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"vip.mystery0.xhu.timetable.laundry.campus-host-session",
        (__bridge id)kSecAttrAccount: @"session-v1", (__bridge id)kSecAttrSynchronizable: @NO};
}
static BOOL SessionText(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound && ![value containsString:@"&"];
}
static NSString *SessionBinding(NSDictionary *context) {
    NSMutableArray *identity = [NSMutableArray array];
    for (NSString *key in @[@"x-appkey", @"x-utdid", @"x-ttid", @"deviceID"]) {
        if (!SessionText(context[key], 512)) return nil;
        [identity addObject:context[key]];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    return [[NSData dataWithBytes:bytes length:sizeof(bytes)] base64EncodedStringWithOptions:0];
}
NSDictionary *CampusSessionLoad(NSDictionary *context) {
    NSMutableDictionary *query = [SessionKey() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    id data = CFBridgingRelease(result);
    if (status != errSecSuccess || ![data isKindOfClass:NSData.class] || [data length] > 16384) return nil;
    id stored = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    id session = [stored isKindOfClass:NSDictionary.class] ? stored[@"session"] : nil;
    NSString *binding = SessionBinding(context);
    if (![stored isKindOfClass:NSDictionary.class] || ![stored[@"version"] isEqual:@1] || !binding ||
        ![binding isEqual:stored[@"binding"]] || ![session isKindOfClass:NSDictionary.class] || [session count] != 2 ||
        !SessionText(session[@"sid"], 4096) || !SessionText(session[@"uid"], 128)) return nil;
    return session;
}
void CampusSessionSave(NSDictionary *session, NSDictionary *context) {
    NSString *binding = SessionBinding(context);
    if (!binding || session.count != 2 || !SessionText(session[@"sid"], 4096) || !SessionText(session[@"uid"], 128)) CampusPaymentFail(@"SESSION_STORAGE_FAILED");
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"binding": binding, @"session": session} options:0 error:nil];
    if (!data.length || data.length > 16384) CampusPaymentFail(@"SESSION_STORAGE_FAILED");
    NSDictionary *value = @{(__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)SessionKey(), (__bridge CFDictionaryRef)value);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [SessionKey() mutableCopy]; [item addEntriesFromDictionary:value];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status != errSecSuccess || ![CampusSessionLoad(context) isEqual:session]) CampusPaymentFail(@"SESSION_STORAGE_FAILED");
}
void CampusSessionClear(void) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)SessionKey());
    if (status != errSecSuccess && status != errSecItemNotFound) CampusPaymentFail(@"SESSION_STORAGE_FAILED");
}
