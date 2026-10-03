#import "CampusTimetablePayment.h"
#import "CampusTimetableClient.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

static NSDictionary *Key(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"vip.mystery0.xhu.timetable.laundry.campus-host-payment",
        (__bridge id)kSecAttrAccount: @"intent-v1", (__bridge id)kSecAttrSynchronizable: @NO};
}
static NSDictionary *DismissedKey(NSDictionary *intent) {
    if (![intent[@"owner"] isKindOfClass:NSString.class] || ![intent[@"isvOrderId"] isKindOfClass:NSString.class]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    NSData *identity = [NSJSONSerialization dataWithJSONObject:@[intent[@"owner"], intent[@"isvOrderId"]] options:0 error:nil];
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identity.bytes, (CC_LONG)identity.length, bytes);
    NSString *account = [[NSData dataWithBytes:bytes length:sizeof(bytes)] base64EncodedStringWithOptions:0];
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"vip.mystery0.xhu.timetable.laundry.campus-host-payment-dismissed",
        (__bridge id)kSecAttrAccount: account, (__bridge id)kSecAttrSynchronizable: @NO};
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
        // 本地结束过的原订单也不能再次创建；新的扫码下单必须取得新的订单编号。
        NSMutableDictionary *archivedQuery = [DismissedKey(intent) mutableCopy];
        archivedQuery[(__bridge id)kSecReturnData] = @YES;
        archivedQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef archivedResult = NULL;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)archivedQuery, &archivedResult);
        id archived = CFBridgingRelease(archivedResult);
        (void)archived;
        if (status == errSecSuccess) CampusPaymentFail(@"PAYMENT_PENDING");
        if (status != errSecItemNotFound) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
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

void CampusPaymentDismiss(NSDictionary *intent) {
    if (!intent.count || !intent[@"checkoutId"] || ![CampusPaymentLoad() isEqual:intent]) CampusPaymentFail(@"PAYMENT_MISMATCH");
    // 独立账号/订单条目保留原始身份，不写入 CLOSE，也不删除待确认创建的意图。
    NSDictionary *key = DismissedKey(intent);
    NSDictionary *record = @{@"version": @1, @"localPaymentEnded": @YES, @"intent": intent};
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!data.length || data.length > 16384) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    NSMutableDictionary *item = [key mutableCopy];
    item[(__bridge id)kSecValueData] = data;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess && status != errSecDuplicateItem) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    NSMutableDictionary *query = [key mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    id archived = CFBridgingRelease(result);
    if (status != errSecSuccess || ![archived isKindOfClass:NSData.class] || [archived length] > 16384) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    id decoded = [NSJSONSerialization JSONObjectWithData:archived options:0 error:nil];
    if (![decoded isEqual:record]) CampusPaymentFail(@"PAYMENT_STORAGE_FAILED");
    // 保存与回读都成功才移除当前槽位；任何失败仍阻止新建订单。
    if (![CampusPaymentLoad() isEqual:intent]) CampusPaymentFail(@"PAYMENT_MISMATCH");
    CampusPaymentClear();
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
