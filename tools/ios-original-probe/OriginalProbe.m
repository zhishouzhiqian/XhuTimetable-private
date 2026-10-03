#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>
#include <stdlib.h>
#import "../../iosApp/iosApp/CampusMtopProbeInput.h"
#import "OriginalNetworkProbe.h"

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
            if (initialized && appKey.length && context) *context = @{@"appKey": appKey, @"unified": unified};
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
    Class utdidClass = NSClassFromString(@"UTDIDMain");
    SEL identifier = NSSelectorFromString(@"uniqueGlobalDeviceIdentifier");
    if (!ProbeMethod(utdidClass, identifier, @[], NO)) {
        emit(@"设备上下文", @"原 UTDID 入口类型不匹配；未发送"); return nil;
    }
    id utdid = ((id (*)(id, SEL))objc_msgSend)(utdidClass, identifier);
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

void CampusOriginalProbeNetworkRun(NSDictionary *manifest, NSString *resourceRoot,
                                  void (^progress)(NSArray *), void (^completion)(NSArray *)) {
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
    emit(@"联网范围", @"仅一次匿名公开配置任务；无 Cookie、账号或会话；禁止跳转，无应用层自动重试");
    CampusOriginalConfigSend(request, ^(NSDictionary *outcome) {
        emit(@"匿名配置响应", outcome[@"summary"]);
        emit(@"验收结论", [outcome[@"success"] boolValue] ? @"本次匿名配置查询返回 SUCCESS；尚未验证设备注册、登录或洗衣" :
            @"本次未通过；不继续注册或登录；不能单独据此定位签名、协议或网络原因");
        completion([rows copy]);
    });
}

#ifndef CAMPUS_ORIGINAL_PROBE_TEST
@interface CampusOriginalProbeController : UIViewController
@property(nonatomic, strong) UITextView *report;
@property(nonatomic, strong) UIButton *start;
@property(nonatomic, strong) UIButton *network;
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
    self.report.text = @"诊断版本：4\n当前运行专用 Application/AppDelegate\n\n离线检查：开启飞行模式并关闭 Wi-Fi。\n联网检查：先连接网络，再手动点击下方联网按钮，仅查询一次匿名公开配置，使用原设备标识但不展示，不登录、不注册设备、不下单。\n原二进制的类加载代码仍可能执行。\n\n每项检查每个进程只执行一次。";
    [stack addArrangedSubview:self.report];
    self.start = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.start setTitle:@"开始本地检查" forState:UIControlStateNormal];
    [self.start addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.start];
    self.network = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.network setTitle:@"联网检查（仅匿名配置）" forState:UIControlStateNormal];
    [self.network addTarget:self action:@selector(runNetworkProbe) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.network];
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制诊断报告" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyReport) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:copy];
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
        NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：4\n当前运行专用 Application/AppDelegate\n\n"];
        for (NSDictionary *row in rows) [text appendFormat:@"%@：%@\n\n", row[@"step"], row[@"result"]];
        self.report.text = text;
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CampusOriginalProbeNetworkRun(manifest, root, ^(NSArray *rows) {
            dispatch_async(dispatch_get_main_queue(), ^{ show(rows); });
        }, ^(NSArray *rows) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.networkFinished = YES; show(rows); });
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.networkFinished) self.report.text = [self.report.text stringByAppendingString:
            @"\n联网检查超过 45 秒尚未完成；可能停留在 SDK 调用，无法取消该调用。请复制当前报告并彻底关闭应用。\n"];
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
        NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：4\n当前运行专用 Application/AppDelegate\n\n"];
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
    self.window.rootViewController = [[CampusOriginalProbeController alloc] init];
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
