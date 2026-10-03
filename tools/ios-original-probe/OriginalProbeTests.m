#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdio.h>

NSArray *CampusOriginalProbeRun(NSDictionary *, NSString *, void (^)(NSArray *));
@protocol ISecurityGuardOpenUnifiedSecurity <NSObject>
@end
static BOOL ProbeTestFailure;
static NSUInteger ProbeTestKeyCalls, ProbeTestInitCalls, ProbeTestSignCalls, ProbeTestSignMode;
static NSArray *ProbeTestPreviousFields;
static NSString *ProbeTestPreviousRequest;

static NSString *ResultForStep(NSArray *rows, NSString *step) {
    for (NSDictionary *row in rows) if ([row[@"step"] isEqualToString:step]) return row[@"result"];
    return nil;
}

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
- (NSDictionary *)getSecurityFactors:(NSDictionary *)parameters error:(NSError **)error;
@end
@implementation ProbeOriginalUnified
- (BOOL)init:(NSDictionary *)parameters error:(NSError **)error {
    NSCAssert(parameters.count == 0, @"原配默认初始化参数改变");
    ProbeTestInitCalls++;
    if (ProbeTestFailure) *error = [NSError errorWithDomain:@"SECRET_ERROR_DOMAIN" code:2404 userInfo:
        @{NSLocalizedDescriptionKey: @"SECRET_ERROR_BODY"}];
    return !ProbeTestFailure;
}
- (NSDictionary *)getSecurityFactors:(NSDictionary *)parameters error:(NSError **)error {
    NSCAssert([parameters[@"appkey"] isEqualToString:@"TEST_APPKEY_MUST_NOT_APPEAR"] &&
        [parameters[@"api"] isEqualToString:@"mtop.sys.newdeviceid"] &&
        [parameters[@"useWua"] isEqual:@NO] && [parameters[@"env"] isEqual:@0] &&
        [parameters[@"extendParas"] isEqual:@{}], @"签名参数改变");
    NSArray *fields = [parameters[@"data"] componentsSeparatedByString:@"&"];
    NSCAssert(fields.count == 22 && [fields[3] isEqualToString:parameters[@"appkey"]] &&
        [fields[5] length] == 10 && [fields[4] length] == 32, @"MTOP 字段契约不符");
    if (ProbeTestSignCalls % 2 == 0) {
        ProbeTestPreviousFields = fields;
        ProbeTestPreviousRequest = parameters[@"requestId"];
    } else {
        for (NSUInteger i = 0; i < fields.count; i++) {
            NSCAssert(i == 4 ? ![fields[i] isEqual:ProbeTestPreviousFields[i]] :
                [fields[i] isEqual:ProbeTestPreviousFields[i]], @"输入对照必须只改变正文摘要");
        }
        NSCAssert(![parameters[@"requestId"] isEqual:ProbeTestPreviousRequest], @"请求编号未改变");
    }
    ProbeTestSignCalls++;
    if (ProbeTestSignMode == 1) return @{@"x-sign": @"SECRET_PARTIAL"};
    if (ProbeTestSignMode == 2) {
        *error = [NSError errorWithDomain:@"SECRET_ERROR_DOMAIN" code:2405 userInfo:
            @{NSLocalizedDescriptionKey: @"SECRET_ERROR_BODY"}];
    }
    if (ProbeTestSignMode == 3) return @{@"x-sign": @123, @"x-mini-wua": @"", @"x-umt": @"SECRET_UMT", @"x-sgext": @"SECRET_SGEXT"};
    if (ProbeTestSignMode == 4) return (id)@"SECRET_NON_DICTIONARY";
    NSString *sign = [NSString stringWithFormat:@"SECRET_SIGN_%lu", (unsigned long)ProbeTestSignCalls];
    return @{@"x-sign": sign, @"x-mini-wua": @"SECRET_MINI", @"x-umt": @"SECRET_UMT", @"x-sgext": @"SECRET_SGEXT"};
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
        NSCAssert(ProbeTestSignCalls == 2 && [ResultForStep(success, @"第一次离线签名") containsString:@"必需字段完整"] &&
            [ResultForStep(success, @"签名输入变化对照") containsString:@"不同"], @"完整签名或输入对照未验证");
        NSCAssert(![text containsString:@"SECRET_"], @"签名字段泄露");
        ProbeTestFailure = YES;
        NSArray *failure = CampusOriginalProbeRun(manifest, root, nil);
        text = failure.description;
        NSCAssert([text containsString:@"2404"] && ![text containsString:@"SECRET_ERROR"], @"错误码丢失或错误正文泄露");
        NSCAssert(ProbeTestInitCalls == 2, @"AppKey 空值后未检查初始化");
        NSCAssert(ProbeTestSignCalls == 2, @"初始化失败仍执行签名");
        ProbeTestFailure = NO;
        for (NSUInteger mode = 1; mode <= 4; mode++) {
            ProbeTestSignMode = mode;
            NSArray *invalid = CampusOriginalProbeRun(manifest, root, nil);
            NSString *result = ResultForStep(invalid, @"第一次离线签名");
            NSCAssert(![result containsString:@"必需字段完整"] &&
                [ResultForStep(invalid, @"签名输入变化对照") containsString:@"无法比较"], @"不完整、错误或类型不符返回误判成功");
            NSCAssert(mode != 2 || [result containsString:@"2405"], @"签名错误码丢失");
            NSCAssert(![invalid.description containsString:@"SECRET_"], @"负例报告泄露安全值");
        }
        NSUInteger calls = ProbeTestInitCalls, keyCalls = ProbeTestKeyCalls, signCalls = ProbeTestSignCalls;
        [[NSFileManager defaultManager] removeItemAtPath:[root stringByAppendingPathComponent:@"yw_1222.jpg"] error:nil];
        CampusOriginalProbeRun(manifest, root, nil);
        NSCAssert(ProbeTestKeyCalls == keyCalls && ProbeTestInitCalls == calls && ProbeTestSignCalls == signCalls, @"缺图没有阻断 SDK");
        CampusOriginalProbeRun(@{}, root, nil);
        NSCAssert(ProbeTestInitCalls == calls, @"缺清单没有阻断 SDK");
        [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
        puts("原配诊断原生桩测试通过；未执行厂商组件。");
    }
    return 0;
}
