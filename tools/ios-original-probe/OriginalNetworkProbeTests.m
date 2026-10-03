#import "OriginalNetworkProbe.h"

// 所有请求只在内存构造；发送测试只使用必须在建连前拒绝的请求。
void CampusOriginalNetworkProbeTests(void) {
    NSString *(^encode)(NSString *) = ^NSString *(NSString *value) {
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
        return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    };
    NSDictionary *factors = @{@"x-sign": @"TEST_SIGN+a/b=", @"x-mini-wua": @"TEST_MINI+a/b=",
        @"x-umt": @"TEST_UMT+a/b=", @"x-sgext": @"TEST_SGEXT+a/b="};
    NSString *utdid = @"AAAAAAAAAAAAAAAAAAAAAAAA";
    NSString *ttid = @"test@campus_iPhone_5.7.2";
    NSURLRequest *request = CampusOriginalConfigRequest(@"test-key", utdid, ttid, @"1800000000", factors, encode);
    NSCAssert(request != nil, @"合法配置请求未能构造");
    NSString *expectedPath = [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalConfigAPI];
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES];
    NSCAssert([components.host isEqualToString:@"acs.m.taobao.com"], @"匿名请求主机错误");
    NSCAssert([components.percentEncodedPath isEqualToString:expectedPath], @"匿名路径末尾斜杠或编码改变");
    NSCAssert([components.percentEncodedQuery isEqualToString:@"data=%7B%7D"], @"匿名空正文线路编码错误");
    NSCAssert([request.HTTPMethod isEqualToString:@"GET"], @"匿名请求方法错误");
    NSCAssert(CampusOriginalConfigRequestInScope(request), @"合法请求被发送范围校验拒绝");
    NSString *expectedURL = [NSString stringWithFormat:@"https://acs.m.taobao.com%@?data=%%7B%%7D", expectedPath];
    NSCAssert([request.URL.absoluteString isEqualToString:expectedURL], @"实际 URL 丢失末尾斜杠或重复编码正文");
    NSCAssert(request.HTTPBody == nil && !request.HTTPShouldHandleCookies &&
        [request valueForHTTPHeaderField:@"Cookie"] == nil && [request valueForHTTPHeaderField:@"x-sid"] == nil &&
        [request valueForHTTPHeaderField:@"x-devid"] == nil, @"混入账号或旧注册状态");
    NSCAssert([[[request valueForHTTPHeaderField:@"x-ttid"] stringByRemovingPercentEncoding] isEqualToString:ttid], @"TTID 编码改变");
    for (NSString *key in factors) {
        NSString *value = [request valueForHTTPHeaderField:key];
        NSCAssert([value containsString:@"%2B"] && [value containsString:@"%2F"] && [value containsString:@"%3D"] &&
            [[value stringByRemovingPercentEncoding] isEqualToString:factors[key]], @"安全头漏编码或重复编码");
    }
    NSMutableDictionary *partial = [factors mutableCopy];
    [partial removeObjectForKey:@"x-umt"];
    NSCAssert(CampusOriginalConfigRequest(@"test-key", utdid, ttid, @"1800000000", partial, encode) == nil, @"缺字段未阻断");
    NSCAssert(CampusOriginalConfigRequest(@"test-key", @"random-uuid", ttid, @"1800000000", factors, encode) == nil, @"非法设备标识未阻断");
    NSCAssert(CampusOriginalConfigRequest(@"test-key", utdid, ttid, @"1800000000000", factors, encode) == nil, @"毫秒时间未阻断");
    NSString *(^doubleEncode)(NSString *) = ^NSString *(NSString *value) { return encode(encode(value)); };
    NSCAssert(CampusOriginalConfigRequest(@"test-key", utdid, ttid, @"1800000000", factors, doubleEncode) == nil, @"双重编码未阻断");
    NSString *(^wrongValue)(NSString *) = ^NSString *(NSString *value) {
        return [value isEqualToString:@"a+b/= %~*"] ? encode(value) : @"altered";
    };
    NSCAssert(CampusOriginalConfigRequest(@"test-key", utdid, ttid, @"1800000000", factors, wrongValue) == nil, @"编码器改变正文未阻断");
    for (NSUInteger mode = 0; mode < 6; mode++) {
        NSMutableURLRequest *bad = [request mutableCopy];
        if (mode == 0) bad.URL = [NSURL URLWithString:@"https://example.invalid/"];
        if (mode == 1) [bad setValue:@"private-cookie" forHTTPHeaderField:@"Cookie"];
        if (mode == 2) bad.HTTPMethod = @"POST";
        if (mode == 3) bad.HTTPBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        if (mode == 4) bad.URL = [NSURL URLWithString:@"https://acs.m.taobao.com/gw/mtop.sys.newdeviceid/4.0/?data=%7B%7D"];
        if (mode == 5) [bad setValue:@"0000000000" forHTTPHeaderField:@"x-t"];
        __block BOOL rejected = NO;
        CampusOriginalConfigSend(bad, ^(NSDictionary *result) {
            rejected = ![result[@"success"] boolValue] && [result[@"summary"] containsString:@"未发送"];
        });
        NSCAssert(rejected, @"越界或过期请求没有在发送前拒绝");
    }
    NSArray *wrongQueries = @[@"data=%257B%257D", @"data=%7B%7D&extra=1", @"data=%7B%7D&data=%7B%7D", @"data=%7B%22a%22%3A1%7D"];
    for (NSString *query in wrongQueries) {
        NSURLComponents *changed = [components copy];
        changed.percentEncodedQuery = query;
        NSMutableURLRequest *bad = [request mutableCopy];
        bad.URL = changed.URL;
        NSCAssert(!CampusOriginalConfigRequestInScope(bad), @"多编码、额外参数或正文改变未阻断");
    }
    for (NSString *path in @[[expectedPath substringToIndex:expectedPath.length - 1], [expectedPath stringByAppendingString:@"extra/"]]) {
        NSURLComponents *changed = [components copy];
        changed.percentEncodedPath = path;
        NSMutableURLRequest *bad = [request mutableCopy];
        bad.URL = changed.URL;
        NSCAssert(!CampusOriginalConfigRequestInScope(bad), @"线路路径改变未阻断");
    }
    NSArray *cases = @[
        @{@"ret": @[@"SUCCESS::SECRET_BODY"], @"data": @{@"secret": @"SECRET_DATA"}},
        @{@"ret": @[@"FAIL_SYS_ILEGEL_SIGN::SECRET_BODY"]},
        @{@"ret": @[@"SUCCESS::ok", @"FAIL_SYS_USER_VALIDATE::SECRET_BODY"]},
        @{@"ret": @[@"SECRET_UNKNOWN_CODE::SECRET_BODY"]},
        @{@"ret": @[]},
        @{@"ret": @[@123]},
    ];
    for (NSUInteger i = 0; i < cases.count; i++) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:cases[i] options:0 error:nil];
        NSDictionary *result = CampusOriginalConfigOutcome(200, body, 0, NO, NO);
        NSCAssert([result[@"success"] boolValue] == (i == 0), @"业务成功判定错误");
        NSCAssert(![result.description containsString:@"SECRET"], @"响应内容泄露");
    }
    NSData *ok = [NSJSONSerialization dataWithJSONObject:cases[0] options:0 error:nil];
    NSCAssert(![CampusOriginalConfigOutcome(403, ok, 0, NO, NO)[@"success"] boolValue], @"HTTP 失败误判成功");
    NSCAssert(![CampusOriginalConfigOutcome(200, ok, 0, YES, NO)[@"success"] boolValue], @"跳转误判成功");
    NSCAssert(![CampusOriginalConfigOutcome(200, ok, 0, NO, YES)[@"success"] boolValue], @"超限误判成功");
    NSCAssert(![CampusOriginalConfigOutcome(200, ok, -1009, NO, NO)[@"success"] boolValue], @"断网误判成功");
    NSCAssert(![CampusOriginalConfigOutcome(200, [@"invalid-json" dataUsingEncoding:NSUTF8StringEncoding], 0, NO, NO)[@"success"] boolValue], @"无效 JSON 误判成功");
}
