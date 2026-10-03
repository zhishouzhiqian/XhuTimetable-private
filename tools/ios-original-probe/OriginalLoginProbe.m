#import "OriginalNetworkProbe.h"
#import <CoreFoundation/CoreFoundation.h>

static BOOL AccountText(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static BOOL AccountCode(id value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return AccountText(value, 512) && [value length] >= 16 && [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *AccountUID(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
        NSString *text = [value stringValue];
        if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return nil;
        value = text;
    }
    return AccountText(value, 128) && ![value containsString:@"&"] ? value : nil;
}

BOOL CampusOriginalAuthorizationNavigation(NSURL *url) {
    NSURLComponents *c = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES] : nil;
    if (url.absoluteString.length > 8192 || ![c.scheme isEqual:@"https"] || c.user || c.password ||
        (c.port && ![c.port isEqual:@443])) return NO;
    NSString *host = c.host.lowercaseString;
    for (NSString *domain in @[@"taobao.com", @"tmall.com", @"alipay.com", @"alicdn.com"]) {
        if ([host isEqual:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

NSString *CampusOriginalAuthorizationCode(NSURL *url, BOOL mainFrame) {
    if (!mainFrame || !CampusOriginalAuthorizationNavigation(url)) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    if (![c.host.lowercaseString isEqual:@"www.alipay.com"] || ![c.percentEncodedPath isEqual:@"/webviewbridge"] || c.fragment) return nil;
    NSMutableArray *codes = [NSMutableArray array], *actions = [NSMutableArray array];
    for (NSURLQueryItem *item in c.queryItems) {
        if ([item.name isEqual:@"top_auth_code"]) [codes addObject:item.value ?: @""];
        if ([item.name isEqual:@"action"]) [actions addObject:item.value ?: @""];
    }
    if (codes.count != 1 || actions.count != 1 || ![actions[0] isEqual:@"taobao_auth_token"]) return nil;
    NSString *code = codes[0];
    return AccountCode(code) ? code : nil;
}

NSURL *CampusOriginalAuthorizationURL(NSString *appKey) {
    if (!AccountText(appKey, 128)) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithString:@"https://havanalogin.taobao.com/taobao_oauth_common.htm"];
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"appName" value:@"taobao-oauth-common"],
        [NSURLQueryItem queryItemWithName:@"appEntrance" value:@"sdk-common"],
        [NSURLQueryItem queryItemWithName:@"needTopToken" value:@"true"],
        [NSURLQueryItem queryItemWithName:@"topTokenAppName" value:appKey]];
    return c.URL;
}

NSString *CampusOriginalLoginBody(NSDictionary *info, NSDictionary *risk, NSDictionary *identity, NSString *code) {
    if (![info isKindOfClass:NSDictionary.class] || ![risk isKindOfClass:NSDictionary.class] || !AccountCode(code)) return nil;
    for (NSString *key in @[@"appName", @"utdid", @"ttid", @"deviceId"]) {
        NSString *identityKey = [@{@"appName": @"x-appkey", @"utdid": @"x-utdid", @"ttid": @"x-ttid", @"deviceId": @"deviceID"} objectForKey:key];
        if (!AccountText(info[key], 512) || ![info[key] isEqual:identity[identityKey]]) return nil;
    }
    if (![info[@"token"] isEqual:code] || ![info[@"snsType"] isEqual:@"taobao"] || ![info[@"site"] isEqual:@"96"] ||
        !AccountText(info[@"sdkVersion"], 128) || !AccountText(info[@"appVersion"], 128) ||
        !AccountText(risk[@"wua"], 65536) || !AccountText(risk[@"umidToken"], 4096) ||
        !AccountText(risk[@"t"], 13) || [risk[@"t"] length] != 13) return nil;
    NSData *a = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
    NSData *b = [NSJSONSerialization dataWithJSONObject:risk options:0 error:nil];
    if (!a || !b) return nil;
    // 外层两项为 JSON 字符串，不能把字典直接作为登录参数发送。
    NSDictionary *outer = @{@"snsLoginInfo": [[NSString alloc] initWithData:a encoding:NSUTF8StringEncoding],
        @"riskControlInfo": [[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding], @"ext": @"{}"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:outer options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

NSString *CampusOriginalAccountAPI(CampusOriginalPurpose purpose) {
    if (purpose == CampusOriginalPurposeLogin) return @"mtop.taobao.mloginservice.snslogin";
    if (purpose == CampusOriginalPurposeProfile) return @"mtop.tmall.campus.member.app.user.get";
    if (purpose == CampusOriginalPurposeOrders) return @"mtop.tmall.campus.share.applet.general.user.urgent.order.list";
    return nil;
}

static NSDictionary *AccountJSON(NSString *body) {
    if (!AccountText(body, 131072)) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static BOOL AccountBodyValid(NSString *body, CampusOriginalPurpose purpose, NSDictionary *identity) {
    NSDictionary *object = AccountJSON(body);
    if (purpose == CampusOriginalPurposeProfile) return [object isEqual:@{@"platForm": @"ios"}];
    if (purpose == CampusOriginalPurposeOrders) {
        return object.count == 2 && [object[@"requestType"] isEqual:@"USER_URGENT_ORDER_LIST"] &&
            [AccountJSON(object[@"requestJson"]) isEqual:@{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE"}];
    }
    if (purpose != CampusOriginalPurposeLogin || object.count != 3 || ![object[@"ext"] isEqual:@"{}"]) return NO;
    NSDictionary *info = AccountJSON(object[@"snsLoginInfo"]), *risk = AccountJSON(object[@"riskControlInfo"]);
    return CampusOriginalLoginBody(info, risk, identity, info[@"token"]) != nil;
}

BOOL CampusOriginalAccountRequestInScope(NSURLRequest *request, CampusOriginalPurpose purpose) {
    NSString *api = CampusOriginalAccountAPI(purpose);
    if (!api || !request.URL || ![request.HTTPMethod isEqual:@"POST"] || !request.HTTPBody.length ||
        request.HTTPBody.length > 393216 || request.HTTPBodyStream || request.HTTPShouldHandleCookies) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES];
    NSString *path = [NSString stringWithFormat:@"/gw/%@/1.0/", api];
    if (![url.percentEncodedPath isEqual:path] || url.percentEncodedQuery != nil) return NO;
    NSString *form = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
    if (![form hasPrefix:@"data="] || [form containsString:@"&"]) return NO;
    NSString *body = [[form substringFromIndex:5] stringByRemovingPercentEncoding];
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"x-appkey", @"x-utdid", @"x-ttid", @"x-devid"]) {
        NSString *value = [request valueForHTTPHeaderField:key].stringByRemovingPercentEncoding;
        if (!AccountText(value, 512)) return NO;
        identity[[key isEqual:@"x-devid"] ? @"deviceID" : key] = value;
    }
    if (!AccountBodyValid(body, purpose, identity)) return NO;
    NSString *sid = [request valueForHTTPHeaderField:@"x-sid"], *uid = [request valueForHTTPHeaderField:@"x-uid"];
    NSString *rawSID = sid.stringByRemovingPercentEncoding, *rawUID = uid.stringByRemovingPercentEncoding;
    if (purpose == CampusOriginalPurposeLogin ? sid != nil || uid != nil :
        !AccountText(rawSID, 4096) || [rawSID containsString:@"&"] || !AccountUID(rawUID)) return NO;
    if (![[request valueForHTTPHeaderField:@"Content-Type"] isEqual:@"application/x-www-form-urlencoded;charset=UTF-8"]) return NO;
    NSMutableURLRequest *normalized = [request mutableCopy];
    normalized.HTTPMethod = @"GET"; normalized.HTTPBody = nil;
    [normalized setValue:nil forHTTPHeaderField:@"x-sid"]; [normalized setValue:nil forHTTPHeaderField:@"x-uid"];
    [normalized setValue:nil forHTTPHeaderField:@"Content-Type"];
    url.percentEncodedPath = [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalConfigAPI];
    url.percentEncodedQuery = @"data=%7B%7D"; normalized.URL = url.URL;
    return CampusOriginalDeviceRequestInScope(normalized, CampusOriginalPurposeReuse);
}

NSURLRequest *CampusOriginalAccountRequest(NSDictionary *identity, NSString *time, NSString *body,
    NSDictionary *factors, NSDictionary *session, CampusOriginalPurpose purpose,
    NSString *(^encode)(NSString *), NSString *__autoreleasing *reason) {
    if (!AccountBodyValid(body, purpose, identity)) { if (reason) *reason = @"登录/只读正文契约未通过"; return nil; }
    NSURLRequest *base = CampusOriginalDeviceRequest(identity[@"x-appkey"], identity[@"x-utdid"], identity[@"x-ttid"], time,
        @"{}", factors, identity[@"deviceID"], CampusOriginalPurposeReuse, encode, reason);
    if (!base) return nil;
    @try {
        NSString *encoded = encode(body);
        NSCharacterSet *wire = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%"];
        if (!AccountText(encoded, 393216) || ![encoded.stringByRemovingPercentEncoding isEqual:body] ||
            [encoded rangeOfCharacterFromSet:wire.invertedSet].location != NSNotFound) {
            if (reason) *reason = @"正文编码回读不一致"; return nil;
        }
        NSMutableURLRequest *request = [base mutableCopy];
        NSURLComponents *url = [NSURLComponents componentsWithURL:base.URL resolvingAgainstBaseURL:YES];
        url.percentEncodedPath = [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalAccountAPI(purpose)];
        url.percentEncodedQuery = nil; request.URL = url.URL;
        request.HTTPMethod = @"POST";
        request.HTTPBody = [[@"data=" stringByAppendingString:encoded] dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
        if (purpose != CampusOriginalPurposeLogin) {
            for (NSString *key in @[@"sid", @"uid"]) {
                NSString *raw = session[key];
                if (!AccountText(raw, [key isEqual:@"sid"] ? 4096 : 128)) { if (reason) *reason = @"本人会话缺失或类型不符"; return nil; }
                NSString *value = encode(raw);
                if (!AccountText(value, 12288) || ![value.stringByRemovingPercentEncoding isEqual:raw] ||
                    [value rangeOfCharacterFromSet:wire.invertedSet].location != NSNotFound) { if (reason) *reason = @"会话编码回读失败"; return nil; }
                [request setValue:value forHTTPHeaderField:[@"x-" stringByAppendingString:key]];
            }
        }
        if (!CampusOriginalAccountRequestInScope(request, purpose)) { if (reason) *reason = @"发送白名单核对失败"; return nil; }
        return request;
    } @catch (NSException *exception) { if (reason) *reason = @"请求构造异常（正文隐藏）"; return nil; }
}

NSDictionary *CampusOriginalAccountEvidence(NSData *body, CampusOriginalPurpose purpose) {
    if (!body.length || body.length > 1024 * 1024) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    id data = [root isKindOfClass:NSDictionary.class] ? root[@"data"] : nil;
    if (![data isKindOfClass:NSDictionary.class]) return nil;
    if (purpose == CampusOriginalPurposeLogin) {
        id value = data[@"returnValue"];
        if (![value isKindOfClass:NSDictionary.class] || !AccountText(value[@"sid"], 4096) || [value[@"sid"] containsString:@"&"]) return nil;
        NSString *uid = AccountUID(value[@"hid"]);
        return uid ? @{@"sid": value[@"sid"], @"uid": uid} : nil;
    }
    if (purpose == CampusOriginalPurposeProfile) {
        return AccountText(data[@"openUserId"], 256) || AccountText(data[@"phone"], 128) ? @{@"verified": @YES} : nil;
    }
    if (purpose == CampusOriginalPurposeOrders) {
        id fail = data[@"fail"];
        id inner = data[@"data"];
        id rows = [inner isKindOfClass:NSDictionary.class] ? inner[@"urgentOrderListResponse"] : nil;
        if (![fail isKindOfClass:NSNumber.class] || [fail boolValue] || ![rows isKindOfClass:NSArray.class] || [rows count] > 200) return nil;
        for (id row in rows) if (![row isKindOfClass:NSDictionary.class]) return nil;
        return @{@"verified": @YES, @"count": @([rows count])};
    }
    return nil;
}
