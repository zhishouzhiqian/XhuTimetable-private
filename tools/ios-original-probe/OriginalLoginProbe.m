#import "OriginalNetworkProbe.h"
#import <CoreFoundation/CoreFoundation.h>
#ifdef CAMPUS_TIMETABLE_HOST
#import "../ios-timetable-host/CampusTimetablePaymentProtocol.h"
#endif

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
#ifdef CAMPUS_TIMETABLE_HOST
    if (purpose == CampusOriginalPurposeRender) return @"mtop.tmall.campus.share.order.render.execute";
    if (purpose == CampusOriginalPurposeSequence) return @"mtop.tmall.campus.share.general.uuid.get";
    if (purpose == CampusOriginalPurposeCreate) return @"mtop.tmall.campus.share.order.create.execute";
    if (purpose == CampusOriginalPurposeCheckout) return @"mtop.tmall.campus.cashier.checkout.query";
    if (purpose == CampusOriginalPurposePaymethod) return @"mtop.tmall.campus.cashier.paymethod.query";
#endif
    if (purpose == CampusOriginalPurposeLogin) return @"mtop.taobao.mloginservice.snslogin";
    if (purpose == CampusOriginalPurposeProfile) return @"mtop.tmall.campus.member.app.user.get";
    if (purpose == CampusOriginalPurposeOrders) return @"mtop.tmall.campus.share.applet.general.user.urgent.order.list";
    if (purpose == CampusOriginalPurposeHistory) return @"mtop.tmall.campus.share.applet.general.user.order.list";
    if (purpose == CampusOriginalPurposeBuildings) return @"mtop.tmall.campus.share.applet.building.list";
    if (purpose == CampusOriginalPurposeDevices) return @"mtop.tmall.campus.share.applet.device.list";
    if (purpose == CampusOriginalPurposeDeviceInfo) return @"mtop.tmall.campus.share.applet.general.device.info";
    if (purpose == CampusOriginalPurposeOrderDetail) return @"mtop.tmall.campus.share.applet.general.order.detail.get";
    return nil;
}

// 与 Android JSONObject.optBoolean 对齐，但未知值和缺失值不能充当成功。
static BOOL AccountBoolean(id value, BOOL expected) {
    if ([value isKindOfClass:NSNumber.class]) return [value isEqual:@(expected)];
    if ([value isKindOfClass:NSString.class]) return [value caseInsensitiveCompare:expected ? @"true" : @"false"] == NSOrderedSame;
    return NO;
}

