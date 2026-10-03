#import "OriginalNetworkProbe.h"

// 原 iOS 构造入口的 API 名称；请求对象自行规范化，签名读取原对象返回值。
NSString *const CampusOriginalRegisterAPI = @"mtop.sys.newDeviceId";

static BOOL DeviceText(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static BOOL DeviceIDValid(id value) {
    // 原 iOS 返回的是不透明字符串，不把 Android 样本的 44 字符长度当作 iOS 必须契约。
    return DeviceText(value, 256) &&
        [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_=-+/"].invertedSet].location == NSNotFound;
}

NSString *CampusOriginalRegistrationBody(NSString *utdid, NSString *platform, NSString *mac) {
    if (!DeviceText(utdid, 24) || utdid.length != 24 ||
        [[NSData alloc] initWithBase64EncodedString:utdid options:0].length != 18 ||
        !DeviceText(platform, 128) || !DeviceText(mac, 128)) return nil;
    NSDictionary *object = @{@"device_global_id": utdid, @"c0": @"apple", @"c1": platform,
        @"c2": utdid, @"c3": @"0987654321", @"c4": mac, @"c5": @"CPUID", @"c6": @"SDCARDID",
        @"new_id_rule": @"true", @"new_device": @"true"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static BOOL RegistrationValid(NSString *body, NSString *utdid) {
    if (!DeviceText(body, 4096)) return NO;
    id object = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *expected = @{@"device_global_id": utdid ?: @"", @"c0": @"apple", @"c2": utdid ?: @"",
        @"c3": @"0987654321", @"c5": @"CPUID", @"c6": @"SDCARDID", @"new_id_rule": @"true", @"new_device": @"true"};
    if ([object count] != 10 || !DeviceText(object[@"c1"], 128) || !DeviceText(object[@"c4"], 128)) return NO;
    for (NSString *key in expected) if (![expected[key] isEqual:object[key]]) return NO;
    return YES;
}

BOOL CampusOriginalDeviceRequestInScope(NSURLRequest *request, CampusOriginalPurpose purpose) {
    if (purpose == CampusOriginalPurposeConfig) return CampusOriginalConfigRequestInScope(request);
    if (purpose != CampusOriginalPurposeRegister && purpose != CampusOriginalPurposeReuse) return NO;
    NSURLComponents *url = request.URL ? [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES] : nil;
    NSString *path = purpose == CampusOriginalPurposeRegister ? @"/gw/mtop.sys.newdeviceid/4.0/" :
        [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalConfigAPI];
    NSString *query = url.percentEncodedQuery;
    if (![url.percentEncodedPath isEqual:path] || ![query hasPrefix:@"data="] || [query containsString:@"&"]) return NO;
    NSString *encoded = [query substringFromIndex:5];
    NSString *body = encoded.stringByRemovingPercentEncoding;
    NSString *utdid = [request valueForHTTPHeaderField:@"x-utdid"].stringByRemovingPercentEncoding;
    if (purpose == CampusOriginalPurposeRegister ? !RegistrationValid(body, utdid) : ![encoded isEqual:@"%7B%7D"]) return NO;
    NSString *device = [request valueForHTTPHeaderField:@"x-devid"];
    if (purpose == CampusOriginalPurposeRegister ? device != nil : !DeviceIDValid(device.stringByRemovingPercentEncoding)) return NO;
    // 复用配置请求的完整目的地、方法、Cookie 和精确请求头白名单检查。
    NSMutableURLRequest *normalized = [request mutableCopy];
    url.percentEncodedPath = [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalConfigAPI];
    url.percentEncodedQuery = @"data=%7B%7D";
    normalized.URL = url.URL;
    [normalized setValue:nil forHTTPHeaderField:@"x-devid"];
    return CampusOriginalConfigRequestInScope(normalized);
}

NSURLRequest *CampusOriginalDeviceRequest(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSString *body, NSDictionary *factors, NSString *deviceID,
    CampusOriginalPurpose purpose, NSString *(^encode)(NSString *), NSString *__autoreleasing *reason) {
    NSURLRequest *base = CampusOriginalConfigRequestChecked(appKey, utdid, ttid, time, factors, encode, reason);
    if (!base) return nil;
    BOOL valid = purpose == CampusOriginalPurposeRegister ? RegistrationValid(body, utdid) && !deviceID :
        purpose == CampusOriginalPurposeReuse ? [body isEqual:@"{}"] && DeviceIDValid(deviceID) : NO;
    if (!valid) { if (reason) *reason = @"DEVICE_BODY：注册正文或设备 ID 不符合契约"; return nil; }
    @try {
        NSString *encodedBody = encode(body);
        NSString *encodedID = deviceID ? encode(deviceID) : nil;
        if (!DeviceText(encodedBody, 65536) || ![encodedBody.stringByRemovingPercentEncoding isEqual:body] ||
            (deviceID && (!DeviceText(encodedID, 768) || ![encodedID.stringByRemovingPercentEncoding isEqual:deviceID]))) {
            if (reason) *reason = @"DEVICE_ENCODING：正文或设备 ID 编码回读不一致";
            return nil;
        }
        NSCharacterSet *wire = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%"];
        if ([encodedBody rangeOfCharacterFromSet:wire.invertedSet].location != NSNotFound ||
            (encodedID && [encodedID rangeOfCharacterFromSet:wire.invertedSet].location != NSNotFound)) {
            if (reason) *reason = @"DEVICE_ENCODING：存在未转义字符"; return nil;
        }
        NSMutableURLRequest *request = [base mutableCopy];
        NSURLComponents *url = [NSURLComponents componentsWithURL:base.URL resolvingAgainstBaseURL:YES];
        if (purpose == CampusOriginalPurposeRegister) url.percentEncodedPath = @"/gw/mtop.sys.newdeviceid/4.0/";
        url.percentEncodedQuery = [@"data=" stringByAppendingString:encodedBody];
        request.URL = url.URL;
        if (encodedID) [request setValue:encodedID forHTTPHeaderField:@"x-devid"];
        if (!CampusOriginalDeviceRequestInScope(request, purpose)) {
            if (reason) *reason = @"DEVICE_SCOPE：范围核对失败"; return nil;
        }
        return request;
    } @catch (NSException *exception) {
        if (reason) *reason = @"DEVICE_ENCODING：编码入口异常（正文隐藏）"; return nil;
    }
}

NSString *CampusOriginalRegisteredDevice(NSData *body) {
    if (!body.length || body.length > 1024 * 1024) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    id data = [root isKindOfClass:NSDictionary.class] ? root[@"data"] : nil;
    id value = [data isKindOfClass:NSDictionary.class] ? data[@"device_id"] : nil;
    return DeviceIDValid(value) ? value : nil;
}
