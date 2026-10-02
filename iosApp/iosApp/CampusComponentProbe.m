#import "CampusComponentProbe.h"
#import <CommonCrypto/CommonDigest.h>
#import "CampusMtopProbeInput.h"
#include <math.h>
#include <stdlib.h>
#include <stdarg.h>
#if CAMPUS_COMPONENT_TRACE_FILES
#import "ProbeContainerSnapshot.h"
#import "ProbeResourceTrace.h"
#endif

#if CAMPUS_COMPONENT_PROBE && CAMPUS_COMPONENT_CAPTURE_SDK_ERRORS
// 仅轻量诊断宿主链接此观察器。SDK 静态库的 NSLog 引用由宿主解析，
// 仍用 Foundation 的 NSLogv 输出原日志；报告只保留同步 AppKey 调用中的数字码。
static _Thread_local BOOL ProbeReadingAppKey;
static _Thread_local NSInteger ProbeAppKeyError;
void NSLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    @try {
        if (ProbeReadingAppKey && ProbeAppKeyError == 0) {
            va_list copy;
            va_copy(copy, args);
            NSString *message;
            @try { message = [[NSString alloc] initWithFormat:format arguments:copy]; }
            @finally { va_end(copy); }
            NSString *prefix = @"SG ERROR: ";
            if ([message hasPrefix:prefix]) {
                NSUInteger cursor = prefix.length, digits = 0;
                NSInteger code = 0;
                while (cursor < message.length && digits < 6) {
                    unichar c = [message characterAtIndex:cursor];
                    if (c < '0' || c > '9') break;
                    code = code * 10 + c - '0';
                    cursor++; digits++;
                }
                // 厂商格式在数字后换行；不接受数字与其他字段拼接的文本。
                if (digits > 0 && digits <= 5 && code > 0 &&
                    (cursor == message.length || [message characterAtIndex:cursor] == '\n')) {
                    ProbeAppKeyError = code;
                }
            }
        }
        NSLogv(format, args);
    } @finally { va_end(args); }
}
#endif

#if CAMPUS_COMPONENT_PROBE
#import <SecurityGuardSDK/Open/OpenSecurityGuardManager.h>
#import <SecurityGuardSDK/Open/OpenStaticDataStore/IOpenStaticDataStoreComponent.h>
#import <SecurityGuardSDK/Open/OpenSecurityBody/IOpenSecurityBodyComponent.h>
#import <SGMain/ISecurityGuardOpenStaticDataStore.h>
#import <SGMiddleTier/ISecurityGuardOpenUnifiedSecurity.h>
void CampusComponentProbeRequireEnabled(void) {}
#endif

static NSString *ProbeDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}

// 诊断对照变体：内容全部从导入资源就地派生，不新增素材，也不改动导入目录。
// 首轮目标是区分“没有读到目标资源”与“读到后解析拒绝”，所以只改变对照目录的内容。
static NSArray<NSDictionary<NSString *, NSString *> *> *CampusProbeDiagnosticTable(void) {
    return @[
        @{@"id": @"baseline", @"title": @"基线：与导入资源一致"},
        @{@"id": @"main-missing", @"title": @"缺主图 yw_1222.jpg"},
        @{@"id": @"mwua-missing", @"title": @"缺 yw_1222_mwua.jpg"},
        @{@"id": @"both-missing", @"title": @"两张图都缺"},
        @{@"id": @"main-zero", @"title": @"主图同长度全零"},
        @{@"id": @"main-header-only", @"title": @"主图保留前 16 字节，其余置零"},
        @{@"id": @"main-truncated", @"title": @"主图截断为一半"},
        @{@"id": @"main-random", @"title": @"主图同长度随机字节"},
    ];
}

static NSString *CampusProbeDiagnosticTitle(NSString *identifier) {
    for (NSDictionary<NSString *, NSString *> *entry in CampusProbeDiagnosticTable()) {
        if ([entry[@"id"] isEqualToString:identifier]) return entry[@"title"];
    }
    return identifier;
}

