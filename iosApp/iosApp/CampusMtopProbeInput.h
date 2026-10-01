#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

/**
 * 仅用于离线组件检查，不发送请求。
 * 字段顺序来自天猫校园 iOS 5.7.2 的 TBSDkSignUtility；正文按同一份 UTF-8 字节取 MD5。
 * 不复制 Android 签名串，也不以此证明候选 SDK 或服务端兼容。
 */
static NSString *CampusMtopProbeSignData(NSData *body, NSString *utdid, NSString *appKey,
                                       NSString *api, NSString *version, NSDictionary *headers) {
    if (!body || !utdid.length || !appKey.length || !api.length || !version.length) return nil;
    NSString *time = headers[@"x-t"];
    if (![time isKindOfClass:NSString.class] || time.length != 10 ||
        [time rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return nil;
    NSArray *optional = @[@"x-uid", @"x-reqbiz-ext", @"x-sid", @"x-ttid", @"x-devid", @"x-location",
        @"x-extdata", @"x-features", @"x-router-id", @"x-place-id", @"x-open-biz", @"x-mini-appkey",
        @"x-req-appkey", @"x-act", @"x-open-biz-data"];
    for (NSString *key in optional) {
        if (headers[key] && ![headers[key] isKindOfClass:NSString.class]) return nil;
    }
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(body.bytes, (CC_LONG)body.length, digest);
    NSMutableString *md5 = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [md5 appendFormat:@"%02x", digest[i]];
    NSArray *location = [headers[@"x-location"] componentsSeparatedByString:@","];
    NSMutableArray *fields = [NSMutableArray arrayWithArray:@[utdid, headers[@"x-uid"] ?: @"",
        headers[@"x-reqbiz-ext"] ?: @"", appKey, md5, time, api, version,
        headers[@"x-sid"] ?: @"", headers[@"x-ttid"] ?: @"", headers[@"x-devid"] ?: @"",
        location.count == 2 ? location[1] : @"", location.count == 2 ? location[0] : @""]];
    for (NSString *key in @[@"x-extdata", @"x-features", @"x-router-id", @"x-place-id", @"x-open-biz",
                           @"x-mini-appkey", @"x-req-appkey", @"x-act", @"x-open-biz-data"]) {
        [fields addObject:headers[key] ?: @""];
    }
    return [fields componentsJoinedByString:@"&"];
}

/** 厂商返回非空字典不等于完整签名；错误和必需字段缺失都不能判成功。 */
static BOOL CampusMtopProbeFactorsComplete(NSDictionary *factors, NSError *error) {
    if (error || ![factors isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"x-sign", @"x-mini-wua", @"x-umt", @"x-sgext"]) {
        id value = factors[key];
        if (![value isKindOfClass:NSString.class] || [value length] == 0) return NO;
    }
    return YES;
}
