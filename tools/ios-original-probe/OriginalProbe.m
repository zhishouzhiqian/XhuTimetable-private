#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

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

NSArray<NSDictionary<NSString *, NSString *> *> *CampusOriginalProbeRun(
    NSDictionary *manifest, NSString *resourceRoot, void (^progress)(NSArray *)) {
    NSMutableArray *rows = [NSMutableArray array];
    void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) {
        [rows addObject:@{@"step": step, @"result": result}];
        if (progress) progress([rows copy]);
    };
    emit(@"诊断方式", @"原程序内组件；默认资源入口；只进行本地初始化，不调用业务接口");
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
        if (ProbeMethod(store, getKey, @[@"@"], NO)) {
            id value = ((id (*)(id, SEL, id))objc_msgSend)(store, getKey, @0);
            BOOL valid = [value isKindOfClass:NSString.class] && [value length] > 0;
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
        if (ProbeMethod(unified, initialize, @[@"@", @"^@"], YES)) {
            NSError *error = nil;
            // 6.8 已核对读取 authCode/flag/customBundelPath；空字典保留默认 nil/nil/0。
            // 不复制调用层未被消费的 auth_code，也不更换原应用资源目录。
            BOOL ready = ((BOOL (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(unified, initialize, @{}, &error);
            emit(@"统一签名初始化", ready && error == nil ? @"成功" : error ?
                [NSString stringWithFormat:@"失败（SDK 错误码 %ld）", (long)error.code] : @"失败；未提供错误码");
        } else emit(@"统一签名初始化", @"方法类型不匹配；未调用");
    } @catch (NSException *exception) {
        emit(@"本地检查", @"发生异常（正文不展示）");
    }
    emit(@"验证边界", @"未生成签名、未验证服务器、未登录或下单；原二进制加载期活动不在诊断控制范围内");
    return [rows copy];
}

#ifndef CAMPUS_ORIGINAL_PROBE_TEST
@interface CampusOriginalProbeController : UIViewController
@property(nonatomic, strong) UITextView *report;
@property(nonatomic, strong) UIButton *start;
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
    self.report.text = @"请先开启飞行模式，并关闭 Wi-Fi，再开始。\n\n诊断版本：1\n当前运行专用 Application/AppDelegate\n本检查只调用原配组件的本地初始化接口。\n原二进制的类加载代码仍可能执行。\n\n每次新进程只执行一次。";
    [stack addArrangedSubview:self.report];
    self.start = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.start setTitle:@"开始本地检查" forState:UIControlStateNormal];
    [self.start addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.start];
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"复制诊断报告" forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyReport) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:copy];
}
- (void)copyReport { UIPasteboard.generalPasteboard.string = self.report.text; }
- (void)runProbe {
    if (self.started) return;
    self.started = YES;
    self.start.enabled = NO;
    NSDictionary *manifest = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CampusOriginalProbe"];
    NSString *root = NSBundle.mainBundle.bundlePath;
    void (^show)(NSArray *) = ^(NSArray *rows) {
        NSMutableString *text = [NSMutableString stringWithString:@"诊断版本：1\n当前运行专用 Application/AppDelegate\n\n"];
        for (NSDictionary *row in rows) [text appendFormat:@"%@：%@\n\n", row[@"step"], row[@"result"]];
        self.report.text = text;
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *final = CampusOriginalProbeRun(manifest, root, ^(NSArray *rows) {
            dispatch_async(dispatch_get_main_queue(), ^{ show(rows); });
        });
        dispatch_async(dispatch_get_main_queue(), ^{ self.finished = YES; show(final); });
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