static BOOL AccountDeviceCode(id value) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return AccountText(value, 128) && [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSString *CampusOriginalReadBody(CampusOriginalPurpose purpose, NSDictionary *device) {
    NSString *type = nil; NSDictionary *query = nil;
    if (purpose == CampusOriginalPurposeOrders) {
        type = @"USER_URGENT_ORDER_LIST"; query = @{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE"};
    } else if (purpose == CampusOriginalPurposeHistory) {
        type = @"USER_ORDER_LIST"; query = @{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE", @"pageNum": @1, @"pageSize": @10, @"isQueryToPayOrderList": @NO};
    } else if (purpose == CampusOriginalPurposeBuildings) {
        type = @"USER_BUILDING_LIST"; query = @{@"relationStatus": @"ON", @"businessType": @"WASH_AND_CARE"};
    } else if (purpose == CampusOriginalPurposeDevices) {
        type = @"USER_DEVICE_LIST"; query = @{@"pageNum": @1, @"pageSize": @20, @"deviceType": @"COMMONLY_USED_DEVICE", @"choose": @YES};
    } else if (purpose == CampusOriginalPurposeDeviceInfo) {
        if (!AccountDeviceCode(device[@"resNo"]) || (device[@"deviceId"] && !AccountUID(device[@"deviceId"]))) return nil;
        type = @"DEVICE_INFO_GET";
        NSMutableDictionary *input = [@{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE", @"resNo": device[@"resNo"],
            @"needAutoSendCoupon": @NO, @"paymentChannel": @"TMXY_APP"} mutableCopy];
        if (device[@"deviceId"]) input[@"deviceId"] = device[@"deviceId"];
        query = input;
    } else if (purpose == CampusOriginalPurposeOrderDetail) {
        NSMutableDictionary *input = [@{@"isv": @"CAMPUS", @"businessType": @"WASH_AND_CARE"} mutableCopy];
        for (NSString *key in @[@"bizOrderId", @"mixBuyerId", @"isvOrderId"]) {
            if (!AccountUID(device[key])) return nil;
            input[key] = device[key];
        }
        type = @"ORDER_DETAIL_GET"; query = input;
    }
    if (!query) return nil;
    NSData *inner = [NSJSONSerialization dataWithJSONObject:query options:0 error:nil];
    NSDictionary *outer = @{@"requestType": type, @"requestJson": [[NSString alloc] initWithData:inner encoding:NSUTF8StringEncoding]};
    NSData *body = [NSJSONSerialization dataWithJSONObject:outer options:0 error:nil];
    return body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
}

static NSDictionary *AccountJSON(NSString *body) {
    if (!AccountText(body, 131072)) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static BOOL AccountBodyValid(NSString *body, CampusOriginalPurpose purpose, NSDictionary *identity) {
    NSDictionary *object = AccountJSON(body);
#ifdef CAMPUS_TIMETABLE_HOST
    if (CampusPaymentPurpose(purpose)) {
        id query = purpose <= CampusOriginalPurposeCreate ? AccountJSON(object[@"requestJson"]) : object;
        NSDictionary *expected = AccountJSON(CampusPaymentBody(purpose, query));
        if (!expected) return NO;
        // requestJson 是嵌套 JSON 字符串；字段顺序不影响契约，签名与表单仍使用原始正文。
        if (purpose <= CampusOriginalPurposeCreate)
            return object.count == 2 && [object[@"requestType"] isEqual:expected[@"requestType"]] &&
                [query isEqual:AccountJSON(expected[@"requestJson"])];
        return [object isEqual:expected];
    }
#endif
    if (purpose == CampusOriginalPurposeProfile) return [object isEqual:@{@"platForm": @"ios"}];
    if (purpose >= CampusOriginalPurposeOrders && purpose <= CampusOriginalPurposeOrderDetail) {
        NSDictionary *query = AccountJSON(object[@"requestJson"]);
        NSDictionary *device = (purpose == CampusOriginalPurposeDeviceInfo || purpose == CampusOriginalPurposeOrderDetail) ? query : nil;
        NSDictionary *expected = AccountJSON(CampusOriginalReadBody(purpose, device));
        return expected && object.count == 2 && [object[@"requestType"] isEqual:expected[@"requestType"]] &&
            [query isEqual:AccountJSON(expected[@"requestJson"])];
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
#ifdef CAMPUS_TIMETABLE_HOST
    if (CampusPaymentPurpose(purpose)) return CampusPaymentDataValid(data, purpose) ? @{@"verified": @YES} : nil;
#endif
    if (purpose == CampusOriginalPurposeLogin) {
        id value = data[@"returnValue"];
        if (![value isKindOfClass:NSDictionary.class] || !AccountText(value[@"sid"], 4096) || [value[@"sid"] containsString:@"&"]) return nil;
        NSString *uid = AccountUID(value[@"hid"]);
        return uid ? @{@"sid": value[@"sid"], @"uid": uid} : nil;
    }
    if (purpose == CampusOriginalPurposeProfile) {
        return AccountText(data[@"openUserId"], 256) || AccountText(data[@"phone"], 128) ? @{@"verified": @YES} : nil;
    }
    id inner = data[@"data"], rows = nil;
    NSUInteger maximum = 0;
    if (purpose == CampusOriginalPurposeOrders || purpose == CampusOriginalPurposeHistory) {
        if (!AccountBoolean(data[@"fail"], NO) || ![inner isKindOfClass:NSDictionary.class]) return nil;
        rows = inner[purpose == CampusOriginalPurposeOrders ? @"urgentOrderListResponse" : @"orderListResponses"];
        maximum = purpose == CampusOriginalPurposeOrders ? 20 : 10;
    } else if (purpose == CampusOriginalPurposeBuildings) {
        if (!AccountBoolean(data[@"fail"], NO)) return nil;
        rows = inner; maximum = 200;
    } else if (purpose == CampusOriginalPurposeDevices) {
        id page = data[@"pageResult"];
        if (![page isKindOfClass:NSDictionary.class] || !AccountBoolean(page[@"success"], YES)) return nil;
        rows = page[@"data"]; maximum = 20;
    } else if (purpose == CampusOriginalPurposeOrderDetail) {
        if (!AccountBoolean(data[@"fail"], NO) || ![inner isKindOfClass:NSDictionary.class]) return nil;
        id detail = inner[@"response"];
        if (![detail isKindOfClass:NSDictionary.class]) return nil;
        NSString *orderID = AccountUID(detail[@"bizOrderIdStr"] ?: detail[@"bizOrderId"]);
        if (!orderID || !AccountText(detail[@"payStatus"], 128) || !AccountText(detail[@"fulfilStatus"], 128)) return nil;
        return @{@"verified": @YES, @"bizOrderId": orderID};
    } else if (purpose == CampusOriginalPurposeDeviceInfo) {
        if (!AccountBoolean(data[@"fail"], NO) || ![inner isKindOfClass:NSDictionary.class]) return nil;
        id device = inner[@"deviceResponse"];
        if (![device isKindOfClass:NSDictionary.class] || !AccountDeviceCode(device[@"deviceCode"]) || !AccountUID(device[@"deviceId"])) return nil;
        id modes = device[@"deviceWorkingModelDTOS"];
        if (![modes isKindOfClass:NSArray.class] || [modes count] > 100) return nil;
        NSUInteger count = 0;
        for (id mode in modes) {
            if (![mode isKindOfClass:NSDictionary.class]) return nil;
            if (!AccountBoolean(mode[@"isSupport"], YES)) continue;
            id prices = mode[@"priceModelList"];
            if (![prices isKindOfClass:NSArray.class] || [prices count] > 100) return nil;
            for (id price in prices) {
                if (![price isKindOfClass:NSDictionary.class]) return nil;
                if (AccountBoolean(price[@"isOpen"], YES) && AccountText(price[@"key"], 128)) count++;
            }
        }
        id usable = device[@"deviceCanUse"];
        if (!AccountBoolean(usable, YES) && !AccountBoolean(usable, NO)) return nil;
        return @{@"verified": @YES, @"programs": @(count), @"canUse": @(AccountBoolean(usable, YES)),
            @"resNo": device[@"deviceCode"], @"deviceId": AccountUID(device[@"deviceId"])};
    }
    if (maximum) {
        if (![rows isKindOfClass:NSArray.class] || [rows count] > maximum) return nil;
        for (id row in rows) if (![row isKindOfClass:NSDictionary.class]) return nil;
        NSMutableDictionary *evidence = [@{@"verified": @YES, @"count": @([rows count])} mutableCopy];
        if (purpose == CampusOriginalPurposeHistory || purpose == CampusOriginalPurposeOrders) for (NSDictionary *row in rows) {
            NSMutableDictionary *order = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"bizOrderId", @"mixBuyerId", @"isvOrderId"]) {
                id value = [key isEqual:@"bizOrderId"] ? (row[@"bizOrderIdStr"] ?: row[key]) : row[key];
                NSString *text = AccountUID(value); if (text) order[key] = text;
            }
            if (order.count == 3) { evidence[@"order"] = [order copy]; break; }
        }
        if (purpose == CampusOriginalPurposeDevices) for (NSDictionary *row in rows) {
            NSString *deviceID = AccountUID(row[@"deviceId"]);
            if (AccountDeviceCode(row[@"deviceCode"]) && deviceID) {
                evidence[@"device"] = @{@"resNo": row[@"deviceCode"], @"deviceId": deviceID}; break;
            }
        }
        return evidence;
    }
    return nil;
}

// 仅描述固定字段的类型与真假；不打印任意键名、业务正文或身份标识。
static NSString *AccountShapeType(id value) {
    if (!value) return @"缺失";
    if (value == NSNull.null) return @"null";
    if ([value isKindOfClass:NSString.class]) {
        if (AccountBoolean(value, YES)) return @"字符串 true";
        if (AccountBoolean(value, NO)) return @"字符串 false";
        return @"其它字符串（隐藏）";
    }
    if ([value isKindOfClass:NSNumber.class]) {
        if (AccountBoolean(value, YES)) return @"数值/布尔 true";
        if (AccountBoolean(value, NO)) return @"数值/布尔 false";
        return @"其它数值（隐藏）";
    }
    if ([value isKindOfClass:NSDictionary.class]) return @"对象";
    if ([value isKindOfClass:NSArray.class]) return @"数组";
    return @"其它类型";
}

NSString *CampusOriginalAccountShape(NSData *body, CampusOriginalPurpose purpose) {
    if (!body.length || body.length > 1024 * 1024) return @"正文为空或超限";
    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    id data = [root isKindOfClass:NSDictionary.class] ? root[@"data"] : nil;
    if (![data isKindOfClass:NSDictionary.class]) return [@"data=" stringByAppendingString:AccountShapeType(data)];
    id inner = data[@"data"], leaf = nil;
    NSString *key = @"data.data";
    if (purpose == CampusOriginalPurposeDevices) {
        inner = data[@"pageResult"]; key = @"pageResult.data";
        leaf = [inner isKindOfClass:NSDictionary.class] ? inner[@"data"] : nil;
    } else if (purpose == CampusOriginalPurposeBuildings) leaf = inner;
    else {
        key = purpose == CampusOriginalPurposeOrders ? @"urgentOrderListResponse" :
            purpose == CampusOriginalPurposeHistory ? @"orderListResponses" :
            purpose == CampusOriginalPurposeOrderDetail ? @"response" : @"deviceResponse";
        leaf = [inner isKindOfClass:NSDictionary.class] ? inner[key] : nil;
    }
    NSString *flag = purpose == CampusOriginalPurposeDevices ? @"pageResult.success" : @"fail";
    id value = purpose == CampusOriginalPurposeDevices && [inner isKindOfClass:NSDictionary.class] ? inner[@"success"] : data[@"fail"];
    return [NSString stringWithFormat:@"%@=%@；内层=%@；%@=%@", flag, AccountShapeType(value), AccountShapeType(inner), key, AccountShapeType(leaf)];
}


static NSURLComponents *AccountQRURL(NSString *text) {
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    if (![url.scheme.lowercaseString isEqual:@"https"] || ![url.host.lowercaseString isEqual:@"share.confong.cn"] ||
        url.user || url.password || url.fragment || (url.port && ![url.port isEqual:@443])) return nil;
    return url;
}

static NSString *AccountQRItem(NSURLComponents *url, NSString *name) {
    NSString *value = nil; NSUInteger count = 0;
    for (NSURLQueryItem *item in url.queryItems) if ([item.name isEqual:name]) { value = item.value; count++; }
    return count == 1 && AccountText(value, 2048) ? value : nil;
}

NSString *CampusOriginalMachineNumber(NSString *contents) {
    if (![contents isKindOfClass:NSString.class] || contents.length > 2048) return nil;
    NSString *text = [contents stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (AccountDeviceCode(text)) return text;
    NSURLComponents *url = AccountQRURL(text);
    if (!url) return nil;
    if ([url.percentEncodedPath isEqual:@"/app/tmall-xiaoyuan/tmxy-m-share/laundry/deviceDetail"]) {
        NSString *nested = AccountQRItem(url, @"result");
        url = nested ? AccountQRURL(nested) : nil;
    }
    if (![url.percentEncodedPath isEqual:@"/cf"] || !AccountQRItem(url, @"biz") || !AccountQRItem(url, @"isv")) return nil;
    NSString *number = AccountQRItem(url, @"id");
    return AccountDeviceCode(number) ? number : nil;
}

static NSString *AccountDisplayText(id value, NSString *fallback) {
    return AccountText(value, 256) ? value : fallback;
}

static NSString *AccountOrderLabel(id pay, id fulfil) {
    if ([pay isEqual:@"CLOSED"]) return @"订单已关闭";
    if (![pay isEqual:@"SUCCEED"]) return @"付款尚未确认";
    if ([fulfil isEqual:@"COMPLETED"]) return @"已付款 · 洗衣完成";
    if ([fulfil isEqual:@"FULFILLING"]) return @"已付款 · 运行中";
    if ([fulfil isEqual:@"ERROR_COMPLETE"]) return @"已付款 · 服务异常，请核对订单";
    return @"已付款 · 等待设备状态确认";
}

// 仅送到本人结果页面；不写入诊断报告、剪贴板或持久化存储。
NSArray *CampusOriginalReadDisplay(NSData *body, CampusOriginalPurpose purpose) {
    if (!CampusOriginalAccountEvidence(body, purpose)) return @[];
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSDictionary *data = root[@"data"];
    NSMutableArray *result = [NSMutableArray array];
    if (purpose == CampusOriginalPurposeOrders || purpose == CampusOriginalPurposeHistory) {
        NSArray *items = data[@"data"][purpose == CampusOriginalPurposeOrders ? @"urgentOrderListResponse" : @"orderListResponses"];
        NSString *section = purpose == CampusOriginalPurposeOrders ? @"运行订单" : @"历史订单";
        if (!items.count) [result addObject:@{@"title": section, @"detail": @"本次查询暂无记录"}];
        for (NSDictionary *item in items) {
            NSString *name = AccountDisplayText(item[@"deviceName"], @"洗衣机");
            NSString *program = AccountDisplayText(item[@"workModeName"], @"程序未提供");
            NSString *status = purpose == CampusOriginalPurposeHistory ? AccountOrderLabel(item[@"payStatusEnum"], item[@"fulfilStatus"]) : @"运行列表记录；状态以详情为准";
            [result addObject:@{@"title": [NSString stringWithFormat:@"%@ · %@", section, name], @"detail": [NSString stringWithFormat:@"%@\n%@", program, status]}];
        }
    } else if (purpose == CampusOriginalPurposeOrderDetail) {
        NSDictionary *item = data[@"data"][@"response"];
        [result addObject:@{@"title": @"本人订单详情", @"detail": [NSString stringWithFormat:@"%@\n%@\n%@ %@",
            AccountDisplayText(item[@"workModeName"], @"程序未提供"), AccountOrderLabel(item[@"payStatus"], item[@"fulfilStatus"]),
            AccountDisplayText(item[@"buildingName"], @""), AccountDisplayText(item[@"floorName"], @"")]}];
    } else if (purpose == CampusOriginalPurposeDeviceInfo) {
        NSDictionary *item = data[@"data"][@"deviceResponse"];
        [result addObject:@{@"title": AccountDisplayText(item[@"deviceName"], @"洗衣机"), @"detail": [NSString stringWithFormat:@"%@ %@\n%@ · %@",
            AccountDisplayText(item[@"buildingName"], @"位置未提供"), AccountDisplayText(item[@"floorName"], @""),
            AccountBoolean(item[@"deviceCanUse"], YES) ? @"当前可用" : @"当前不可用", AccountDisplayText(item[@"workbenchStatusDESC"], @"状态描述未提供")]}];
        for (NSDictionary *mode in item[@"deviceWorkingModelDTOS"]) {
            if (!AccountBoolean(mode[@"isSupport"], YES)) continue;
            for (NSDictionary *price in mode[@"priceModelList"]) {
                if (!AccountBoolean(price[@"isOpen"], YES) || !AccountText(price[@"key"], 128)) continue;
                // price 原始单位未经换算；只显示服务器明确提供的 priceYuan。
                id rawYuan = price[@"priceYuan"];
                if ([rawYuan isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)rawYuan) != CFBooleanGetTypeID()) rawYuan = [rawYuan stringValue];
                NSString *yuan = AccountDisplayText(rawYuan, nil);
                NSRegularExpression *number = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,6}(\\.[0-9]{1,2})?$" options:0 error:nil];
                BOOL validPrice = yuan && [number numberOfMatchesInString:yuan options:0 range:NSMakeRange(0, yuan.length)] == 1;
                [result addObject:@{@"title": AccountDisplayText(price[@"desc"], @"洗衣程序"), @"detail": [NSString stringWithFormat:@"%@\n%@\n%@",
                    AccountDisplayText(price[@"defaultDetails"], @"时长说明未提供"), validPrice ? [NSString stringWithFormat:@"标示价格：%@ 元", yuan] : @"标示价格未提供",
                    @"实际应付金额尚未查询；本页仅查看，不下单"]}];
            }
        }
    }
    return result;
}
