#import "CampusComponentProbe.h"
#import <CommonCrypto/CommonDigest.h>
#import "CampusMtopProbeInput.h"
#include <math.h>
#include <stdlib.h>

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

@implementation CampusComponentProbe
+ (void)runAtResourcePath:(NSString *)path appKeyHint:(NSString *)appKeyHint
                progress:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))progress
              completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    static BOOL active = NO;
    // Swift 在主线程调用；SDK 单例不能并发执行或中途更换资源。
    if (active) { completion(@[@{@"step": @"检查任务", @"result": @"正在执行，请稍候"}]); return; }
    active = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *rows = [NSMutableArray array];
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
            if (resourcesValid) {
#if CAMPUS_COMPONENT_PROBE
                for (NSString *name in @[@"MainPlugin", @"MiddleTierPlugin", @"SecurityBodyPlugin"]) {
                    emit(name, NSClassFromString(name) ? @"已链接" : @"未找到组件类");
                }
                NSError *error = nil;
                stage = @"SDK 初始化";
                emit(stage, @"正在执行");
                // 厂商无参入口传 nil；空字符串会作为非空 UTF-8 指针进入底层，不能假定与默认值等价。
                emit(@"认证参数", @"使用 SDK 默认 authCode；未提供值，不使用显式空字符串");
                OpenSecurityGuardManager *manager = [OpenSecurityGuardManager getInstance:nil withCustomBundlePath:path error:&error];
                record(stage, manager != nil && error == nil, error);
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
                            appKey = [store getAppKey:@0 authCode:nil];
                            emit(@"读取 AppKey（索引 0）", appKey.length > 0 ? @"成功（值不展示）" :
                                @"返回空值；此接口不提供 NSError，原因尚不确定");
                        }
                    } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
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
                            emit(@"统一签名资源路径", @"显式使用已校验的导入目录（路径不展示）");
                            ready = [unified init:@{@"customBundelPath": path} error:&error];
                            record(stage, ready && error == nil, error);
                            ready = ready && error == nil;
                        }
                    } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
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
                    } else emit(@"安全字段及签名生成", @"跳过：没有 AppKey；可填写抓包中的 AppKey 后重启重试");
                }
#else
                emit(@"候选 SDK", @"检查包未启用组件，请更换构建（PROBE_NOT_ENABLED）");
#endif
            }
        } @catch (NSException *exception) { emit(stage, @"发生异常（正文已隐藏）"); }
        emit(@"服务端签名及设备注册", @"尚未验证");
        NSArray *snapshot = [rows copy];
        dispatch_async(dispatch_get_main_queue(), ^{ active = NO; completion(snapshot); });
    });
}
@end
