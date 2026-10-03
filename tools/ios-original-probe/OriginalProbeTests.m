#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdio.h>

NSArray *CampusOriginalProbeRun(NSDictionary *, NSString *, void (^)(NSArray *));
@protocol ISecurityGuardOpenUnifiedSecurity <NSObject>
@end
static BOOL ProbeTestFailure;
static NSUInteger ProbeTestKeyCalls, ProbeTestInitCalls;

@interface ProbeOriginalStore : NSObject
- (NSString *)getAppKey:(NSNumber *)index;
- (NSString *)getAppKey:(NSNumber *)index authCode:(NSString *)auth;
@end
@implementation ProbeOriginalStore
- (NSString *)getAppKey:(NSNumber *)index { return [self getAppKey:index authCode:nil]; }
- (NSString *)getAppKey:(NSNumber *)index authCode:(NSString *)auth {
    NSCAssert([index isEqual:@0] && auth == nil, @"AppKey 默认参数改变");
    ProbeTestKeyCalls++;
    return ProbeTestFailure ? nil : @"TEST_APPKEY_MUST_NOT_APPEAR";
}
@end
@interface ProbeOriginalUnified : NSObject <ISecurityGuardOpenUnifiedSecurity>
- (BOOL)init:(NSDictionary *)parameters error:(NSError **)error;
@end
@implementation ProbeOriginalUnified
- (BOOL)init:(NSDictionary *)parameters error:(NSError **)error {
    NSCAssert(parameters.count == 0, @"原配默认初始化参数改变");
    ProbeTestInitCalls++;
    if (ProbeTestFailure) *error = [NSError errorWithDomain:@"SECRET_ERROR_DOMAIN" code:2404 userInfo:
        @{NSLocalizedDescriptionKey: @"SECRET_ERROR_BODY"}];
    return !ProbeTestFailure;
}
@end
@interface OpenSecurityGuardManager : NSObject
+ (instancetype)getInstance;
- (NSString *)getSDKVersion;
- (id)getStaticDataStoreComp;
- (id)getInterface:(Protocol *)protocol;
@end
@implementation OpenSecurityGuardManager
+ (instancetype)getInstance { return [[self alloc] init]; }
- (NSString *)getSDKVersion { return @"6.8.260603"; }
- (id)getStaticDataStoreComp { return [[ProbeOriginalStore alloc] init]; }
- (id)getInterface:(Protocol *)protocol {
    NSCAssert(protocol == @protocol(ISecurityGuardOpenUnifiedSecurity), @"协议改变");
    return [[ProbeOriginalUnified alloc] init];
}
@end

@interface SecurityGuardManager : OpenSecurityGuardManager
@end
@implementation SecurityGuardManager
@end

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *content = [@"test-resource" dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(content.bytes, (CC_LONG)content.length, digest);
        NSMutableString *sha = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [sha appendFormat:@"%02x", digest[i]];
        NSMutableDictionary *resources = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"yw_1222.jpg", @"yw_1222_mwua.jpg"]) {
            NSCAssert([content writeToFile:[root stringByAppendingPathComponent:name] atomically:YES], @"准备测试资源失败");
            resources[name] = @{@"bytes": @(content.length), @"sha256": sha};
        }
        NSDictionary *manifest = @{@"version": @1, @"resources": resources};
        NSArray *success = CampusOriginalProbeRun(manifest, root, nil);
        NSString *text = success.description;
        NSCAssert([text containsString:@"6.8.260603"] && ![text containsString:@"TEST_APPKEY_MUST_NOT_APPEAR"], @"成功报告泄露值");
        NSCAssert(ProbeTestKeyCalls == 1 && ProbeTestInitCalls == 1, @"成功流程未调用接口");
        ProbeTestFailure = YES;
        NSArray *failure = CampusOriginalProbeRun(manifest, root, nil);
        text = failure.description;
        NSCAssert([text containsString:@"2404"] && ![text containsString:@"SECRET_ERROR"], @"错误码丢失或错误正文泄露");
        NSCAssert(ProbeTestInitCalls == 2, @"AppKey 空值后未检查初始化");
        [[NSFileManager defaultManager] removeItemAtPath:[root stringByAppendingPathComponent:@"yw_1222.jpg"] error:nil];
        CampusOriginalProbeRun(manifest, root, nil);
        NSCAssert(ProbeTestKeyCalls == 2 && ProbeTestInitCalls == 2, @"缺图没有阻断 SDK");
        CampusOriginalProbeRun(@{}, root, nil);
        NSCAssert(ProbeTestInitCalls == 2, @"缺清单没有阻断 SDK");
        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        puts("原配诊断原生桩测试通过；未执行厂商组件。");
    }
    return 0;
}