// 从同一份完整导入资源生成对照；缺图是主动控制的变量，不能由来源损坏代替。
static NSDictionary<NSString *, id> *CampusProbeDiagnosticPrepare(NSString *sourcePath, NSString *variant) {
    NSString *selected = variant.length ? variant : @"baseline";
    BOOL known = NO;
    for (NSDictionary<NSString *, NSString *> *entry in CampusProbeDiagnosticTable()) {
        if ([entry[@"id"] isEqualToString:selected]) { known = YES; break; }
    }
    if (!known) return nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray<NSString *> *names = @[@"yw_1222.jpg", @"yw_1222_mwua.jpg"];
    NSData *sources[2] = {
        [NSData dataWithContentsOfFile:[sourcePath stringByAppendingPathComponent:names[0]]],
        [NSData dataWithContentsOfFile:[sourcePath stringByAppendingPathComponent:names[1]]],
    };
    NSData *sourceInfo = [NSData dataWithContentsOfFile:[sourcePath stringByAppendingPathComponent:@"Info.plist"]];
    NSData *sourceManifest = [NSData dataWithContentsOfFile:[sourcePath stringByAppendingPathComponent:@"probe-manifest.plist"]];
    id manifest = sourceManifest ? [NSPropertyListSerialization propertyListWithData:sourceManifest
        options:NSPropertyListImmutable format:nil error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || sourceInfo.length == 0 ||
        [NSBundle bundleWithPath:sourcePath] == nil) return nil;
    for (NSUInteger index = 0; index < 2; index++) {
        id expected = manifest[names[index]];
        if (sources[index].length == 0 || sources[index].length > 65536 ||
            ![expected isKindOfClass:NSString.class] || ![ProbeDigest(sources[index]) isEqualToString:expected]) return nil;
    }
    NSString *directory = [[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"CampusProbeDiagnostic-" stringByAppendingString:NSUUID.UUID.UUIDString]]
        stringByAppendingPathExtension:@"bundle"];
    if (![manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    if (![sourceInfo writeToFile:[directory stringByAppendingPathComponent:@"Info.plist"] atomically:YES] ||
        ![sourceManifest writeToFile:[directory stringByAppendingPathComponent:@"probe-manifest.plist"] atomically:YES]) {
        [manager removeItemAtPath:directory error:nil]; return nil;
    }
    NSData *variants[2] = {sources[0], sources[1]};
    BOOL writes[2] = {YES, YES};
    NSString *notes[2] = {@"与导入一致", @"与导入一致"};
    if ([selected isEqualToString:@"main-missing"]) { writes[0] = NO; }
    else if ([selected isEqualToString:@"mwua-missing"]) { writes[1] = NO; }
    else if ([selected isEqualToString:@"both-missing"]) { writes[0] = NO; writes[1] = NO; }
    else if (sources[0].length > 0) {
        if ([selected isEqualToString:@"main-zero"]) {
            variants[0] = [NSMutableData dataWithLength:sources[0].length];
            notes[0] = @"同长度全零";
        } else if ([selected isEqualToString:@"main-header-only"]) {
            NSMutableData *value = [NSMutableData dataWithLength:sources[0].length];
            NSUInteger keep = MIN((NSUInteger)16, sources[0].length);
            [value replaceBytesInRange:NSMakeRange(0, keep) withBytes:sources[0].bytes];
            variants[0] = value;
            notes[0] = [NSString stringWithFormat:@"保留前 %lu 字节，其余置零", (unsigned long)keep];
        } else if ([selected isEqualToString:@"main-truncated"] && sources[0].length > 1) {
            variants[0] = [sources[0] subdataWithRange:NSMakeRange(0, sources[0].length / 2)];
            notes[0] = @"截断为一半";
        } else if ([selected isEqualToString:@"main-random"]) {
            NSMutableData *value = [NSMutableData dataWithLength:sources[0].length];
            arc4random_buf(value.mutableBytes, value.length);
            variants[0] = value;
            notes[0] = @"同长度随机字节";
        }
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    [rows addObject:@{@"step": @"诊断对照模式", @"result": [NSString stringWithFormat:
        @"变体「%@」；不因资源不完整跳过 SDK，直接在对照目录上执行；每个变体必须使用新的应用进程；目录与路径不展示",
        CampusProbeDiagnosticTitle(selected)]}];
    for (NSUInteger index = 0; index < 2; index++) {
        NSString *step = [@"诊断对照资源：" stringByAppendingString:names[index]];
        if (!writes[index] || variants[index].length == 0) {
            [rows addObject:@{@"step": step, @"result": sources[index].length == 0 ?
                @"导入来源缺失，无法派生" : @"未写入对照目录"}];
            continue;
        }
        NSString *target = [directory stringByAppendingPathComponent:names[index]];
        if (![variants[index] writeToFile:target atomically:YES] ||
            ![[NSData dataWithContentsOfFile:target] isEqualToData:variants[index]]) {
            [manager removeItemAtPath:directory error:nil]; return nil;
        }
        [rows addObject:@{@"step": step, @"result": [NSString stringWithFormat:@"%@；%lu 字节",
            notes[index], (unsigned long)variants[index].length]}];
    }
    return @{@"directory": directory, @"rows": rows};
}

@implementation CampusComponentProbe
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)diagnosticVariants {
    return CampusProbeDiagnosticTable();
}

+ (void)runAtResourcePath:(NSString *)path appKeyHint:(NSString *)appKeyHint
                progress:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))progress
              completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    [self runAtResourcePath:path variant:nil appKeyHint:appKeyHint diagnostics:NO
                   progress:progress completion:completion];
}

