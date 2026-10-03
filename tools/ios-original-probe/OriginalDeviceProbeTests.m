#import "OriginalNetworkProbe.h"

// 只构造内存请求。发送测试使用越界请求，禁止真实建连。
void CampusOriginalDeviceProbeTests(void) {
    NSString *(^encode)(NSString *) = ^NSString *(NSString *value) {
        return [value stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
    };
    NSDictionary *factors = @{@"x-sign": @"TEST_SIGN", @"x-mini-wua": @"TEST_MINI", @"x-umt": @"TEST_UMT", @"x-sgext": @"TEST_SGEXT"};
    NSString *utdid = @"AAAAAAAAAAAAAAAAAAAAAAAA";
    NSString *body = CampusOriginalRegistrationBody(utdid, @"iPhone-test", @"02:00:00:00:00:00");
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSCAssert(json.count == 10 && !json[@"bizId"] && [json[@"c2"] isEqual:utdid] && [json[@"c3"] isEqual:@"0987654321"] &&
        [json[@"c5"] isEqual:@"CPUID"] && [json[@"c6"] isEqual:@"SDCARDID"], @"原 iOS 注册契约改变或混入 Android 参数");
    NSCAssert(CampusOriginalRegistrationBody(@"UUID", @"phone", @"mac") == nil &&
        CampusOriginalRegistrationBody(utdid, @"", @"mac") == nil && CampusOriginalRegistrationBody(utdid, @"phone", @"\n") == nil, @"无效设备资料未拒绝");
    NSString *deviceID = [@"D" stringByPaddingToLength:44 withString:@"D" startingAtIndex:0];
    NSString *reason = nil;
    NSURLRequest *registration = CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", body, factors, nil,
        CampusOriginalPurposeRegister, encode, &reason);
    NSURLRequest *reuse = CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", @"{}", factors, deviceID,
        CampusOriginalPurposeReuse, encode, &reason);
    NSCAssert(registration && reuse && CampusOriginalDeviceRequestInScope(registration, CampusOriginalPurposeRegister) &&
        CampusOriginalDeviceRequestInScope(reuse, CampusOriginalPurposeReuse), @"合法注册/复用请求未通过");
    NSCAssert(!CampusOriginalConfigRequestInScope(registration) && !CampusOriginalConfigRequestInScope(reuse) &&
        !CampusOriginalDeviceRequestInScope(registration, CampusOriginalPurposeReuse) &&
        !CampusOriginalDeviceRequestInScope(reuse, CampusOriginalPurposeRegister), @"三类请求白名单未隔离");
    NSURLRequest *escapedID = CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", @"{}", factors, @"opaque+/=ID",
        CampusOriginalPurposeReuse, encode, &reason);
    NSCAssert(escapedID && [[[escapedID valueForHTTPHeaderField:@"x-devid"] stringByRemovingPercentEncoding] isEqual:@"opaque+/=ID"],
        @"不透明 ID 被限定为 Android 长度或未正确转义");
    NSURLComponents *url = [NSURLComponents componentsWithURL:registration.URL resolvingAgainstBaseURL:YES];
    NSString *decoded = [[url.percentEncodedQuery substringFromIndex:5] stringByRemovingPercentEncoding];
    NSCAssert([url.percentEncodedPath isEqual:@"/gw/mtop.sys.newdeviceid/4.0/"] && [decoded isEqual:body], @"注册线路大小写、版本或正文改变");
    for (NSString *key in @[@"device_global_id", @"c2", @"c0", @"new_device", @"c3", @"c5"]) {
        NSMutableDictionary *badJSON = [json mutableCopy]; badJSON[key] = @"bad";
        NSString *badBody = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:badJSON options:0 error:nil] encoding:NSUTF8StringEncoding];
        NSCAssert(CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", badBody, factors, nil,
            CampusOriginalPurposeRegister, encode, &reason) == nil, @"注册字段变更未阻断");
    }
    NSCAssert(CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", @"{}", factors, @"bad&value",
        CampusOriginalPurposeReuse, encode, &reason) == nil, @"无效返回 ID 被复用");
    NSCAssert(CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", body, factors, deviceID,
        CampusOriginalPurposeRegister, encode, &reason) == nil, @"本次注册混入旧 ID");
    NSString *(^doubleEncode)(NSString *) = ^NSString *(NSString *value) { return encode(encode(value)); };
    NSCAssert(CampusOriginalDeviceRequest(@"key", utdid, @"ttid", @"1800000000", body, factors, nil,
        CampusOriginalPurposeRegister, doubleEncode, &reason) == nil, @"重复编码未拒绝");
    for (NSUInteger mutation = 0; mutation < 5; mutation++) {
        NSMutableURLRequest *bad = [registration mutableCopy];
        NSURLComponents *changed = [url copy];
        if (mutation == 0) changed.host = @"example.invalid";
        if (mutation == 1) [bad setValue:@"account" forHTTPHeaderField:@"Cookie"];
        if (mutation == 2) changed.percentEncodedQuery = [changed.percentEncodedQuery stringByAppendingString:@"&extra=1"];
        if (mutation == 3) [bad setValue:@"BBBBBBBBBBBBBBBBBBBBBBBB" forHTTPHeaderField:@"x-utdid"];
        if (mutation == 4) bad.HTTPMethod = @"POST";
        bad.URL = changed.URL;
        __block BOOL rejected = NO;
        CampusOriginalDeviceSend(bad, CampusOriginalPurposeRegister, ^(NSDictionary *outcome, NSString *returned) {
            rejected = ![outcome[@"success"] boolValue] && !returned && [outcome[@"summary"] containsString:@"未发送"];
        });
        NSCAssert(rejected, @"越界注册请求未在建连前拒绝");
    }
    for (id value in @[deviceID, @"bad&value", @123, NSNull.null]) {
        NSData *response = [NSJSONSerialization dataWithJSONObject:@{@"data": @{@"device_id": value}} options:0 error:nil];
        NSString *result = CampusOriginalRegisteredDevice(response);
        NSCAssert([value isEqual:deviceID] ? [result isEqual:deviceID] : result == nil, @"注册 ID 解析形状判定错误");
    }
    NSCAssert(CampusOriginalRegisteredDevice([@"{}" dataUsingEncoding:NSUTF8StringEncoding]) == nil &&
        CampusOriginalRegisteredDevice([@"bad-json" dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"缺 ID 或错误 JSON 被接纳");
}
