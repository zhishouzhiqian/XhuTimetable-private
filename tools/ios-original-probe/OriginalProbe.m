#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>
#import "../../iosApp/iosApp/CampusMtopProbeInput.h"
#import "OriginalNetworkProbe.h"
#if defined(CAMPUS_TIMETABLE_HOST) || defined(CAMPUS_QUOTE_DIAGNOSTIC)
#import "../ios-timetable-host/CampusTimetablePaymentProtocol.h"
#endif
#ifdef CAMPUS_QUOTE_DIAGNOSTIC
#import "OriginalQuoteProbe.h"
#endif

#ifndef CAMPUS_ORIGINAL_PROBE_TEST
#import <UIKit/UIKit.h>
#endif

// 仅调用原程序中已有的本地 SDK 接口。报告不包含 AppKey、路径或异常正文。
static const char *ProbeType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL ProbeMethod(id object, SEL selector, NSArray<NSString *> *arguments, BOOL booleanResult) {
    if (![object respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != arguments.count + 2) return NO;
    const char *result = ProbeType(signature.methodReturnType);
    if (booleanResult ? !(result[0] == 'B' || result[0] == 'c') : result[0] != '@') return NO;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        const char *type = ProbeType([signature getArgumentTypeAtIndex:i + 2]);
        if (strcmp(type, arguments[i].UTF8String) != 0) return NO;
    }
    return YES;
}

