// macOS 上使用桩组件验证检查流程，不运行厂商二进制或访问网络。
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <SecurityGuardSDK/Open/OpenSecurityGuardManager.h>
#import <SecurityGuardSDK/Open/OpenStaticDataStore/IOpenStaticDataStoreComponent.h>
#import <SecurityGuardSDK/Open/OpenSecurityBody/IOpenSecurityBodyComponent.h>
#import <SGMiddleTier/ISecurityGuardOpenUnifiedSecurity.h>
#import "CampusComponentProbe.h"

static int managerCalls, initCalls, signCalls, completedTests;
static BOOL failInitialization;
static NSString *folder;
static BOOL unifiedPathMatched;

@interface ProbeStore : NSObject
@end
@implementation ProbeStore
- (NSString *)getAppKey:(NSNumber *)index authCode:(NSString *)code { return nil; }
@end
@interface ProbeUnified : NSObject
@end
@implementation ProbeUnified
- (BOOL)init:(NSDictionary *)params error:(NSError **)error {
    initCalls++;
    unifiedPathMatched = [params[@"customBundelPath"] isEqualToString:folder] &&
        params[@"customBundlePath"] == nil;
    if (failInitialization) { *error = [NSError errorWithDomain:@"Mock" code:445 userInfo:nil]; return NO; }
    return YES;
}
- (NSDictionary *)getSecurityFactors:(NSDictionary *)params error:(NSError **)error {
    signCalls++;
    return @{@"x-sign": [NSString stringWithFormat:@"private-sign-%d", signCalls],
        @"x-mini-wua": @"private-mini", @"x-sgext": @"private-ext", @"x-umt": @"private-device"};
}
@end

@interface ProbeBody : NSObject
@end
@implementation ProbeBody
- (NSString *)getSecurityBodyDataEx:(NSString *)time appKey:(NSString *)key authCode:(NSString *)code
                       extendParam:(NSDictionary *)extra flag:(int)flag env:(int)env error:(NSError **)error {
    return @"private-wua";
}
@end
@implementation OpenSecurityGuardManager
+ (instancetype)getInstance:(NSString *)code withCustomBundlePath:(NSString *)path error:(NSError **)error {
    managerCalls++;
    return [self new];
}
- (NSString *)getSDKVersion { return @"1.0"; }
- (id<IOpenStaticDataStoreComponent>)getStaticDataStoreComp { return (id)[ProbeStore new]; }
- (id<IOpenSecurityBodyComponent>)getSecurityBodyComp { return (id)[ProbeBody new]; }
- (id)getInterface:(Protocol *)protocol { return [ProbeUnified new]; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
static void RunCase(int number) {
    managerCalls = initCalls = signCalls = 0;
    unifiedPathMatched = NO;
    failInitialization = number == 3;
    if (number == 2) [@"changed" writeToFile:[folder stringByAppendingPathComponent:@"yw_1222.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (number == 3) [@"mock" writeToFile:[folder stringByAppendingPathComponent:@"yw_1222.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    __block NSUInteger progressCount = 0;
    [CampusComponentProbe runAtResourcePath:folder appKeyHint:number == 0 ? nil : @"mock-input-key"
        progress:^(NSArray *rows) { progressCount++; }
        completion:^(NSArray *rows) {
            NSString *report = rows.description;
            Check(progressCount > 0, @"应提供阶段进度");
            Check(![report containsString:@"private-"] && ![report containsString:@"mock-input-key"], @"报告不得包含安全字段或输入值");
            Check(![report containsString:folder], @"报告不得包含资源沙盒路径");
            if (number == 0) Check(initCalls == 1 && signCalls == 0, @"AppKey 为空仍应检查统一签名初始化");
            if (number == 1) Check(initCalls == 1 && signCalls == 2, @"提供 AppKey 时应使用两个新输入生成签名");
            if (number == 2) Check(managerCalls == 0, @"资源完整性失败时不能进入 SDK");
            else Check(unifiedPathMatched, @"统一签名必须收到已校验资源路径，参数拼写为 customBundelPath");
            if (number == 3) Check(initCalls == 1 && signCalls == 0 && [report containsString:@"445"], @"保留 SDK 错误码并禁止失败后的签名调用");
            completedTests++;
            if (number < 3) RunCase(number + 1);
            else { [[NSFileManager defaultManager] removeItemAtPath:folder error:nil]; printf("%d 项原生检查流程测试通过。\n", completedTests); exit(0); }
        }];
}

int main(void) {
    @autoreleasepool {
        folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".bundle"]];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        [@{@"CFBundleIdentifier": @"invalid.example.probe", @"CFBundlePackageType": @"BNDL"}
            writeToFile:[folder stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
        NSData *data = [@"mock" dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *hash = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
        NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"yw_1222.jpg", @"yw_1222_mwua.jpg"]) {
            [data writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES]; manifest[name] = hash;
        }
        [manifest writeToFile:[folder stringByAppendingPathComponent:@"probe-manifest.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ RunCase(0); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Check(NO, @"原生测试超时"); });
        dispatch_main();
    }
}
