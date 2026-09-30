#import "CampusComponentProbe.h"

#if CAMPUS_COMPONENT_PROBE
#import <SecurityGuardSDK/Open/OpenSecurityGuardManager.h>
#import <SecurityGuardSDK/Open/OpenStaticDataStore/IOpenStaticDataStoreComponent.h>
#import <SecurityGuardSDK/Open/OpenSecurityBody/IOpenSecurityBodyComponent.h>
#import <SGMiddleTier/ISecurityGuardOpenUnifiedSecurity.h>
#endif

@implementation CampusComponentProbe

+ (void)runAtResourcePath:(NSString *)path completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    static BOOL active = NO;
    // UI 在主线程调用；同一进程至多执行一个组件检查。
    if (active) { completion(@[@{@"step": @"检查任务", @"result": @"正在执行，请稍候"}]); return; }
    active = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *rows = [NSMutableArray array];
        void (^record)(NSString *, BOOL, NSError *) = ^(NSString *step, BOOL success, NSError *error) {
            [rows addObject:@{@"step": step, @"result": success ? @"成功" :
                [NSString stringWithFormat:@"失败（错误码 %ld）", (long)(error ? error.code : -1)]}];
        };
        @try {
#if CAMPUS_COMPONENT_PROBE
            NSError *error = nil;
            OpenSecurityGuardManager *manager = [OpenSecurityGuardManager getInstance:@"" withCustomBundlePath:path error:&error];
            record(@"SDK 初始化", manager != nil && error == nil, error);
            if (manager && !error) {
                NSString *appKey = [[manager getStaticDataStoreComp] getAppKey:@0 authCode:@""];
                record(@"读取应用配置", appKey.length > 0, nil);
                if (appKey.length > 0) {
                    NSString *time = [NSString stringWithFormat:@"%.0f", NSDate.date.timeIntervalSince1970 * 1000];
                    error = nil;
                    NSString *wua = [[manager getSecurityBodyComp] getSecurityBodyDataEx:time appKey:appKey
                        authCode:@"" extendParam:nil flag:4 env:0 error:&error];
                    record(@"当次登录安全字段", wua.length > 0 && error == nil, error);
                    id<ISecurityGuardOpenUnifiedSecurity> unified = [manager getInterface:@protocol(ISecurityGuardOpenUnifiedSecurity)];
                    error = nil;
                    BOOL ready = unified && [unified init:@{@"authCode": @""} error:&error];
                    record(@"统一签名接口初始化", ready && error == nil, error);
                    if (ready && !error) {
                        // 唯一当次输入仅用于接口兼容性检查，不作为 MTOP 请求发送。
                        NSDictionary *input = @{@"probe": @"campus-ios-component", @"nonce": NSUUID.UUID.UUIDString, @"t": time};
                        NSData *json = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
                        NSString *data = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                        NSDictionary *factors = [unified getSecurityFactors:@{@"appkey": appKey, @"data": data,
                            @"api": @"mtop.sys.newdeviceid", @"useWua": @NO, @"env": @0, @"authCode": @""} error:&error];
                        record(@"生成本地签名字段", factors != nil && error == nil, error);
                        for (NSString *key in @[@"x-sign", @"x-mini-wua", @"x-umt", @"x-sgext"]) {
                            id value = factors[key];
                            record([NSString stringWithFormat:@"%@ 字段", key], [value isKindOfClass:NSString.class] && [value length] > 0, nil);
                        }
                    }
                }
            }
#else
            record(@"候选 SDK", NO, [NSError errorWithDomain:@"CampusProbe" code:-2 userInfo:nil]);
#endif
        } @catch (NSException *exception) {
            // 不显示异常正文，它可能包含 SDK 入参。
            record(@"组件异常", NO, [NSError errorWithDomain:@"CampusProbe" code:-3 userInfo:nil]);
        }
        [rows addObject:@{@"step": @"服务端签名及设备注册", @"result": @"尚未验证"}];
        dispatch_async(dispatch_get_main_queue(), ^{ active = NO; completion(rows); });
    });
}
@end
