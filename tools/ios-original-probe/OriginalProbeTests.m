#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#import "OriginalNetworkProbe.h"

NSArray *CampusOriginalProbeRun(NSDictionary *, NSString *, void (^)(NSArray *));
void CampusOriginalNetworkProbeTests(void);
NSURLRequest *CampusOriginalProbeTestRequest(NSDictionary *);
NSURLRequest *CampusOriginalProbeTestDeviceRequest(NSDictionary *, NSDictionary *, NSString *, CampusOriginalPurpose);
NSArray *CampusOriginalProbeTestCredentials(NSDictionary *, NSDictionary *);
void CampusOriginalDeviceProbeTests(void);
void CampusOriginalLoginProbeTests(void);
@protocol ISecurityGuardOpenUnifiedSecurity <NSObject>
@end
static BOOL ProbeTestFailure;
static NSUInteger ProbeTestKeyCalls, ProbeTestInitCalls, ProbeTestSignCalls, ProbeTestSignMode;
static NSArray *ProbeTestPreviousFields;
static NSString *ProbeTestPreviousRequest;
static NSUInteger ProbeTestConfigSignCalls;
static NSUInteger ProbeTestLegacyIDCalls, ProbeTestDeviceMode, ProbeTestMtopReadCount;
static NSUInteger ProbeTestCredentialMode, ProbeTestWUACalls, ProbeTestRegisterSignCalls;
static NSString *ProbeTestLastSignInput;
static NSUInteger ProbeTestRequestMode;
NSString *CampusOriginalProbeTestLastInput(void) { return ProbeTestLastSignInput; }