+ (void)runDiagnosticAtResourcePath:(NSString *)path variant:(NSString *)variant
                           progress:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))progress
                         completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    [self runAtResourcePath:path variant:variant appKeyHint:nil diagnostics:YES
                   progress:progress completion:completion];
}

+ (void)runAtResourcePath:(NSString *)path variant:(NSString *)variant appKeyHint:(NSString *)appKeyHint
              diagnostics:(BOOL)diagnostics
                 progress:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))progress
               completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    static BOOL active = NO;
    // 在生成目录之前阻止并发调用，避免拒绝执行却留下临时目录。
    if (active) { completion(@[@{@"step": @"检查任务", @"result": @"正在执行，请稍候"}]); return; }
    // 诊断模式先在对照目录上派生变体，后续 SDK 步骤全部读取该目录。
    NSDictionary<NSString *, id> *diagnostic = nil;
    if (diagnostics) {
        diagnostic = CampusProbeDiagnosticPrepare(path, variant);
        if (diagnostic == nil) {
            completion(@[@{@"step": @"诊断对照模式", @"result": @"来源校验或对照写入失败；未调用 SDK，请重新导入完整检查资源"}]);
            return;
        }
    }
    NSString *effectivePath = diagnostic[@"directory"] ?: path;
    NSArray<NSDictionary<NSString *, NSString *> *> *diagnosticRows = diagnostic[@"rows"] ?: @[];
    // Swift 在主线程调用；SDK 单例不能并发执行或中途更换资源。
    active = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *rows = [NSMutableArray arrayWithArray:diagnosticRows];
        void (^emit)(NSString *, NSString *) = ^(NSString *step, NSString *result) {
            NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) {
                return [row[@"step"] isEqualToString:step];
            }];
            NSDictionary *row = @{@"step": step, @"result": result};
            if (index == NSNotFound) [rows addObject:row]; else rows[index] = row;
            NSArray *snapshot = [rows copy];
            dispatch_async(dispatch_get_main_queue(), ^{ progress(snapshot); });
        };
        void (^record)(NSString *, BOOL, NSError *) = ^(NSString *step, BOOL success, NSError *error) {
            emit(step, success ? @"成功" : error ?
                [NSString stringWithFormat:@"失败（SDK 错误码 %ld）", (long)error.code] :
                @"未返回有效结果（接口未提供错误码）");
        };
        // 诊断模式下把检查窗口切成阶段，才能回答“初始化阶段是否已经读过”。
        // 未启用文件跟踪时为空操作，正式入口行为不变。
        void (^mark)(NSString *) = ^(NSString *name) {
#if CAMPUS_COMPONENT_TRACE_FILES
            if (diagnostics) CampusProbeResourceTraceMark(name);
#else
            (void)name;
#endif
        };
        NSDictionary<NSString *, NSString *> *sandboxBaseline = nil;
#if CAMPUS_COMPONENT_TRACE_FILES
        if (diagnostics) sandboxBaseline = [CampusProbeContainerSnapshot capture];