static NSString *ProbeSHA(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *ProbeRun(
    NSDictionary *manifest, NSString *resourceRoot, void (^progress)(NSArray *),
    BOOL signLocally, NSDictionary *__autoreleasing *context) {
    NSMutableArray *rows = [NSMutableArray array];
    void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) {
        [rows addObject:@{@"step": step, @"result": result}];
        if (progress) progress([rows copy]);
    };
    emit(@"诊断方式", signLocally ? @"原程序内组件；默认资源入口；本地初始化及两次离线签名，不发送请求" :
        @"原程序内组件；准备本次匿名配置查询；默认资源入口");
    @try {
        BOOL resourcesValid = [manifest isKindOfClass:NSDictionary.class] &&
            [manifest[@"version"] isEqual:@1] &&
            [manifest[@"resources"] isKindOfClass:NSDictionary.class];
        for (NSString *name in @[@"yw_1222.jpg", @"yw_1222_mwua.jpg"]) {
            NSDictionary *expected = resourcesValid ? manifest[@"resources"][name] : nil;
            NSData *data = [NSData dataWithContentsOfFile:[resourceRoot stringByAppendingPathComponent:name]];
            BOOL valid = [expected isKindOfClass:NSDictionary.class] && data.length > 0 &&
                data.length <= 65536 && [expected[@"bytes"] isEqual:@(data.length)] &&
                [expected[@"sha256"] isKindOfClass:NSString.class] &&
                [ProbeSHA(data) isEqualToString:expected[@"sha256"]];
            emit(name, valid ? [NSString stringWithFormat:@"与制作副本时一致；%lu 字节", (unsigned long)data.length] :
                @"原配资源核对失败；不调用 SDK");
            resourcesValid = resourcesValid && valid;
        }
        if (!resourcesValid) return [rows copy];
        Class managerClass = NSClassFromString(@"SecurityGuardManager");
        SEL getInstance = NSSelectorFromString(@"getInstance");
        if (!ProbeMethod(managerClass, getInstance, @[], NO)) {
            emit(@"内部管理器", @"类、默认入口或方法类型不符合已核对形式");
            return [rows copy];
        }
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, getInstance);
        emit(@"内部管理器", manager ? @"默认入口返回实例；不等同于全部初始化成功" : @"默认入口返回空值");
        if (!manager) return [rows copy];
        SEL sdkVersion = NSSelectorFromString(@"getSDKVersion");
        if (ProbeMethod(manager, sdkVersion, @[], NO)) {
            id version = ((id (*)(id, SEL))objc_msgSend)(manager, sdkVersion);
            NSCharacterSet *characters = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
            BOOL valid = [version isKindOfClass:NSString.class] && [version length] > 0 && [version length] < 40 &&
                [version rangeOfCharacterFromSet:characters.invertedSet].location == NSNotFound;
            emit(@"SDK 版本", valid ? version : @"未返回可展示版本");
        }
        SEL getStore = NSSelectorFromString(@"getStaticDataStoreComp");
        id store = ProbeMethod(manager, getStore, @[], NO) ?
            ((id (*)(id, SEL))objc_msgSend)(manager, getStore) : nil;
        emit(@"静态存储组件", store ? @"可获取" : @"入口不匹配或返回空值");
        // 原校园先初始化内部管理器并读取包装器；包装器自行转发 Open、authCode:nil。
        SEL getKey = NSSelectorFromString(@"getAppKey:");
        NSString *appKey = nil;
        if (ProbeMethod(store, getKey, @[@"@"], NO)) {
            id value = ((id (*)(id, SEL, id))objc_msgSend)(store, getKey, @0);
            BOOL valid = [value isKindOfClass:NSString.class] && [value length] > 0;
            if (valid) appKey = value;
            emit(@"AppKey 索引 0", valid ? @"读取成功（值不展示）" :
                @"空值；接口无 NSError；本诊断未捕获底层日志错误码");
        } else emit(@"AppKey 索引 0", @"方法类型不匹配；未调用");
        Class openClass = NSClassFromString(@"OpenSecurityGuardManager");
        id openManager = ProbeMethod(openClass, getInstance, @[], NO) ?
            ((id (*)(id, SEL))objc_msgSend)(openClass, getInstance) : nil;
        emit(@"Open 管理器", openManager ? @"默认入口返回实例" : @"入口不匹配或返回空值");
        SEL getInterface = NSSelectorFromString(@"getInterface:");
        Protocol *protocol = NSProtocolFromString(@"ISecurityGuardOpenUnifiedSecurity");
        id unified = protocol && ProbeMethod(openManager, getInterface, @[@"@"], NO) ?
            ((id (*)(id, SEL, id))objc_msgSend)(openManager, getInterface, protocol) : nil;
        emit(@"统一签名接口", unified ? @"可获取" : @"协议、入口不匹配或返回空值");
        SEL initialize = NSSelectorFromString(@"init:error:");
        BOOL initialized = NO;
        if (ProbeMethod(unified, initialize, @[@"@", @"^@"], YES)) {
            NSError *error = nil;
            // 6.8 已核对读取 authCode/flag/customBundelPath；空字典保留默认 nil/nil/0。
            // 不复制调用层未被消费的 auth_code，也不更换原应用资源目录。
            BOOL ready = ((BOOL (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(unified, initialize, @{}, &error);
            initialized = ready && error == nil;
            emit(@"统一签名初始化", ready && error == nil ? @"成功" : error ?
                [NSString stringWithFormat:@"失败（SDK 错误码 %ld）", (long)error.code] : @"失败；未提供错误码");
        } else emit(@"统一签名初始化", @"方法类型不匹配；未调用");
        if (!signLocally) {
            if (initialized && appKey.length && context) *context = @{@"appKey": appKey, @"unified": unified, @"openManager": openManager};
            return [rows copy];
        }
        SEL factorsSelector = NSSelectorFromString(@"getSecurityFactors:error:");
        if (!initialized || !appKey.length) {
            emit(@"离线签名", @"跳过：初始化未成功或 AppKey 为空");
        } else if (!ProbeMethod(unified, factorsSelector, @[@"@", @"^@"], NO)) {
            emit(@"离线签名", @"方法类型不匹配；未调用");
        } else {
            unsigned char randomBytes[18];
            arc4random_buf(randomBytes, sizeof(randomBytes));
            NSString *utdid = [[NSData dataWithBytes:randomBytes length:sizeof(randomBytes)] base64EncodedStringWithOptions:0];
            NSString *timestamp = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970];
            NSString *previous = nil;
            emit(@"签名输入", @"iOS MTOP 22 字段；秒级时间与正文 MD5；临时随机标识未注册；第二次仅改变正文及请求编号");
            for (NSUInteger attempt = 0; attempt < 2; attempt++) {
                NSString *stage = attempt == 0 ? @"第一次离线签名" : @"改变正文后离线签名";
                emit(stage, @"正在执行");
                NSData *body = [NSJSONSerialization dataWithJSONObject:
                    @{@"device_global_id": utdid, @"probe_nonce": @(attempt)} options:0 error:nil];
                NSString *input = CampusMtopProbeSignData(body, utdid, appKey, @"mtop.sys.newdeviceid", @"4.0",
                    @{@"x-t": timestamp, @"x-ttid": @"campus-ios-original-probe"});
                if (!input) { emit(stage, @"输入组装失败；未调用"); break; }
                NSError *error = nil;
                id result = ((id (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(unified, factorsSelector,
                    @{@"appkey": appKey, @"data": input, @"api": @"mtop.sys.newdeviceid", @"useWua": @NO,
                      @"env": @0, @"extendParas": @{}, @"requestId": NSUUID.UUID.UUIDString}, &error);
                BOOL complete = CampusMtopProbeFactorsComplete(result, error);
                emit(stage, complete ? @"必需字段完整（值不展示）；仅证明本地生成" : error ?
                    [NSString stringWithFormat:@"失败（SDK 错误码 %ld）", (long)error.code] : @"必需字段不完整；不能判定签名成功");
                NSDictionary *factors = [result isKindOfClass:NSDictionary.class] ? result : nil;
                for (NSString *key in @[@"x-sign", @"x-mini-wua", @"x-umt", @"x-sgext"]) {
                    id value = factors[key];
                    emit([stage stringByAppendingFormat:@" / %@", key],
                        [value isKindOfClass:NSString.class] && [value length] > 0 ? @"已生成（值不展示）" : @"为空或类型不符");
                }
                NSString *sign = complete ? factors[@"x-sign"] : nil;
                if (attempt == 0) previous = sign;
                else emit(@"签名输入变化对照", previous.length && sign.length ?
                    ([previous isEqualToString:sign] ? @"相同，需继续分析" : @"不同，已随输入变化") : @"缺少完整签名，无法比较");
            }
        }
    } @catch (NSException *exception) {
        emit(@"本地检查", @"发生异常（正文不展示）");
    }
    emit(@"验证边界", @"仅离线生成诊断安全字段；未发送请求、未验证服务器、未登录或下单；原二进制加载期活动不在诊断控制范围内");
    return [rows copy];
}

NSArray *CampusOriginalProbeRun(NSDictionary *manifest, NSString *resourceRoot, void (^progress)(NSArray *)) {
    return ProbeRun(manifest, resourceRoot, progress, YES, NULL);
}

// SDK/设备参数仅存在本次函数及请求内存中；不保存候选 URL 或安全字段。
static NSURLRequest *ProbeAnonymousRequest(NSDictionary *context, void (^emit)(NSString *, NSString *)) {
    Class utdidClass = NSClassFromString(@"TBSDKNetworkSDKUtil");
    SEL identifier = NSSelectorFromString(@"utdid");
    if (!ProbeMethod(utdidClass, identifier, @[], NO)) {
        emit(@"设备上下文", @"原 UTDID 入口类型不匹配；未发送"); return nil;
    }
    id utdid = ((id (*)(id, SEL))objc_msgSend)(utdidClass, identifier);
    id repeat = ((id (*)(id, SEL))objc_msgSend)(utdidClass, identifier);
    Class deviceClass = NSClassFromString(@"UTDevice");
    id direct = ProbeMethod(deviceClass, identifier, @[], NO) ?
        ((id (*)(id, SEL))objc_msgSend)(deviceClass, identifier) : nil;
    BOOL stringValue = [utdid isKindOfClass:NSString.class];
    NSData *decoded = stringValue ? [[NSData alloc] initWithBase64EncodedString:utdid options:0] : nil;
    BOOL validDevice = stringValue && [utdid length] == 24 && decoded.length == 18;
    BOOL stable = stringValue && [repeat isKindOfClass:NSString.class] && [utdid isEqualToString:repeat];
    BOOL same = stringValue && [direct isKindOfClass:NSString.class] && [utdid isEqualToString:direct];
    emit(@"设备入口", @"原 MTOP 的 TBSDKNetworkSDKUtil.utdid → UTDevice.utdid；不使用 uniqueGlobalDeviceIdentifier");
    emit(@"UTDID 形状", stringValue ? [NSString stringWithFormat:@"%lu 字符；Base64 解码 %lu 字节；%@（值不展示）",
        (unsigned long)[utdid length], (unsigned long)decoded.length, validDevice ? @"格式通过" : @"格式不符"] : @"返回值不是字符串");
    emit(@"UTDID 重复读取", stable ? @"两次一致" : @"不一致或无法读取；不使用随机替代值");
    emit(@"UTDID 原入口对照", same ? @"MTOP 包装器与 UTDevice 返回值一致" : @"不同或原入口不可用");
    Class appClass = NSClassFromString(@"AppInfo");
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *name in @[@"channel", @"bundleName", @"version"]) {
        SEL selector = NSSelectorFromString(name);
        id value = ProbeMethod(appClass, selector, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(appClass, selector) : nil;
        if (![value isKindOfClass:NSString.class] || ![value length]) {
            emit(@"应用协议参数", @"原 AppInfo 参数缺失；未发送"); return nil;
        }
        [parts addObject:value];
    }
    NSString *ttid = [NSString stringWithFormat:@"%@@%@_iPhone_%@", parts[0], parts[1], parts[2]];
    SEL keySelector = NSSelectorFromString(@"appKey");
    id networkKey = ProbeMethod(appClass, keySelector, @[], NO) ?
        ((id (*)(id, SEL))objc_msgSend)(appClass, keySelector) : nil;
    if (![networkKey isKindOfClass:NSString.class] || ![networkKey length]) {
        emit(@"校园请求 AppKey", @"原 AppInfo 入口不可用；未发送"); return nil;
    }
    emit(@"校园请求 AppKey", [networkKey isEqualToString:context[@"appKey"]] ?
        @"原 AppInfo 返回值与索引 0 一致（值不展示）" : @"原 AppInfo 返回值与索引 0 不同；请求使用原 AppInfo 值（均不展示）");
    if (!validDevice || !stable || !same) {
        emit(@"设备上下文", @"格式、稳定性或原入口对照未通过；未发送"); return nil;
    }
    Class encoder = NSClassFromString(@"TBSDKMTOPEnvConfig");
    SEL encode = NSSelectorFromString(@"urlEncodeString:");
    if (!ProbeMethod(encoder, encode, @[@"@"], NO) || ![utdid isKindOfClass:NSString.class] || ![utdid length]) {
        emit(@"设备与编码入口", @"原 UTDID 或编码方法不可用；未发送"); return nil;
    }
    NSString *(^encodeValue)(NSString *) = ^NSString *(NSString *value) {
        return ((id (*)(id, SEL, id))objc_msgSend)(encoder, encode, value);
    };
    // 原 5.7.2 setHTTPRequestHeader 使用 x-pv=6.3；不复制 Android 的 TTID。
    NSString *time = [NSString stringWithFormat:@"%lld", (long long)NSDate.date.timeIntervalSince1970];
    NSData *body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *input = CampusMtopProbeSignData(body, utdid, networkKey, CampusOriginalConfigAPI, @"1.0",
        @{@"x-t": time, @"x-ttid": ttid});
    id unified = context[@"unified"];
    SEL sign = NSSelectorFromString(@"getSecurityFactors:error:");
    if (!input || !ProbeMethod(unified, sign, @[@"@", @"^@"], NO)) {
        emit(@"本次配置查询签名", @"输入或接口类型不符合要求；未发送"); return nil;
    }
    NSError *error = nil;
    id factors = ((id (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(unified, sign,
        @{@"appkey": networkKey, @"data": input, @"api": CampusOriginalConfigAPI, @"useWua": @NO,
          @"env": @0, @"extendParas": @{}, @"requestId": NSUUID.UUID.UUIDString}, &error);
    if (!CampusMtopProbeFactorsComplete(factors, error)) {
        emit(@"本次配置查询签名", error ? [NSString stringWithFormat:@"失败（SDK 错误码 %ld）；未发送", (long)error.code] :
            @"字段不完整；未发送"); return nil;
    }
    for (NSDictionary *row in CampusOriginalConfigPreflight(networkKey, utdid, ttid, time, factors, encodeValue)) {
        emit(row[@"step"], row[@"result"]);
    }
    NSString *reason = nil;
    NSURLRequest *request = CampusOriginalConfigRequestChecked(networkKey, utdid, ttid, time, factors, encodeValue, &reason);
    emit(@"设备上下文", @"使用原 UTDID 组件返回值；不展示；未据此认定新设备已注册");
    emit(@"本次请求一致性", request ? @"固定空正文、时间及设备参数；四个字段完整；原编码入口核对通过" :
        [NSString stringWithFormat:@"%@；未发送", reason ?: @"构造失败；原因未提供"]);
    return request;
}

#ifdef CAMPUS_ORIGINAL_PROBE_TEST
NSURLRequest *CampusOriginalProbeTestRequest(NSDictionary *context) {
    return ProbeAnonymousRequest(context, ^(NSString *step, NSString *result) {});
}
#endif

static NSDictionary *ProbeRequestIdentity(NSURLRequest *request) {
    NSMutableDictionary *identity = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"x-appkey", @"x-utdid", @"x-ttid", @"x-mini-wua", @"x-umt"]) {
        NSString *value = [request valueForHTTPHeaderField:key].stringByRemovingPercentEncoding;
        if (!value.length) return nil;
        identity[key] = value;
    }
    return identity;
}

static void ProbeLocalCredentials(NSDictionary *context, NSDictionary *identity,
                                  void (^emit)(NSString *, NSString *)) {
    // 只调用本地 getter 与生成方法；不调用 UMID 初始化/注册或登录接口。
    @try {
        id manager = context[@"openManager"];
        SEL getUMID = NSSelectorFromString(@"getUMIDComp");
        id umid = ProbeMethod(manager, getUMID, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(manager, getUMID) : nil;
        SEL getToken = NSSelectorFromString(@"getSecurityToken");
        emit(@"UMID 本地读取", @"正在执行本地 getter");
        id token = ProbeMethod(umid, getToken, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(umid, getToken) : nil;
        BOOL valid = [token isKindOfClass:NSString.class] && [token length] > 0;
        emit(@"UMID 本地读取", valid ? @"返回非空值（不展示）；未调用 UMID 注册" : @"组件、方法类型或返回值未通过");
        if (valid) emit(@"UMID 与签名 x-umt 对照", [token isEqual:identity[@"x-umt"]] ? @"相同；仅为本次本地对照" : @"不同；不能仅据此判定请求无效");
    } @catch (NSException *exception) { emit(@"UMID 本地读取", @"发生异常（正文隐藏）；其它检查继续"); }
    @try {
        id manager = context[@"openManager"];
        SEL getBody = NSSelectorFromString(@"getSecurityBodyComp");
        id body = ProbeMethod(manager, getBody, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(manager, getBody) : nil;
        SEL generate = NSSelectorFromString(@"getSecurityBodyDataEx:appKey:authCode:extendParam:flag:env:error:");
        // 原 Open 接口 flag/env 为 32 位 int，不能改成 NSInteger。
        if (!ProbeMethod(body, generate, @[@"@", @"@", @"@", @"@", @"i", @"i", @"^@"], NO)) {
            emit(@"候选完整 WUA", @"组件或方法类型不匹配；未调用"); return;
        }
        NSError *error = nil;
        NSString *milliseconds = [NSString stringWithFormat:@"%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
        emit(@"候选完整 WUA", @"正在执行本地生成；不调用登录接口");
        id value = ((id (*)(id, SEL, id, id, id, id, int, int, NSError *__autoreleasing *))objc_msgSend)(
            body, generate, milliseconds, identity[@"x-appkey"], nil, nil, 4, 0, &error);
        BOOL valid = !error && [value isKindOfClass:NSString.class] && [value length] > 0;
        emit(@"候选完整 WUA", valid ? @"本地返回非空值（不展示）；尚未验证登录接口接受性" : error ?
            [NSString stringWithFormat:@"失败（SDK 错误码 %ld）", (long)error.code] : @"返回空值或类型不符");
        if (valid) emit(@"WUA 与 x-mini-wua 对照", [value isEqual:identity[@"x-mini-wua"]] ? @"相同；需继续核对用途" : @"不同；不能互相替代");
    } @catch (NSException *exception) { emit(@"候选完整 WUA", @"发生异常（正文隐藏）；其它检查继续"); }
}

@protocol CampusOriginalRequestConstruction <NSObject>
- (instancetype)initWithApiName:(NSString *)api apiVersion:(NSString *)version;
@end

static NSURLRequest *ProbeDeviceRequest(NSDictionary *context, NSDictionary *identity, NSString *deviceID,
                                       CampusOriginalPurpose purpose, void (^emit)(NSString *, NSString *)) {
    Class device = NSClassFromString(@"TBSDKNetworkSDKUtil");
    SEL utdidSelector = NSSelectorFromString(@"utdid");
    id current = ProbeMethod(device, utdidSelector, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(device, utdidSelector) : nil;
    if (![identity[@"x-utdid"] isEqual:current]) { emit(@"跨阶段设备标识", @"发生变化或入口不可用；未发送"); return nil; }
    NSString *body = @"{}", *api = CampusOriginalConfigAPI, *version = @"1.0";
    if (purpose == CampusOriginalPurposeRegister) {
        // 原程序 UIDevice(TBNewSDKIdentifierAddition) 两个类方法；不使用系统 UUID 替代。
        Class profile = NSClassFromString(@"UIDevice");
        SEL platform = NSSelectorFromString(@"tbsdkPlatform"), mac = NSSelectorFromString(@"tbsdkMacaddress");
        if (!ProbeMethod(profile, platform, @[], NO) || !ProbeMethod(profile, mac, @[], NO)) {
            emit(@"iOS 注册设备参数", @"原 UIDevice 分类入口未通过；未发送"); return nil;
        }
        body = CampusOriginalRegistrationBody(current, ((id (*)(id, SEL))objc_msgSend)(profile, platform),
            ((id (*)(id, SEL))objc_msgSend)(profile, mac));
        if (!body) { emit(@"iOS 注册设备参数", @"原入口返回值或注册正文未通过；未发送"); return nil; }
        // 让原请求对象完成 API 名称处理，再读取其实际签名名称，避免猜测大小写。
        Class requestClass = NSClassFromString(@"MtopExtRequest");
        SEL initialize = NSSelectorFromString(@"initWithApiName:apiVersion:");
        id<CampusOriginalRequestConstruction> original = [requestClass alloc];
        if (!ProbeMethod(original, initialize, @[@"@", @"@"], NO)) {
            emit(@"注册 API 原入口", @"请求对象入口不匹配；未发送"); return nil;
        }
        // init 方法按 ARC 的初始化所有权约定调用，不通过普通返回值 cast。
        original = [original initWithApiName:CampusOriginalRegisterAPI apiVersion:@"4.0"];
        // 外层 MtopExtRequest 用 getApiName/getApiVersion，内部 TBSDKRequest 才用 apiName/apiVersion。
        SEL apiName = NSSelectorFromString(@"getApiName"), apiVersion = NSSelectorFromString(@"getApiVersion");
        if (!ProbeMethod(original, apiName, @[], NO) || !ProbeMethod(original, apiVersion, @[], NO)) {
            emit(@"注册 API 原入口", @"原 getApiName/getApiVersion 方法类型未通过；未发送"); return nil;
        }
        id actualAPI = ((id (*)(id, SEL))objc_msgSend)(original, apiName);
        id actualVersion = ((id (*)(id, SEL))objc_msgSend)(original, apiVersion);
        if (![actualAPI isEqual:CampusOriginalRegisterAPI] && ![actualAPI isEqual:CampusOriginalRegisterAPI.lowercaseString]) {
            emit(@"注册 API 原入口", [actualAPI isKindOfClass:NSString.class] && [actualAPI length] ?
                @"原 getApiName 返回名称不符合已核对 API；未发送" : @"原 getApiName 返回空值或类型不符；未发送"); return nil;
        }
        if (![actualVersion isKindOfClass:NSString.class] || ![actualVersion isEqual:@"4.0"]) {
            emit(@"注册 API 原入口", @"原 getApiVersion 返回值未通过 4.0 对照；未发送"); return nil;
        }
        api = actualAPI; version = actualVersion;
        emit(@"注册 API 原入口", [api isEqual:CampusOriginalRegisterAPI] ? @"原 getApiName/getApiVersion 通过；保留原 API 大小写；网关路径小写" :
            @"原 getApiName/getApiVersion 通过；原请求对象已转小写；使用原返回值签名");
        emit(@"iOS 注册设备参数", @"原 UIDevice 分类返回值；10 个原 iOS 字段；不展示标识或正文");
    }
    NSString *time = [NSString stringWithFormat:@"%lld", (long long)NSDate.date.timeIntervalSince1970];
    NSMutableDictionary *headers = [@{@"x-t": time, @"x-ttid": identity[@"x-ttid"]} mutableCopy];
    if (deviceID) headers[@"x-devid"] = deviceID;
    NSString *input = CampusMtopProbeSignData([body dataUsingEncoding:NSUTF8StringEncoding], current,
        identity[@"x-appkey"], api, version, headers);
    id unified = context[@"unified"];
    SEL sign = NSSelectorFromString(@"getSecurityFactors:error:");
    if (!input || !ProbeMethod(unified, sign, @[@"@", @"^@"], NO)) { emit(@"阶段签名", @"输入或接口未通过；未发送"); return nil; }
    NSError *error = nil;
    emit(purpose == CampusOriginalPurposeRegister ? @"设备注册签名" : @"设备 ID 复用签名", @"正在生成本阶段安全字段");
    id factors = ((id (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(unified, sign,
        @{@"appkey": identity[@"x-appkey"], @"data": input, @"api": api, @"useWua": @NO, @"env": @0,
          @"extendParas": @{}, @"requestId": NSUUID.UUID.UUIDString}, &error);
    if (!CampusMtopProbeFactorsComplete(factors, error)) {
        emit(@"阶段签名", error ? [NSString stringWithFormat:@"失败（SDK 错误码 %ld）；未发送", (long)error.code] : @"四字段不完整；未发送"); return nil;
    }
    Class encoder = NSClassFromString(@"TBSDKMTOPEnvConfig"); SEL encode = NSSelectorFromString(@"urlEncodeString:");
    if (!ProbeMethod(encoder, encode, @[@"@"], NO)) { emit(@"阶段编码", @"原入口未通过；未发送"); return nil; }
    NSString *reason = nil;
    NSURLRequest *request = CampusOriginalDeviceRequest(identity[@"x-appkey"], current, identity[@"x-ttid"], time,
        body, factors, deviceID, purpose, ^NSString *(NSString *value) { return ((id (*)(id, SEL, id))objc_msgSend)(encoder, encode, value); }, &reason);
    // 签名和 URL 必须复用同一份正文，不重新序列化 JSON。
    NSURLComponents *url = request ? [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES] : nil;
    BOOL sameBody = [url.percentEncodedQuery hasPrefix:@"data="] &&
        [[[url.percentEncodedQuery substringFromIndex:5] stringByRemovingPercentEncoding] isEqual:body];
    BOOL sameID = deviceID ? [[request valueForHTTPHeaderField:@"x-devid"].stringByRemovingPercentEncoding isEqual:deviceID] &&
        [[[input componentsSeparatedByString:@"&"] objectAtIndex:10] isEqual:deviceID] : YES;
    emit(purpose == CampusOriginalPurposeRegister ? @"设备注册请求一致性" : @"设备 ID 复用请求一致性", request && sameBody && sameID ? @"正文 UTF-8/MD5 来源一致；编码回读一致；设备 ID 签名与请求头一致；四字段完整" :
        [NSString stringWithFormat:@"%@；未发送", reason ?: @"正文或设备 ID 对照失败"]);
    return sameBody && sameID ? request : nil;
}

#ifdef CAMPUS_ORIGINAL_PROBE_TEST
NSURLRequest *CampusOriginalProbeTestDeviceRequest(NSDictionary *context, NSDictionary *identity, NSString *deviceID, CampusOriginalPurpose purpose) {
    return ProbeDeviceRequest(context, identity, deviceID, purpose, ^(NSString *step, NSString *result) {});
}
NSArray *CampusOriginalProbeTestCredentials(NSDictionary *context, NSDictionary *identity) {
    NSMutableArray *rows = [NSMutableArray array];
    ProbeLocalCredentials(context, identity, ^(NSString *step, NSString *result) { [rows addObject:@{@"step": step, @"result": result}]; });
    return rows;
}
#endif

void CampusOriginalProbeNetworkRun(NSDictionary *manifest, NSString *resourceRoot,
                                  void (^progress)(NSArray *), void (^ready)(NSDictionary *), void (^completion)(NSArray *)) {
    NSDictionary *context = nil;
    NSMutableArray *rows = [ProbeRun(manifest, resourceRoot, progress, NO, &context) mutableCopy];
    void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) {
        [rows addObject:@{@"step": step, @"result": result}];
        if (progress) progress([rows copy]);
    };
    NSURLRequest *request = nil;
    @try {
        if (context) request = ProbeAnonymousRequest(context, emit);
        else emit(@"联网检查", @"初始化或资源未通过；未发送");
    } @catch (NSException *exception) { emit(@"联网准备", @"发生异常（正文隐藏）；未发送"); }
    if (!request) { completion([rows copy]); return; }
    NSDictionary *identity = ProbeRequestIdentity(request);
    if (!identity) { emit(@"阶段上下文", @"请求头回读失败；未发送"); completion([rows copy]); return; }
    ProbeLocalCredentials(context, identity, emit);
    emit(@"联网范围", @"最多三个串行任务：匿名配置、设备注册、带返回 ID 的配置；无 Cookie、账号或会话；禁止跳转，无应用层自动重试");
    CampusOriginalConfigSend(request, ^(NSDictionary *outcome) {
        emit(@"匿名配置响应", outcome[@"summary"]);
        if (![outcome[@"success"] boolValue]) {
            emit(@"后续设备检查", @"跳过：匿名基线未通过；本地凭据检查结果已保留"); completion([rows copy]); return;
        }
        NSURLRequest *registration = nil;
        @try { registration = ProbeDeviceRequest(context, identity, nil, CampusOriginalPurposeRegister, emit); }
        @catch (NSException *exception) { emit(@"注册准备", @"发生异常（正文隐藏）；未发送"); }
        if (!registration) { completion([rows copy]); return; }
        CampusOriginalDeviceSend(registration, CampusOriginalPurposeRegister, ^(NSDictionary *registered, NSString *deviceID) {
            emit(@"设备注册响应", registered[@"summary"]);
            if (![registered[@"success"] boolValue] || !deviceID) {
                emit(@"设备 ID 复用", @"跳过：注册或返回 ID 未通过"); completion([rows copy]); return;
            }
            emit(@"返回设备 ID", [NSString stringWithFormat:@"data.device_id：%lu 字符；有界字符串通过（值不展示）；仅保留本次内存，不写入原 SDK 状态", (unsigned long)deviceID.length]);
            NSURLRequest *reuse = nil;
            @try { reuse = ProbeDeviceRequest(context, identity, deviceID, CampusOriginalPurposeReuse, emit); }
            @catch (NSException *exception) { emit(@"复用准备", @"发生异常（正文隐藏）；未发送"); }
            if (!reuse) { completion([rows copy]); return; }
            CampusOriginalDeviceSend(reuse, CampusOriginalPurposeReuse, ^(NSDictionary *reused, NSString *unused) {
                emit(@"带设备 ID 配置响应", reused[@"summary"]);
                emit(@"验收结论", [reused[@"success"] boolValue] ?
                    @"匿名基线、设备注册、返回 ID 的重新签名配置均通过；尚未验证登录或洗衣" :
                    @"匿名基线与注册通过，带 ID 的配置未通过；不能据此判定登录或洗衣可用");
                if ([reused[@"success"] boolValue] && ready) {
                    NSMutableDictionary *prepared = [context mutableCopy];
                    [prepared addEntriesFromDictionary:identity]; prepared[@"deviceID"] = deviceID;
                    ready([prepared copy]);
                }
                completion([rows copy]);
            });
        });
    });
}

static BOOL ProbeSetObject(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 3 || strcmp(ProbeType(signature.methodReturnType), "v") ||
        strcmp(ProbeType([signature getArgumentTypeAtIndex:2]), "@")) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value); return YES;
}

static NSDictionary *ProbeModelJSON(id model) {
    Class json = NSClassFromString(@"ALBBJSON"); SEL serialize = NSSelectorFromString(@"objectToJsonString:");
    if (!ProbeMethod(json, serialize, @[@"@"], NO)) return nil;
    id value = ((id (*)(id, SEL, id))objc_msgSend)(json, serialize, model);
    if (![value isKindOfClass:NSString.class] || [value length] > 131072) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *ProbeLoginBody(NSDictionary *context, NSString *code, void (^emit)(NSString *, NSString *)) {
    id info = [[NSClassFromString(@"ALBBOAuthLoginInfo") alloc] init];
    id risk = [[NSClassFromString(@"ALBBRiskControlInfo") alloc] init];
    if (!info || !risk) { emit(@"原 iOS 登录模型", @"模型入口不可用；未发送"); return nil; }
    NSDictionary *values = @{@"setAppName:": context[@"x-appkey"], @"setUtdid:": context[@"x-utdid"],
        @"setTtid:": context[@"x-ttid"], @"setDeviceId:": context[@"deviceID"], @"setToken:": code,
        @"setSnsType:": @"taobao", @"setSite:": @"96", @"setLocale:": @"zh_CN", @"setExt:": @{}};
    for (NSString *name in values) if (!ProbeSetObject(info, name, values[name])) {
        emit(@"原 iOS 登录模型", @"对象 setter 类型未通过；未发送"); return nil;
    }
    for (NSString *name in @[@"setHid:", @"setDeviceTokenKey:", @"setDeviceTokenSign:"]) {
        if (!ProbeSetObject(info, name, nil)) { emit(@"原 iOS 登录模型", @"旧会话清理 setter 未通过；未发送"); return nil; }
    }
    // 原模型这两项是 NSNumber 对象 setter，不能按 BOOL ABI 调用。
    if (!ProbeSetObject(info, @"setUseAcitonType:", @YES) || !ProbeSetObject(info, @"setUseDeviceToken:", @YES)) {
        emit(@"原 iOS 登录模型", @"开关对象 setter 类型未通过；未发送"); return nil;
    }
    id manager = context[@"openManager"];
    SEL getUMID = NSSelectorFromString(@"getUMIDComp"), getBody = NSSelectorFromString(@"getSecurityBodyComp");
    if (!ProbeMethod(manager, getUMID, @[], NO) || !ProbeMethod(manager, getBody, @[], NO)) {
        emit(@"本次登录风控", @"原组件 getter 类型未通过；未发送"); return nil;
    }
    id umid = ((id (*)(id, SEL))objc_msgSend)(manager, getUMID);
    id securityBody = ((id (*)(id, SEL))objc_msgSend)(manager, getBody);
    SEL token = NSSelectorFromString(@"getSecurityToken");
    SEL generate = NSSelectorFromString(@"getSecurityBodyDataEx:appKey:authCode:extendParam:flag:env:error:");
    if (!ProbeMethod(umid, token, @[], NO) || !ProbeMethod(securityBody, generate, @[@"@", @"@", @"@", @"@", @"i", @"i", @"^@"], NO)) {
        emit(@"本次登录风控", @"原 UMID/WUA 方法类型未通过；未发送"); return nil;
    }
    NSString *milliseconds = [NSString stringWithFormat:@"%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
    NSError *error = nil;
    id wua = ((id (*)(id, SEL, id, id, id, id, int, int, NSError *__autoreleasing *))objc_msgSend)(securityBody, generate,
        milliseconds, context[@"x-appkey"], nil, nil, 4, 0, &error);
    id umidValue = ((id (*)(id, SEL))objc_msgSend)(umid, token);
    if (error || ![wua isKindOfClass:NSString.class] || ![wua length] || ![umidValue isKindOfClass:NSString.class] || ![umidValue length]) {
        emit(@"本次登录风控", error ? [NSString stringWithFormat:@"WUA 失败（SDK 错误码 %ld）；未发送", (long)error.code] : @"WUA/UMID 缺失；未发送"); return nil;
    }
    SEL addDevice = NSSelectorFromString(@"addDeviceInfo");
    NSMethodSignature *deviceSignature = [risk respondsToSelector:addDevice] ? [risk methodSignatureForSelector:addDevice] : nil;
    if (deviceSignature.numberOfArguments != 2 || strcmp(ProbeType(deviceSignature.methodReturnType), "v")) {
        emit(@"本次登录风控", @"原 addDeviceInfo 方法类型未通过；未发送"); return nil;
    }
    ((void (*)(id, SEL))objc_msgSend)(risk, addDevice);
    if (!ProbeSetObject(risk, @"setWua:", wua) || !ProbeSetObject(risk, @"setUmidToken:", umidValue) ||
        !ProbeSetObject(risk, @"setApdId:", umidValue) || !ProbeSetObject(risk, @"setT:", milliseconds)) {
        emit(@"本次登录风控", @"风险模型 setter 类型未通过；未发送"); return nil;
    }
    NSDictionary *infoJSON = ProbeModelJSON(info);
    if (![infoJSON[@"sdkVersion"] isKindOfClass:NSString.class] || ![infoJSON[@"sdkVersion"] length]) {
        // 此原样本的存储实现 getter 只返回 SDK 自身的版本常量；不初始化完整账号中心。
        id storage = [[NSClassFromString(@"ALBBSecurityStorageImpl") alloc] init];
        SEL version = NSSelectorFromString(@"getSdkVersion");
        id value = ProbeMethod(storage, version, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(storage, version) : nil;
        if (![value isKindOfClass:NSString.class] || ![value length] || !ProbeSetObject(info, @"setSdkVersion:", value)) {
            emit(@"原 iOS 登录模型", @"登录 SDK 版本原入口未通过；未发送"); return nil;
        }
        infoJSON = ProbeModelJSON(info);
    }
    NSString *body = CampusOriginalLoginBody(infoJSON, ProbeModelJSON(risk), context, code);
    emit(@"本次登录风控", body ? @"原模型序列化通过；本次生成完整 WUA/UMID；账号旧状态未用于请求（值隐藏）" :
        @"原模型返回值或身份对照未通过；未发送");
    return body;
}

#ifdef CAMPUS_ORIGINAL_PROBE_TEST
NSString *CampusOriginalProbeTestLoginBody(NSDictionary *context, NSString *code) {
    return ProbeLoginBody(context, code, ^(NSString *step, NSString *result) {});
}
#endif

static NSURLRequest *ProbeAccountRequest(NSDictionary *context, NSString *body, NSDictionary *session,
                                        CampusOriginalPurpose purpose, void (^emit)(NSString *, NSString *)) {
    emit(purpose == CampusOriginalPurposeLogin ? @"会话交换请求" : purpose == CampusOriginalPurposeProfile ? @"本人资料请求" : @"洗衣只读请求",
        @"正在生成本阶段签名与 POST 请求");
    Class device = NSClassFromString(@"TBSDKNetworkSDKUtil"); SEL utdid = NSSelectorFromString(@"utdid");
    id current = ProbeMethod(device, utdid, @[], NO) ? ((id (*)(id, SEL))objc_msgSend)(device, utdid) : nil;
    if (![context[@"x-utdid"] isEqual:current]) { emit(@"登录/只读设备对照", @"原 UTDID 变化；未发送"); return nil; }
    NSString *api = CampusOriginalAccountAPI(purpose);
    NSString *time = [NSString stringWithFormat:@"%lld", (long long)NSDate.date.timeIntervalSince1970];
    NSMutableDictionary *headers = [@{@"x-t": time, @"x-ttid": context[@"x-ttid"], @"x-devid": context[@"deviceID"]} mutableCopy];
    if (session) { headers[@"x-sid"] = session[@"sid"]; headers[@"x-uid"] = session[@"uid"]; }
    NSString *input = CampusMtopProbeSignData([body dataUsingEncoding:NSUTF8StringEncoding], current, context[@"x-appkey"], api, @"1.0", headers);
    id unified = context[@"unified"]; SEL sign = NSSelectorFromString(@"getSecurityFactors:error:");
    if (!input || !ProbeMethod(unified, sign, @[@"@", @"^@"], NO)) return nil;
    NSError *error = nil;
    id factors = ((id (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(unified, sign,
        @{@"appkey": context[@"x-appkey"], @"data": input, @"api": api, @"useWua": @NO, @"env": @0,
          @"extendParas": @{}, @"requestId": NSUUID.UUID.UUIDString}, &error);
    if (!CampusMtopProbeFactorsComplete(factors, error)) { emit(@"本阶段签名", @"四字段或 SDK 错误未通过；未发送"); return nil; }
    Class encoder = NSClassFromString(@"TBSDKMTOPEnvConfig"); SEL encode = NSSelectorFromString(@"urlEncodeString:");
    if (!ProbeMethod(encoder, encode, @[@"@"], NO)) return nil;
    NSString *reason = nil;
    NSURLRequest *request = CampusOriginalAccountRequest(context, time, body, factors, session, purpose,
        ^NSString *(NSString *value) { return ((id (*)(id, SEL, id))objc_msgSend)(encoder, encode, value); }, &reason);
    NSString *form = request ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : nil;
    BOOL sameBody = [form hasPrefix:@"data="] && [[[form substringFromIndex:5] stringByRemovingPercentEncoding] isEqual:body];
    NSArray *fields = [input componentsSeparatedByString:@"&"];
    BOOL sameSession = !session || ([fields[8] isEqual:session[@"sid"]] && [fields[1] isEqual:session[@"uid"]] &&
        [[request valueForHTTPHeaderField:@"x-sid"].stringByRemovingPercentEncoding isEqual:session[@"sid"]] &&
        [[request valueForHTTPHeaderField:@"x-uid"].stringByRemovingPercentEncoding isEqual:session[@"uid"]]);
    emit(@"本阶段 POST 一致性", request && sameBody && sameSession ? @"签名与表单使用同一正文；设备与会话参与本阶段新签名；白名单通过" :
        [NSString stringWithFormat:@"%@；未发送", reason ?: @"正文或会话对照失败"]);
    return sameBody && sameSession ? request : nil;
}

#ifdef CAMPUS_ORIGINAL_PROBE_TEST
NSURLRequest *CampusOriginalProbeTestAccountRequest(NSDictionary *context, NSString *body, NSDictionary *session, CampusOriginalPurpose purpose) {
    return ProbeAccountRequest(context, body, session, purpose, ^(NSString *step, NSString *result) {});
}
#endif

#ifdef CAMPUS_TIMETABLE_HOST
NSURLRequest *CampusTimetableAccountRequest(NSDictionary *context, NSDictionary *session,
    CampusOriginalPurpose purpose, NSDictionary *selection, NSString *code) {
    if (purpose != CampusOriginalPurposeLogin && purpose != CampusOriginalPurposeProfile &&
        purpose != CampusOriginalPurposeOrders && purpose != CampusOriginalPurposeHistory &&
        purpose != CampusOriginalPurposeDeviceInfo && purpose != CampusOriginalPurposeOrderDetail && !CampusPaymentPurpose(purpose)) return nil;
    if (purpose != CampusOriginalPurposeLogin && !session) return nil;
    NSString *body = purpose == CampusOriginalPurposeLogin ? ProbeLoginBody(context, code, ^(NSString *a, NSString *b) {}) :
        purpose == CampusOriginalPurposeProfile ? @"{\"platForm\":\"ios\"}" :
        CampusPaymentPurpose(purpose) ? CampusPaymentBody(purpose, selection) : CampusOriginalReadBody(purpose, selection);
    if (!body) return nil;
    return ProbeAccountRequest(context, body, session, purpose, ^(NSString *a, NSString *b) {});
}
#endif

static NSString *ProbeReadLabel(CampusOriginalPurpose purpose) {
    if (purpose == CampusOriginalPurposeOrders) return @"运行订单";
    if (purpose == CampusOriginalPurposeHistory) return @"历史订单（第一页）";
    if (purpose == CampusOriginalPurposeBuildings) return @"本人关联楼栋";
    if (purpose == CampusOriginalPurposeDevices) return @"常用设备（第一页）";
    if (purpose == CampusOriginalPurposeOrderDetail) return @"本人订单详情";
    return @"设备状态及洗衣程序";
}

#ifdef CAMPUS_QUOTE_DIAGNOSTIC
static void ProbeQuoteBatch(NSDictionary *context, NSDictionary *session, NSDictionary *payload, NSString *resNo,
                           NSArray *keys, NSUInteger index, void (^emit)(NSString *, NSString *), void (^invalidate)(void), void (^completion)(void)) {
    if (index >= keys.count) { completion(); return; }
    NSString *label = [NSString stringWithFormat:@"程序报价对照 %lu", (unsigned long)(index + 1)];
    NSDictionary *input = nil; NSURLRequest *request = nil;
    @try {
        input = CampusPaymentRenderInput(payload, resNo, keys[index]);
        request = ProbeAccountRequest(context, CampusPaymentBody(CampusOriginalPurposeRender, input), session, CampusOriginalPurposeRender, emit);
    } @catch (NSException *exception) { emit(label, @"设备参数或固定报价正文未通过；未发送，不展示异常正文"); }
    if (!request) {
        emit(label, @"请求准备未通过；继续其它程序的独立报价核对");
        ProbeQuoteBatch(context, session, payload, resNo, keys, index + 1, emit, invalidate, completion); return;
    }
    CampusOriginalAccountSend(request, CampusOriginalPurposeRender, ^(NSDictionary *result, NSDictionary *evidence) {
        emit([label stringByAppendingString:@"响应"], result[@"summary"]);
        if ([result[@"requiresLogin"] boolValue]) { if (invalidate) invalidate(); completion(); return; }
        if ([result[@"success"] boolValue])
            for (NSDictionary *row in CampusOriginalQuoteAudit(input, evidence[@"payload"][@"response"]))
                emit([NSString stringWithFormat:@"%@ / %@", label, row[@"step"]], row[@"result"]);
        ProbeQuoteBatch(context, session, payload, resNo, keys, index + 1, emit, invalidate, completion);
    });
}
static void ProbeDeviceQuotes(NSDictionary *context, NSDictionary *session, NSDictionary *payload, NSString *resNo,
                              void (^emit)(NSString *, NSString *), void (^invalidate)(void), void (^completion)(void)) {
    NSDictionary *device = payload[@"data"][@"deviceResponse"];
    NSMutableArray *keys = [NSMutableArray array];
    for (id mode in device[@"deviceWorkingModelDTOS"]) {
        if (![mode isKindOfClass:NSDictionary.class] || ![mode[@"priceModelList"] isKindOfClass:NSArray.class]) continue;
        for (id price in mode[@"priceModelList"]) {
            if (![price isKindOfClass:NSDictionary.class] || ![price[@"key"] isKindOfClass:NSString.class] || ![price[@"key"] length] || [price[@"key"] length] > 128) continue;
            // RenderInput 再次核对开放状态、身份和唯一程序，不把候选键当作有效程序。
            if (![keys containsObject:price[@"key"]] && keys.count < 5) [keys addObject:price[@"key"]];
        }
    }
    emit(@"报价诊断范围", [NSString stringWithFormat:@"本次设备至多五个程序，候选 %lu 项；每程序至多一次报价请求；不申请订单编号、不创建、不付款", (unsigned long)keys.count]);
    ProbeQuoteBatch(context, session, payload, resNo, keys, 0, emit, invalidate, completion);
}
#endif

// 每个固定只读阶段至多一次；单项结构失败不掩盖其它接口的结果。
static void ProbeReadBatch(NSDictionary *context, NSDictionary *session, NSUInteger index, NSDictionary *device, NSDictionary *order,
                           void (^emit)(NSString *, NSString *), void (^publish)(NSArray *), void (^invalidate)(void), void (^completion)(void)) {
    NSArray *purposes = @[@(CampusOriginalPurposeOrders), @(CampusOriginalPurposeHistory),
        @(CampusOriginalPurposeOrderDetail), @(CampusOriginalPurposeBuildings), @(CampusOriginalPurposeDevices), @(CampusOriginalPurposeDeviceInfo)];
    if (index >= purposes.count) { completion(); return; }
    CampusOriginalPurpose purpose = [purposes[index] integerValue];
    NSString *label = ProbeReadLabel(purpose);
    if (purpose == CampusOriginalPurposeOrderDetail && !order) {
        emit(label, @"列表没有通过校验的订单身份；正常跳过详情；不猜测订单标识");
        ProbeReadBatch(context, session, index + 1, device, order, emit, publish, invalidate, completion); return;
    }
    if (purpose == CampusOriginalPurposeDeviceInfo && !device) {
        emit(label, @"没有有效的手填机器编号或列表设备；正常跳过详情；不猜测设备标识"); completion(); return;
    }
    NSURLRequest *request = nil;
    @try { request = ProbeAccountRequest(context, CampusOriginalReadBody(purpose, purpose == CampusOriginalPurposeOrderDetail ? order : device), session, purpose, emit); }
    @catch (NSException *exception) { emit(label, @"请求准备异常（正文隐藏）；未发送"); }
    if (!request) {
        emit(label, @"准备未通过；继续其它独立只读检查");
        ProbeReadBatch(context, session, index + 1, device, order, emit, publish, invalidate, completion); return;
    }
    CampusOriginalAccountSend(request, purpose, ^(NSDictionary *result, NSDictionary *evidence) {
        emit([label stringByAppendingString:@"响应"], result[@"summary"]);
        if ([result[@"requiresLogin"] boolValue]) {
            emit(@"会话失效", @"已停止后续请求并清除本次会话及结果；请手动重新登录");
            if (invalidate) invalidate(); completion(); return;
        }
        NSDictionary *nextDevice = device, *nextOrder = order;
        if ([result[@"success"] boolValue]) {
            if (purpose == CampusOriginalPurposeDeviceInfo) {
                if ([device[@"resNo"] isEqual:evidence[@"resNo"]] && (!device[@"deviceId"] || [device[@"deviceId"] isEqual:evidence[@"deviceId"]])) {
                    if (publish) publish(evidence[@"display"]);
                    emit(label, [NSString stringWithFormat:@"设备身份与查询来源一致；可用状态 %@；开放程序 %lu 项；标识、位置及价格不展示", [evidence[@"canUse"] boolValue] ? @"可用" : @"不可用", (unsigned long)[evidence[@"programs"] unsignedIntegerValue]]);
#ifdef CAMPUS_QUOTE_DIAGNOSTIC
                    ProbeDeviceQuotes(context, session, evidence[@"payload"], device[@"resNo"], emit, invalidate, ^{
                        ProbeReadBatch(context, session, index + 1, device, order, emit, publish, invalidate, completion);
                    }); return;
#endif
                } else emit(label, @"设备身份与查询来源不一致；此项未通过");
            } else if (purpose == CampusOriginalPurposeOrderDetail) {
                if ([order[@"bizOrderId"] isEqual:evidence[@"bizOrderId"]] && publish) publish(evidence[@"display"]);
                emit(label, [order[@"bizOrderId"] isEqual:evidence[@"bizOrderId"]] ?
                    @"订单身份与本人列表一致；支付及履约字段完整（状态值与标识不展示）" : @"详情与本人列表订单不一致；此项未通过");
            } else {
                if (publish) publish(evidence[@"display"]);
                emit(label, [NSString stringWithFormat:@"业务与数组结构通过；%lu 项（内容不展示）；空数组表示本次正常无记录", (unsigned long)[evidence[@"count"] unsignedIntegerValue]]);
                if (purpose == CampusOriginalPurposeDevices && !context[@"manualDevice"]) nextDevice = evidence[@"device"];
                if ((purpose == CampusOriginalPurposeOrders || purpose == CampusOriginalPurposeHistory) && !nextOrder) nextOrder = evidence[@"order"];
            }
        }
        ProbeReadBatch(context, session, index + 1, nextDevice, nextOrder, emit, publish, invalidate, completion);
    });
}

void CampusOriginalProbeLoginRun(NSDictionary *context, NSString *code,
                                void (^progress)(NSArray *), void (^publish)(NSArray *), void (^ready)(NSDictionary *), void (^completion)(NSArray *)) {
    NSMutableArray *rows = [NSMutableArray array];
    void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) {
        [rows addObject:@{@"step": step, @"result": result}]; if (progress) progress([rows copy]);
    };
    emit(@"本人登录范围", @"一次新授权码交换、本人资料、运行/历史订单、关联楼栋、常用设备、订单详情、设备状态与程序；基础至多八个串行任务；设备详情通过后轻量诊断追加至多五个程序报价；不下单、不付款；会话仅本次内存");
    NSURLRequest *request = nil;
    @try { emit(@"登录准备", @"正在生成本次登录模型与安全字段"); request = ProbeAccountRequest(context, ProbeLoginBody(context, code, emit), nil, CampusOriginalPurposeLogin, emit); }
    @catch (NSException *exception) { emit(@"登录准备", @"发生异常（正文隐藏）；未发送"); }
    if (!request) { emit(@"本人登录", @"准备未通过；未交换会话"); completion([rows copy]); return; }
    CampusOriginalAccountSend(request, CampusOriginalPurposeLogin, ^(NSDictionary *outcome, NSDictionary *session) {
        emit(@"校园会话交换", outcome[@"summary"]);
        if (![outcome[@"success"] boolValue] || !session) { completion([rows copy]); return; }
        emit(@"校园会话", @"本次 sid/hid 返回值通过（不展示）；尚未完成本人资料及洗衣验收");
        NSURLRequest *profile = nil;
        @try { profile = ProbeAccountRequest(context, @"{\"platForm\":\"ios\"}", session, CampusOriginalPurposeProfile, emit); }
        @catch (NSException *exception) { emit(@"本人资料准备", @"发生异常（正文隐藏）；未发送"); }
        if (!profile) { completion([rows copy]); return; }
        CampusOriginalAccountSend(profile, CampusOriginalPurposeProfile, ^(NSDictionary *verified, NSDictionary *profileEvidence) {
            emit(@"本人资料响应", verified[@"summary"]);
            if (![verified[@"success"] boolValue]) { completion([rows copy]); return; }
            emit(@"本人资料验收", @"返回身份字段通过；手机号及用户信息不展示");
            NSMutableDictionary *retained = [context mutableCopy]; retained[@"session"] = session;
            if (ready) ready([retained copy]);
            ProbeReadBatch(context, session, 0, context[@"manualDevice"], nil, emit, publish, ^{ if (ready) ready(nil); }, ^{
                emit(@"本批检查结束", @"登录、资料及六项只读检查已结束；各项是否通过见上文，不能把检查结束等同于全部成功；未下单、付款或持久化会话");
                completion([rows copy]);
            });
        });
    });
}

void CampusOriginalProbeRefreshRun(NSDictionary *context, void (^progress)(NSArray *), void (^publish)(NSArray *),
                                  void (^ready)(NSDictionary *), void (^completion)(NSArray *)) {
    NSMutableArray *rows = [NSMutableArray array];
    void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) {
        [rows addObject:@{@"step": step, @"result": result}]; if (progress) progress([rows copy]);
    };
    NSDictionary *session = context[@"session"];
    emit(@"手动刷新范围", @"复用本进程本人会话；先核验资料，再查询六项只读数据及至多五个程序报价；基础最多七个串行任务；不注册新设备、不交换授权码、不自动重试");
    NSURLRequest *profile = nil;
    @try { profile = ProbeAccountRequest(context, @"{\"platForm\":\"ios\"}", session, CampusOriginalPurposeProfile, emit); }
    @catch (NSException *exception) { emit(@"刷新准备", @"发生异常（正文隐藏）；未发送"); }
    if (!session || !profile) { emit(@"刷新准备", @"有效会话或请求缺失；未查询"); completion([rows copy]); return; }
    CampusOriginalAccountSend(profile, CampusOriginalPurposeProfile, ^(NSDictionary *verified, NSDictionary *evidence) {
        emit(@"刷新本人资料", verified[@"summary"]);
        if (![verified[@"success"] boolValue]) {
            if ([verified[@"requiresLogin"] boolValue] && ready) ready(nil);
            emit(@"刷新停止", [verified[@"requiresLogin"] boolValue] ? @"会话失效，已清除；请手动重新登录" : @"资料核验未通过；未继续查询，可检查网络后手动再试");
            completion([rows copy]); return;
        }
        if (ready) ready(context);
        ProbeReadBatch(context, session, 0, context[@"manualDevice"], nil, emit, publish, ^{ if (ready) ready(nil); }, ^{
            emit(@"本次刷新结束", @"各项是否通过见上文；结果为本次查询快照，没有后台轮询"); completion([rows copy]);
        });
    });
}

#ifndef CAMPUS_ORIGINAL_PROBE_TEST
@interface CampusOriginalProbeController : UIViewController
@property(nonatomic, strong) UITextView *report;
@property(nonatomic, strong) UIButton *start;
@property(nonatomic, strong) UIButton *network;
@property(nonatomic, strong) UIButton *login;
@property(nonatomic, strong) UITextField *machine;
@property(nonatomic, strong) UIButton *results;
@property(nonatomic, strong) NSMutableArray *readRows;
@property(nonatomic, strong) UIButton *refresh;
@property(nonatomic, strong) UIButton *logout;
@property(nonatomic, strong) NSDictionary *accountContext;
@property(nonatomic) BOOL queryBusy;
@property(nonatomic, strong) NSDictionary *loginContext;
@property(nonatomic, strong) NSArray *networkRows;
@property(nonatomic) BOOL loginStarted;
@property(nonatomic) BOOL networkStarted;
@property(nonatomic) BOOL networkFinished;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@end

@implementation CampusOriginalProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
    UILabel *title = [[UILabel alloc] init];
    title.text = @"校园原配本地诊断";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    [stack addArrangedSubview:title];
    self.report = [[UITextView alloc] init];
    self.report.editable = NO;
    self.report.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.report.text = @"诊断版本：13\n当前运行专用 Application/AppDelegate\n\n先点击联网综合检查，配置、注册与 ID 复用全部通过后，本人登录按钮才启用。本人登录由你在官方网页手动操作，取得授权后依次交换校园会话、查询本人资料和洗衣运行订单；不下单、不付款。账号、授权码与会话不写入报告或持久化。\n离线检查仍需断网。原二进制的类加载代码可能执行。\n基础检查每个进程一次；登录后可手动刷新，退出即清除本次会话。";
    [stack addArrangedSubview:self.report];
    self.start = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.start setTitle:@"开始本地检查" forState:UIControlStateNormal];
    [self.start addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.start];
    self.network = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.network setTitle:@"联网综合检查（配置/注册/复用）" forState:UIControlStateNormal];
    [self.network addTarget:self action:@selector(runNetworkProbe) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.network];
    self.login = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.login setTitle:@"本人登录及洗衣综合只读检查" forState:UIControlStateNormal]; self.login.enabled = NO;
    [self.login addTarget:self action:@selector(runLoginProbe) forControlEvents:UIControlEventTouchUpInside];
    self.machine = [[UITextField alloc] init];
    self.machine.placeholder = @"可选：机器编号或官方二维码链接";
    self.machine.borderStyle = UITextBorderStyleRoundedRect;
    self.machine.autocorrectionType = UITextAutocorrectionTypeNo;
    self.machine.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.machine.clearButtonMode = UITextFieldViewModeWhileEditing;
    [stack addArrangedSubview:self.machine];
    [stack addArrangedSubview:self.login];
    self.readRows = [NSMutableArray array];
    self.results = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.results setTitle:@"查看订单、设备及洗衣程序" forState:UIControlStateNormal];
    self.results.enabled = NO;
    [self.results addTarget:self action:@selector(showReadResults) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.results];
    self.refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.refresh setTitle:@"刷新订单或查询另一台机器" forState:UIControlStateNormal];
    self.refresh.enabled = NO;
    [self.refresh addTarget:self action:@selector(refreshReadResults) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.refresh];
    self.logout = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.logout setTitle:@"退出本人会话并清除结果" forState:UIControlStateNormal];
    self.logout.enabled = NO;
    [self.logout addTarget:self action:@selector(forgetAccount) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.logout];
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制诊断报告" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyReport) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:copy];
}
- (void)updateReadControls {
    self.machine.enabled = !self.queryBusy;
    self.results.enabled = !self.queryBusy && self.readRows.count > 0;
    self.refresh.enabled = !self.queryBusy && self.accountContext != nil;
    self.logout.enabled = !self.queryBusy && self.accountContext != nil;
    self.login.enabled = !self.queryBusy && !self.accountContext && self.networkFinished && self.loginContext != nil;
}
- (void)retainAccount:(NSDictionary *)context {
    self.accountContext = context;
    if (!context) [self.readRows removeAllObjects];
    else {
        NSMutableDictionary *base = [context mutableCopy]; [base removeObjectForKey:@"session"];
        self.loginContext = [base copy];
    }
    [self updateReadControls];
}
- (void)forgetAccount {
    if (self.queryBusy) return;
    [self retainAccount:nil]; self.machine.text = nil;
    self.report.text = [self.report.text stringByAppendingString:@"\n本人会话：已清除内存会话及显示结果；需要重新网页登录。\n"];
}
- (void)refreshReadResults {
    if (self.queryBusy || !self.accountContext) return;
    NSMutableDictionary *context = [self.accountContext mutableCopy];
    NSString *input = [self.machine.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (input.length) {
        NSString *number = CampusOriginalMachineNumber(input);
        if (!number) { self.report.text = [self.report.text stringByAppendingString:@"\n机器输入：编号或官方二维码链接未通过；未发送刷新查询。\n"]; return; }
        context[@"manualDevice"] = @{@"resNo": number};
    }
    self.machine.text = nil; [self.view endEditing:YES]; self.queryBusy = YES;
    [self.readRows removeAllObjects]; [self updateReadControls];
    __block BOOL finished = NO;
    void (^show)(NSArray *) = ^(NSArray *rows) {
        NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：13\n本次手动刷新（原配运行环境）\n\n"];
        for (NSDictionary *row in rows) [text appendFormat:@"%@：%@\n\n", row[@"step"], row[@"result"]];
        self.report.text = text;
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CampusOriginalProbeRefreshRun([context copy],
            ^(NSArray *rows) { dispatch_async(dispatch_get_main_queue(), ^{ show(rows); }); },
            ^(NSArray *items) { dispatch_async(dispatch_get_main_queue(), ^{ [self.readRows addObjectsFromArray:items]; }); },
            ^(NSDictionary *retained) { dispatch_async(dispatch_get_main_queue(), ^{ [self retainAccount:retained]; }); },
            ^(NSArray *rows) { dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; self.queryBusy = NO; [self updateReadControls]; show(rows); }); });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 360 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!finished) self.report.text = [self.report.text stringByAppendingString:@"\n刷新超过 360 秒；SDK 调用未取消，请复制报告并彻底关闭应用。\n"];
    });
}
- (void)showReadResults {
    if (!self.readRows.count) return;
    NSArray *snapshot = [self.readRows copy];
    CampusOriginalPresentReadResults(self, snapshot, ^{
        [self.readRows removeAllObjects]; self.results.enabled = NO;
    });
}
- (void)copyReport { UIPasteboard.generalPasteboard.string = self.report.text; }
- (void)runNetworkProbe {
    if (self.networkStarted || (self.started && !self.finished)) return;
    self.networkStarted = YES;
    self.network.enabled = NO;
    self.start.enabled = NO;
    NSDictionary *manifest = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CampusOriginalProbe"];
    NSString *root = NSBundle.mainBundle.bundlePath;
    void (^show)(NSArray *) = ^(NSArray *rows) {
        NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：13\n当前运行专用 Application/AppDelegate\n\n"];
        for (NSDictionary *row in rows) [text appendFormat:@"%@：%@\n\n", row[@"step"], row[@"result"]];
        self.report.text = text;
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CampusOriginalProbeNetworkRun(manifest, root, ^(NSArray *rows) {
            dispatch_async(dispatch_get_main_queue(), ^{ show(rows); });
        }, ^(NSDictionary *context) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.loginContext = context; });
        }, ^(NSArray *rows) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.networkFinished = YES; self.networkRows = rows; self.login.enabled = self.loginContext != nil; show(rows); });
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.networkFinished) self.report.text = [self.report.text stringByAppendingString:
            @"\n联网检查超过 90 秒尚未完成；可能停留在 SDK 调用，无法取消该调用。请复制当前报告并彻底关闭应用。\n"];
    });
}
- (void)runLoginProbe {
    if (self.queryBusy || self.accountContext || !self.networkFinished || !self.loginContext) return;
    NSString *input = [self.machine.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (input.length) {
        NSString *number = CampusOriginalMachineNumber(input);
        if (!number) {
            self.report.text = [self.report.text stringByAppendingString:@"\n机器输入：编号或官方二维码链接未通过；未打开网址，未发送设备查询。\n"]; return;
        }
        NSDictionary *selection = @{@"resNo": number};
        if (!CampusOriginalReadBody(CampusOriginalPurposeDeviceInfo, selection)) {
            self.report.text = [self.report.text stringByAppendingString:@"\n机器编号：格式未通过，请填写 1–128 位字母、数字、下划线或横线；不要填写整条二维码链接。\n"]; return;
        }
        NSMutableDictionary *prepared = [self.loginContext mutableCopy]; prepared[@"manualDevice"] = selection;
        self.loginContext = [prepared copy];
    }
    self.machine.text = nil; self.machine.enabled = NO; [self.view endEditing:YES];
    self.loginStarted = YES; self.queryBusy = YES; [self.readRows removeAllObjects]; [self updateReadControls];
    CampusOriginalPresentAuthorization(self, self.loginContext[@"x-appkey"], ^(NSString *code, NSString *error) {
        if (!code) {
            self.report.text = [self.report.text stringByAppendingFormat:@"\n本人登录：%@\n", error ?: @"未取得授权结果"];
            self.queryBusy = NO; [self updateReadControls]; return;
        }
        NSDictionary *context = self.loginContext;
        self.report.text = [self.report.text stringByAppendingString:@"\n本人授权：新回调已取得（授权码不展示）；开始校园会话交换及只读验证。\n"];
        __block BOOL finished = NO;
        void (^show)(NSArray *) = ^(NSArray *rows) {
            NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：13\n当前运行专用 Application/AppDelegate\n\n"];
            for (NSDictionary *row in [self.networkRows arrayByAddingObjectsFromArray:rows]) [text appendFormat:@"%@：%@\n\n", row[@"step"], row[@"result"]];
            self.report.text = text;
        };
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CampusOriginalProbeLoginRun(context, code, ^(NSArray *rows) { dispatch_async(dispatch_get_main_queue(), ^{ show(rows); }); },
                ^(NSArray *items) { dispatch_async(dispatch_get_main_queue(), ^{
                    if ([items isKindOfClass:NSArray.class]) [self.readRows addObjectsFromArray:items];
                }); },
                ^(NSDictionary *retained) { dispatch_async(dispatch_get_main_queue(), ^{ [self retainAccount:retained]; }); },
                ^(NSArray *rows) { dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; self.queryBusy = NO; [self updateReadControls]; show(rows); }); });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 360 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!finished) self.report.text = [self.report.text stringByAppendingString:@"\n登录/只读综合检查超过 360 秒；请复制报告并彻底关闭应用，SDK 调用未被取消。\n"];
        });
    });
}
- (void)runProbe {
    if (self.started || self.networkStarted) return;
    self.started = YES;
    self.start.enabled = NO;
    self.network.enabled = NO;
    NSDictionary *manifest = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CampusOriginalProbe"];
    NSString *root = NSBundle.mainBundle.bundlePath;
    void (^show)(NSArray *) = ^(NSArray *rows) {
        NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：13\n当前运行专用 Application/AppDelegate\n\n"];
        for (NSDictionary *row in rows) [text appendFormat:@"%@：%@\n\n", row[@"step"], row[@"result"]];
        self.report.text = text;
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *final = CampusOriginalProbeRun(manifest, root, ^(NSArray *rows) {
            dispatch_async(dispatch_get_main_queue(), ^{ show(rows); });
        });
        dispatch_async(dispatch_get_main_queue(), ^{ self.finished = YES; self.network.enabled = YES; show(final); });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.finished) self.report.text = [self.report.text stringByAppendingString:
            @"\n检查超过 45 秒，尚未返回；无法取消 SDK 调用。请复制当前报告并彻底关闭应用。\n"];
    });
}
@end

@interface CampusOriginalProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation CampusOriginalProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
#ifdef CAMPUS_TIMETABLE_HOST
    // Swift 以 passRetained 返回控制器；这里只转移一次所有权，窗口继续持有它。
    extern void *CampusTimetableMakeViewController(void);
    id root = CFBridgingRelease(CampusTimetableMakeViewController());
    if (![root isKindOfClass:UIViewController.class]) return NO;
    self.window.rootViewController = root;
#else
    self.window.rootViewController = [[CampusOriginalProbeController alloc] init];
#endif
    [self.window makeKeyAndVisible];
    return YES;
}
@end

__attribute__((visibility("default"))) int CampusOriginalProbeMain(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(CampusOriginalProbeDelegate.class));
    }
}
#endif