static NSString *ResultForStep(NSArray *rows, NSString *step) {
    // 同一步会先追加“正在执行”，再追加最终结果；断言必须读取最后一条。
    for (NSDictionary *row in rows.reverseObjectEnumerator) {
        if ([row[@"step"] isEqualToString:step]) return row[@"result"];
    }
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
    BOOL config = [parameters[@"api"] isEqualToString:CampusOriginalConfigAPI];
    BOOL registration = [parameters[@"api"] isEqualToString:CampusOriginalRegisterAPI];
    BOOL account = [parameters[@"api"] isEqual:CampusOriginalAccountAPI(CampusOriginalPurposeLogin)] ||
        [parameters[@"api"] isEqual:CampusOriginalAccountAPI(CampusOriginalPurposeProfile)] ||
        [parameters[@"api"] isEqual:CampusOriginalAccountAPI(CampusOriginalPurposeOrders)];
    NSCAssert([parameters[@"appkey"] isEqualToString:@"TEST_APPKEY_MUST_NOT_APPEAR"] &&
        (config || registration || account || [parameters[@"api"] isEqualToString:@"mtop.sys.newdeviceid"]) &&
        [parameters[@"useWua"] isEqual:@NO] && [parameters[@"env"] isEqual:@0] &&
        [parameters[@"extendParas"] isEqual:@{}], @"签名参数改变");
    NSArray *fields = [parameters[@"data"] componentsSeparatedByString:@"&"];
    NSCAssert(fields.count == 22 && [fields[3] isEqualToString:parameters[@"appkey"]] &&
        [fields[5] length] == 10 && [fields[4] length] == 32, @"MTOP 字段契约不符");
    ProbeTestLastSignInput = parameters[@"data"];
    if (account) {
        NSCAssert([fields[6] isEqual:parameters[@"api"]] && [fields[7] isEqual:@"1.0"], @"账号阶段 API 与签名输入不一致");
        return @{@"x-sign": @"SECRET_ACCOUNT_SIGN", @"x-mini-wua": @"SECRET_ACCOUNT_MINI", @"x-umt": @"SECRET_ACCOUNT_UMT", @"x-sgext": @"SECRET_ACCOUNT_SGEXT"};
    }
    registration = registration || ([parameters[@"api"] isEqual:CampusOriginalRegisterAPI.lowercaseString] &&
        [fields[9] isEqual:@"test@campus_iPhone_5.7.2"]);
    if (registration) {
        ProbeTestRegisterSignCalls++;
        NSCAssert([fields[6] isEqual:CampusOriginalRegisterAPI.lowercaseString] && [fields[7] isEqual:@"4.0"] && [fields[10] isEqual:@""], @"注册 API、版本或设备 ID 错误");
        return @{@"x-sign": @"SECRET_REG_SIGN", @"x-mini-wua": @"SECRET_REG_MINI", @"x-umt": @"SECRET_REG_UMT", @"x-sgext": @"SECRET_REG_SGEXT"};
    }
    if (config) {
        ProbeTestConfigSignCalls++;
        NSCAssert([fields[4] isEqualToString:@"99914b932bd37a50b983c5e7c90ae93b"] &&
            [fields[6] isEqualToString:CampusOriginalConfigAPI] && [fields[7] isEqualToString:@"1.0"] &&
            [fields[9] isEqualToString:@"test@campus_iPhone_5.7.2"], @"匿名签名的空正文或 iOS TTID 不一致");
        return @{@"x-sign": @"SECRET_CONFIG_SIGN+a/b=", @"x-mini-wua": @"SECRET_CONFIG_MINI",
            @"x-umt": @"SECRET_CONFIG_UMT", @"x-sgext": @"SECRET_CONFIG_SGEXT"};
    }
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
@interface ProbeOriginalUMID : NSObject
- (NSString *)getSecurityToken;
@end
@implementation ProbeOriginalUMID
- (NSString *)getSecurityToken {
    if (ProbeTestCredentialMode == 1) @throw [NSException exceptionWithName:@"SECRET_NAME" reason:@"SECRET_BODY" userInfo:nil];
    return @"SECRET_CONFIG_UMT";
}
@end
@interface ProbeOriginalBody : NSObject
- (NSString *)getSecurityBodyDataEx:(NSString *)data appKey:(NSString *)key authCode:(NSString *)auth
    extendParam:(NSDictionary *)parameters flag:(int)flag env:(int)env error:(NSError **)error;
@end
@implementation ProbeOriginalBody
- (NSString *)getSecurityBodyDataEx:(NSString *)data appKey:(NSString *)key authCode:(NSString *)auth
    extendParam:(NSDictionary *)parameters flag:(int)flag env:(int)env error:(NSError **)error {
    NSCAssert(data.length == 13 && [key isEqual:@"TEST_APPKEY_MUST_NOT_APPEAR"] && !auth && !parameters && flag == 4 && env == 0,
        @"WUA 的毫秒时间、默认参数或 int ABI 改变");
    ProbeTestWUACalls++;
    if (ProbeTestCredentialMode == 2) *error = [NSError errorWithDomain:@"SECRET_DOMAIN" code:777 userInfo:@{NSLocalizedDescriptionKey:@"SECRET_BODY"}];
    return ProbeTestCredentialMode == 3 ? (id)@123 : @"SECRET_FULL_WUA";
}
@end
@interface OpenSecurityGuardManager : NSObject
+ (instancetype)getInstance;
- (NSString *)getSDKVersion;
- (id)getStaticDataStoreComp;
- (id)getInterface:(Protocol *)protocol;
- (id)getUMIDComp;
- (id)getSecurityBodyComp;
@end
@implementation OpenSecurityGuardManager
+ (instancetype)getInstance { return [[self alloc] init]; }
- (NSString *)getSDKVersion { return @"6.8.260603"; }
- (id)getStaticDataStoreComp { return [[ProbeOriginalStore alloc] init]; }
- (id)getUMIDComp { return [[ProbeOriginalUMID alloc] init]; }
- (id)getSecurityBodyComp { return [[ProbeOriginalBody alloc] init]; }
- (id)getInterface:(Protocol *)protocol {
    NSCAssert(protocol == @protocol(ISecurityGuardOpenUnifiedSecurity), @"协议改变");
    return [[ProbeOriginalUnified alloc] init];
}
@end

@interface SecurityGuardManager : OpenSecurityGuardManager
@end
@implementation SecurityGuardManager
@end

@interface UTDIDMain : NSObject
+ (NSString *)uniqueGlobalDeviceIdentifier;
@end
@implementation UTDIDMain
+ (NSString *)uniqueGlobalDeviceIdentifier {
    ProbeTestLegacyIDCalls++;
    return @"00000000-0000-0000-0000-000000000000";
}
@end
@interface UTDevice : NSObject
+ (NSString *)utdid;
@end
@implementation UTDevice
+ (NSString *)utdid {
    if (ProbeTestDeviceMode == 1) return @"bad-device";
    return ProbeTestDeviceMode == 3 ? @"BBBBBBBBBBBBBBBBBBBBBBBB" : @"AAAAAAAAAAAAAAAAAAAAAAAA";
}
@end
@interface TBSDKNetworkSDKUtil : NSObject
+ (NSString *)utdid;
@end
@implementation TBSDKNetworkSDKUtil
+ (NSString *)utdid {
    ProbeTestMtopReadCount++;
    if (ProbeTestDeviceMode == 2 && ProbeTestMtopReadCount % 2 == 0) return @"BBBBBBBBBBBBBBBBBBBBBBBB";
    if (ProbeTestDeviceMode == 3) return @"AAAAAAAAAAAAAAAAAAAAAAAA";
    return [UTDevice utdid];
}
@end
@interface AppInfo : NSObject
+ (NSString *)appKey;
+ (NSString *)channel;
+ (NSString *)bundleName;
+ (NSString *)version;
@end
@implementation AppInfo
+ (NSString *)appKey { return @"TEST_APPKEY_MUST_NOT_APPEAR"; }
+ (NSString *)channel { return @"test"; }
+ (NSString *)bundleName { return @"campus"; }
+ (NSString *)version { return @"5.7.2"; }
@end
@interface TBSDKMTOPEnvConfig : NSObject
+ (NSString *)urlEncodeString:(NSString *)value;
@end
@implementation TBSDKMTOPEnvConfig
+ (NSString *)urlEncodeString:(NSString *)value {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"]];
}
@end

// macOS 桩不链接 UIKit，仅复现已核对的分类方法类型。
@interface UIDevice : NSObject
+ (NSString *)tbsdkPlatform;
+ (NSString *)tbsdkMacaddress;
@end
@implementation UIDevice
+ (NSString *)tbsdkPlatform { return @"test-platform"; }
+ (NSString *)tbsdkMacaddress { return @"02:00:00:00:00:00"; }
@end
@interface MtopExtRequest : NSObject
@property(nonatomic, copy) NSString *normalizedAPI;
- (instancetype)initWithApiName:(NSString *)api apiVersion:(NSString *)version;
- (NSString *)getApiName;
- (NSString *)getApiVersion;
@end
@implementation MtopExtRequest
- (instancetype)initWithApiName:(NSString *)api apiVersion:(NSString *)version {
    self = [super init];
    if (self) { NSCAssert([version isEqual:@"4.0"], @"注册版本错误"); self.normalizedAPI = api.lowercaseString; }
    return self;
}
- (NSString *)getApiName {
    if (ProbeTestRequestMode == 1) return @"SECRET_OTHER_API";
    if (ProbeTestRequestMode == 2) return nil;
    if (ProbeTestRequestMode == 4) return (id)@123;
    return self.normalizedAPI;
}
- (NSString *)getApiVersion { return ProbeTestRequestMode == 3 ? @"SECRET_OTHER_VERSION" : @"4.0"; }
@end

int main(void) {
    @autoreleasepool {
        NSArray *progressRows = @[
            @{@"step": @"签名", @"result": @"正在执行"},
            @{@"step": @"其它步骤", @"result": @"完成"},
            @{@"step": @"签名", @"result": @"最终成功"},
        ];
        NSCAssert([ResultForStep(progressRows, @"签名") isEqualToString:@"最终成功"], @"读取了进度行而不是最终结果");
        NSCAssert(ResultForStep(progressRows, @"不存在的步骤") == nil, @"不存在的步骤必须返回空值");
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
        NSCAssert(ProbeTestSignCalls == 2, @"未执行两次离线签名");
        NSCAssert([ResultForStep(success, @"第一次离线签名") containsString:@"必需字段完整"], @"第一次签名最终结果不完整");
        NSCAssert([ResultForStep(success, @"改变正文后离线签名") containsString:@"必需字段完整"], @"第二次签名最终结果不完整");
        NSCAssert([ResultForStep(success, @"签名输入变化对照") containsString:@"不同"], @"完整签名未随输入变化");
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
        NSDictionary *context = @{@"appKey": @"TEST_APPKEY_MUST_NOT_APPEAR", @"unified": [[ProbeOriginalUnified alloc] init]};
        NSURLRequest *configRequest = CampusOriginalProbeTestRequest(context);
        NSCAssert(configRequest != nil && ProbeTestConfigSignCalls == 1, @"原设备与应用入口未能构造匿名候选请求");
        NSCAssert([[configRequest valueForHTTPHeaderField:@"x-utdid"] isEqualToString:@"AAAAAAAAAAAAAAAAAAAAAAAA"] &&
            [[[configRequest valueForHTTPHeaderField:@"x-ttid"] stringByRemovingPercentEncoding] isEqualToString:@"test@campus_iPhone_5.7.2"], @"设备标识或 TTID 与签名输入不同");
        NSCAssert(ProbeTestLegacyIDCalls == 0 && ProbeTestMtopReadCount == 2, @"使用了旧标识入口或未核对重复读取");
        for (NSUInteger mode = 1; mode <= 3; mode++) {
            ProbeTestDeviceMode = mode;
            ProbeTestMtopReadCount = 0;
            NSCAssert(CampusOriginalProbeTestRequest(context) == nil, @"无效、不稳定或不一致的设备标识未阻断");
            NSCAssert(ProbeTestConfigSignCalls == 1 && ProbeTestLegacyIDCalls == 0, @"设备预检失败仍签名或使用错误替代入口");
        }
        ProbeTestDeviceMode = 0;
        NSDictionary *identity = @{@"x-appkey": @"TEST_APPKEY_MUST_NOT_APPEAR", @"x-utdid": @"AAAAAAAAAAAAAAAAAAAAAAAA",
            @"x-ttid": @"test@campus_iPhone_5.7.2", @"x-mini-wua": @"SECRET_CONFIG_MINI", @"x-umt": @"SECRET_CONFIG_UMT"};
        NSDictionary *credentialsContext = @{@"openManager": [[OpenSecurityGuardManager alloc] init]};
        for (NSUInteger mode = 0; mode <= 3; mode++) {
            ProbeTestCredentialMode = mode;
            NSArray *results = CampusOriginalProbeTestCredentials(credentialsContext, identity);
            NSCAssert(![results.description containsString:@"SECRET_"] && ![results.description containsString:@"TEST_APPKEY"], @"凭据报告泄露值");
            NSCAssert(mode == 2 ? [ResultForStep(results, @"候选完整 WUA") containsString:@"777"] :
                mode == 3 ? [ResultForStep(results, @"候选完整 WUA") containsString:@"类型不符"] :
                [ResultForStep(results, @"候选完整 WUA") containsString:@"非空值"], @"WUA 成败判定错误或 UMID 异常阻断 WUA");
        }
        NSCAssert(ProbeTestWUACalls == 4, @"独立凭据诊断未完整执行");
        NSCAssert(![[MtopExtRequest alloc] respondsToSelector:NSSelectorFromString(@"apiName")],
            @"桩错误提供了只有内部请求对象才有的 apiName getter");
        for (NSUInteger mode = 1; mode <= 4; mode++) {
            ProbeTestRequestMode = mode;
            NSCAssert(CampusOriginalProbeTestDeviceRequest(context, identity, nil, CampusOriginalPurposeRegister) == nil &&
                ProbeTestRegisterSignCalls == 0, @"错误 API 名称、类型或版本未在签名前阻断");
        }
        ProbeTestRequestMode = 0;
        NSURLRequest *registration = CampusOriginalProbeTestDeviceRequest(context, identity, nil, CampusOriginalPurposeRegister);
        NSCAssert(registration && ProbeTestRegisterSignCalls == 1, @"原设备入口不能构造注册请求");
        NSURLComponents *registrationURL = [NSURLComponents componentsWithURL:registration.URL resolvingAgainstBaseURL:YES];
        NSString *registrationBody = [[registrationURL.percentEncodedQuery substringFromIndex:5] stringByRemovingPercentEncoding];
        NSData *registrationBytes = [registrationBody dataUsingEncoding:NSUTF8StringEncoding];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        unsigned char md5Bytes[CC_MD5_DIGEST_LENGTH]; CC_MD5(registrationBytes.bytes, (CC_LONG)registrationBytes.length, md5Bytes);
#pragma clang diagnostic pop
        NSMutableString *md5 = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof(md5Bytes); i++) [md5 appendFormat:@"%02x", md5Bytes[i]];
        NSCAssert([[[ProbeTestLastSignInput componentsSeparatedByString:@"&"] objectAtIndex:4] isEqual:md5], @"签名与线路 JSON 正文摘要不同");
        NSString *deviceID = [@"D" stringByPaddingToLength:44 withString:@"D" startingAtIndex:0];
        NSURLRequest *reused = CampusOriginalProbeTestDeviceRequest(context, identity, deviceID, CampusOriginalPurposeReuse);
        NSCAssert(reused && [[[ProbeTestLastSignInput componentsSeparatedByString:@"&"] objectAtIndex:10] isEqual:deviceID] &&
            [[reused valueForHTTPHeaderField:@"x-devid"] isEqual:deviceID], @"返回设备 ID 没有同时参与签名与请求头");
        ProbeTestDeviceMode = 1;
        NSCAssert(CampusOriginalProbeTestDeviceRequest(context, identity, nil, CampusOriginalPurposeRegister) == nil &&
            ProbeTestRegisterSignCalls == 1, @"跨阶段标识变化没有阻断注册签名");
        ProbeTestDeviceMode = 0;
        CampusOriginalDeviceProbeTests();
        CampusOriginalNetworkProbeTests();
        ProbeTestCredentialMode = 0;
        CampusOriginalLoginProbeTests();
        puts("原配诊断原生桩测试通过；未执行厂商组件。");
    }
    return 0;
}