#endif
        // 沙盒差集不依赖 fopen/open hook，用于检验“派生缓存”这一类解释。
        void (^sandboxDiff)(NSString *) = ^(NSString *label) {
#if CAMPUS_COMPONENT_TRACE_FILES
            if (!diagnostics || sandboxBaseline == nil) return;
            for (NSDictionary<NSString *, NSString *> *row in
                 [CampusProbeContainerSnapshot diffSince:sandboxBaseline label:label]) {
                emit(row[@"step"], row[@"result"]);
            }
#else
            (void)label;
#endif
        };
        NSString *stage = @"资源检查";
        @try {
            NSBundle *bundle = [NSBundle bundleWithPath:path];
            emit(@"资源目录", bundle ? @"可识别为资源 Bundle" : @"无法识别资源 Bundle");
            NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:
                [path stringByAppendingPathComponent:@"probe-manifest.plist"]];
            BOOL resourcesValid = bundle != nil;
            for (NSString *name in @[@"yw_1222.jpg", @"yw_1222_mwua.jpg"]) {
                NSData *data = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:name]];
                NSString *expected = manifest[name];
                BOOL matched = data.length > 0 && data.length <= 65536 &&
                    [expected isKindOfClass:NSString.class] && [ProbeDigest(data) isEqualToString:expected];
                BOOL found = [bundle pathForResource:name.stringByDeletingPathExtension ofType:name.pathExtension] != nil;
                resourcesValid = resourcesValid && matched && found;
                emit(name, matched && found ?
                    [NSString stringWithFormat:@"可读取，%lu 字节，导入后完整性一致", (unsigned long)data.length] :
                    @"读取、Bundle 查找或完整性校验失败，请重新导入资源");
            }
            // 诊断模式不因资源不完整而跳过 SDK：这正是“缺图对照”的入口。正式入口保持原门槛。
            if (resourcesValid || diagnostics) {
#if CAMPUS_COMPONENT_PROBE
#if CAMPUS_COMPONENT_TRACE_FILES
                CampusProbeTraceOptions traceOptions = CampusProbeTraceOptionsTargetsOnly;
                if (diagnostics) {
                    traceOptions = CampusProbeTraceOptionsScopedFiles | CampusProbeTraceOptionsAllowMissingReference;
                }
                BOOL traceBegan = diagnostics ?
                    CampusProbeResourceTraceBeginWithOptions(effectivePath, traceOptions) :
                    CampusProbeResourceTraceBegin(path);
                emit(@"SDK 文件跟踪", traceBegan ?
                    @"已启用：fopen/open 运行时入口自检通过，覆盖检查窗口内各线程；不展示路径和内容" : @"入口自检或参考资源准备失败；本次不能核实 SDK 文件访问");
                mark(@"窗口开始");
#endif
                for (NSString *name in @[@"MainPlugin", @"MiddleTierPlugin", @"SecurityBodyPlugin"]) {
                    emit(name, NSClassFromString(name) ? @"已链接" : @"未找到组件类");
                }
                NSError *error = nil;
                stage = @"SDK 初始化";
                emit(stage, @"正在执行");
                // 厂商无参入口传 nil；空字符串会作为非空 UTF-8 指针进入底层，不能假定与默认值等价。
                emit(@"认证参数", @"使用 SDK 默认 authCode；未提供值，不使用显式空字符串");
                OpenSecurityGuardManager *manager = [OpenSecurityGuardManager getInstance:nil withCustomBundlePath:effectivePath error:&error];
                record(stage, manager != nil && error == nil, error);
                mark(@"SDK 初始化后");
                sandboxDiff(@"SDK 初始化后");
                if (manager && !error) {
                    NSString *version = [manager getSDKVersion];
                    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
                    if (version.length > 0 && version.length < 40 &&
                        [version rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound) {
                        emit(@"SDK 版本", version);
                        emit(@"校园组件版本对照", [version isEqualToString:@"6.8.260603"] ?
                            @"与已检查的校园 5.7.2 主程序版本一致；运行兼容仍待验证" :
                            @"与已检查的校园 5.7.2（6.8.260603）不同；不据此判定资源或签名不兼容");
                    }
                    // 官方 App 用内部入口读取 AppKey；这里只核对类是否链接，不初始化另一套单例。
                    emit(@"校园 AppKey 入口对照", NSClassFromString(@"SecurityGuardManager") ?
                        @"内部管理器类已链接；当前检查使用 Open 入口，尚未验证与校园入口等价" :
                        @"未找到校园使用的内部管理器类；当前检查仅覆盖 Open 入口");
                    NSString *appKey = nil;
                    stage = @"静态配置组件";
                    @try {
                        id<IOpenStaticDataStoreComponent> store = [manager getStaticDataStoreComp];
                        emit(stage, store ? @"可获取" : @"旧接口未返回组件");
                        if (!store) {
                            store = [manager getInterface:@protocol(ISecurityGuardOpenStaticDataStore)];
                            emit(@"静态配置协议接口", store ? @"可获取" : @"未返回组件");
                        }
                        if (store) {
#if CAMPUS_COMPONENT_CAPTURE_SDK_ERRORS
                            ProbeAppKeyError = 0;
                            ProbeReadingAppKey = YES;
                            @try { appKey = [store getAppKey:@0 authCode:nil]; }
                            @finally { ProbeReadingAppKey = NO; }
                            emit(@"AppKey 底层错误", ProbeAppKeyError > 0 ?
                                [NSString stringWithFormat:@"SG ERROR: %ld", (long)ProbeAppKeyError] :
                                @"未捕获同步数字错误码；不能据此判定底层成功");
                            if (ProbeAppKeyError == 202) {
                                emit(@"AppKey 错误解释", @"当前候选 SDK 的 202 分支指向应用 Bundle ID 与安全图片不匹配；需匹配本应用的授权资源");
                            } else if (ProbeAppKeyError == 204) {
                                // 厂商静态存储错误表：SEC_ERROR_STA_STORE_INCORRECT_DATA_FILE。
                                emit(@"AppKey 错误解释", @"SDK 报告安全图片格式不正确；需核对 SDK 与资源的类别及版本兼容性，不能据此判定 Bundle ID 不匹配");
                            }
#else
                            appKey = [store getAppKey:@0 authCode:nil];
#endif
                            emit(@"读取 AppKey（索引 0）", appKey.length > 0 ? @"成功（值不展示）" :
                                @"返回空值；此接口不提供 NSError，原因尚不确定");
                        }
                    } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
                    mark(@"AppKey 之后");
                    sandboxDiff(@"AppKey 之后");
                    // 抓包中的 AppKey 是输入线索，不等于组件已持有相应密钥。
                    NSCharacterSet *keyCharacters = [NSCharacterSet characterSetWithCharactersInString:
                        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
                    BOOL hasHint = appKeyHint.length > 0 && appKeyHint.length <= 64 &&
                        [appKeyHint rangeOfCharacterFromSet:keyCharacters.invertedSet].location == NSNotFound;
                    if (hasHint) {
                        if (appKey.length > 0) emit(@"AppKey 对照", [appKey isEqualToString:appKeyHint] ?
                            @"与提供值一致" : @"与提供值不同，继续使用 SDK 读取值");
                        else { appKey = appKeyHint; emit(@"AppKey 来源", @"使用手工提供值，尚未证明安全资源与它匹配"); }
                    }
                    // AppKey 为空也继续初始化接口，收集真实 SDK 错误码。
                    stage = @"统一签名接口";
                    emit(stage, @"正在执行");
                    id<ISecurityGuardOpenUnifiedSecurity> unified = nil;
                    BOOL ready = NO;
                    @try {
                        unified = [manager getInterface:@protocol(ISecurityGuardOpenUnifiedSecurity)];
                        record(stage, unified != nil, nil);
                        if (unified) {
                            stage = @"统一签名初始化";
                            emit(stage, @"正在执行");
                            error = nil;
                            // 该版本二进制读取 customBundelPath（Bundel 是厂商参数原名）。
                            // 两个初始化入口分别显式传入同一目录。
                            emit(@"统一签名资源路径", diagnostics ? @"显式使用当前对照目录（路径不展示）" :
                                @"显式使用已校验的导入目录（路径不展示）");
                            ready = [unified init:@{@"customBundelPath": effectivePath} error:&error];
                            record(stage, ready && error == nil, error);
                            ready = ready && error == nil;
                        }
                    } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
                    mark(@"统一签名初始化后");
                    sandboxDiff(@"统一签名初始化后");
                    if (appKey.length > 0) {
                        stage = @"登录安全字段";
                        emit(stage, @"正在执行");
                        @try {
                            error = nil;
                            NSString *time = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970 * 1000];
                            NSString *wua = [[manager getSecurityBodyComp] getSecurityBodyDataEx:time appKey:appKey
                                authCode:nil extendParam:nil flag:4 env:0 error:&error];
                            record(stage, wua.length > 0 && error == nil, error);
                        } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
                        if (ready) {
                            NSString *previous = nil;
                            for (int attempt = 0; attempt < 2; attempt++) {
                                stage = attempt == 0 ? @"生成本地签名字段" : @"更换输入重新生成签名";
                                emit(stage, @"正在执行");
                                // 每次新建无账号的诊断设备标识；规范字段形状不代表真实设备注册。
                                unsigned char randomBytes[18];
                                arc4random_buf(randomBytes, sizeof(randomBytes));
                                NSString *utdid = [[NSData dataWithBytes:randomBytes length:sizeof(randomBytes)] base64EncodedStringWithOptions:0];
                                NSDictionary *input = @{@"device_global_id": utdid};
                                NSData *json = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
                                NSString *timestamp = [NSString stringWithFormat:@"%.0f", floor(NSDate.date.timeIntervalSince1970)];
                                NSString *data = CampusMtopProbeSignData(json, utdid, appKey, @"mtop.sys.newdeviceid", @"4.0",
                                    @{@"x-t": timestamp, @"x-ttid": @"campus-ios-component-probe"});
                                if (!data) { emit(stage, @"无法组装离线 MTOP 输入；未调用签名"); break; }
                                if (attempt == 0) emit(@"签名输入契约", @"iOS MTOP 的 22 个字段、秒级时间与同一正文 MD5；仅离线诊断，未发送请求");
                                error = nil;
                                NSDictionary *factors = [unified getSecurityFactors:@{@"appkey": appKey, @"data": data,
                                    @"api": @"mtop.sys.newdeviceid", @"useWua": @NO, @"env": @0,
                                    @"extendParas": @{}, @"requestId": NSUUID.UUID.UUIDString} error:&error];
                                BOOL complete = CampusMtopProbeFactorsComplete(factors, error);
                                record(stage, complete, error);
                                if (!complete && !error) emit(stage, @"必需安全字段不完整；不能判定签名成功");
                                NSString *sign = nil;
                                NSDictionary *safeFactors = [factors isKindOfClass:NSDictionary.class] ? factors : nil;
                                for (NSString *key in @[@"x-sign", @"x-mini-wua", @"x-umt", @"x-sgext"]) {
                                    id value = safeFactors[key];
                                    BOOL valid = [value isKindOfClass:NSString.class] && [value length] > 0;
                                    if (attempt == 0) emit(key, valid ? @"已生成（值不展示）" : @"为空或未返回");
                                    if (complete && [key isEqualToString:@"x-sign"]) sign = value;
                                }
                                if (attempt == 0) previous = sign;
                                else emit(@"两次签名比较", previous.length && sign.length ?
                                    ([previous isEqualToString:sign] ? @"相同，需继续分析" : @"不同，已随输入变化") : @"缺少签名，无法比较");
                            }
                        } else emit(@"签名生成", @"跳过：统一签名初始化未成功");
                    } else emit(@"安全字段及签名生成", ready ?
                        @"跳过：没有 AppKey；可提供已知 AppKey 核对，但不能证明资源与它匹配" :
                        @"跳过：统一签名初始化失败且没有 AppKey；手工填写 AppKey 不能修复初始化失败");
                }
#else
                emit(@"候选 SDK", @"检查包未启用组件，请更换构建（PROBE_NOT_ENABLED）");
#endif
            }
        } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
        @finally {
            mark(@"签名之后");
            sandboxDiff(@"签名之后");
#if CAMPUS_COMPONENT_TRACE_FILES
            for (NSDictionary *row in CampusProbeResourceTraceEnd()) emit(row[@"step"], row[@"result"]);
#endif
            // 对照目录只服务本次诊断；正式入口既不创建也不删除任何目录。
            if (diagnostics) [[NSFileManager defaultManager] removeItemAtPath:effectivePath error:nil];
        }
        emit(@"服务端签名及设备注册", @"尚未验证");
        NSArray *snapshot = [rows copy];
        dispatch_async(dispatch_get_main_queue(), ^{ active = NO; completion(snapshot); });
    });
}
@end
