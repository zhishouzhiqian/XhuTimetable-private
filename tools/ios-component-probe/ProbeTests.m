// macOS 上使用桩组件验证检查流程，不运行厂商二进制或访问网络。
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <SecurityGuardSDK/Open/OpenSecurityGuardManager.h>
#import <SecurityGuardSDK/Open/OpenStaticDataStore/IOpenStaticDataStoreComponent.h>
#import <SecurityGuardSDK/Open/OpenSecurityBody/IOpenSecurityBodyComponent.h>
#import <SGMiddleTier/ISecurityGuardOpenUnifiedSecurity.h>
#import "CampusComponentProbe.h"
#import "CampusMtopProbeInput.h"

static int managerCalls, initCalls, signCalls, completedTests;
static BOOL failInitialization;
static NSString *folder;
static BOOL unifiedPathMatched;
static int scenario;
static NSString *previousInput;
static void Check(BOOL condition, NSString *message);

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
    NSArray *fields = [params[@"data"] componentsSeparatedByString:@"&"];
    Check(fields.count == 22 && [fields[0] length] == 24 && [fields[4] length] == 32 &&
        [fields[5] length] == 10 && [fields[6] isEqualToString:@"mtop.sys.newdeviceid"] &&
        [fields[7] isEqualToString:@"4.0"] && [fields[8] length] == 0,
        @"签名应使用 iOS MTOP 输入且不含账号会话");
    Check([params[@"extendParas"] isKindOfClass:NSDictionary.class] && [params[@"requestId"] length] > 0,
        @"签名调用应明确扩展参数及当次请求编号");
    if (previousInput) Check(![previousInput isEqualToString:params[@"data"]], @"两次离线签名输入应不同");
    previousInput = params[@"data"];
    if (scenario == 4) return @{@"x-sign": @"private-incomplete"};
    if (scenario == 5) *error = [NSError errorWithDomain:@"Mock" code:778 userInfo:nil];
    return @{@"x-sign": scenario == 6 ? @"private-constant" : [NSString stringWithFormat:@"private-sign-%d", signCalls],
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
static void CheckInputContract(void) {
    NSData *body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *headers = @{@"x-t": @"1700000000", @"x-uid": @"sample-uid", @"x-reqbiz-ext": @"sample-biz",
        @"x-sid": @"sample-sid", @"x-ttid": @"sample-ttid", @"x-devid": @"sample-device",
        @"x-location": @"first,second", @"x-extdata": @"extra", @"x-features": @"features",
        @"x-router-id": @"router", @"x-place-id": @"place", @"x-open-biz": @"open",
        @"x-mini-appkey": @"mini", @"x-req-appkey": @"req", @"x-act": @"act", @"x-open-biz-data": @"open-data"};
    NSString *expected = @"sample-utdid&sample-uid&sample-biz&sample-key&99914b932bd37a50b983c5e7c90ae93b&1700000000&sample.api&1.0&sample-sid&sample-ttid&sample-device&second&first&extra&features&router&place&open&mini&req&act&open-data";
    Check([CampusMtopProbeSignData(body, @"sample-utdid", @"sample-key", @"sample.api", @"1.0", headers) isEqualToString:expected],
        @"iOS 签名字段顺序、正文 MD5 与 location 次序应匹配独立核对的契约");
    NSString *empty = CampusMtopProbeSignData(body, @"sample-utdid", @"sample-key", @"sample.api", @"1.0", @{@"x-t": @"1700000000"});
    Check([empty componentsSeparatedByString:@"&"].count == 22 && [empty hasSuffix:@"&&&&&&&&&&&&&&"], @"可选字段省略仍须保留位置");
    Check(CampusMtopProbeSignData(body, @"sample-utdid", @"sample-key", @"sample.api", @"1.0", @{@"x-t": @"1700000000000"}) == nil,
        @"毫秒时间不能作为 MTOP 秒值签名");
    Check(CampusMtopProbeSignData(body, @"sample-utdid", @"sample-key", @"sample.api", @"1.0", @{@"x-t": @1700000000}) == nil,
        @"时间字段类型错误应拒绝");
    Check(CampusMtopProbeSignData(body, @"sample-utdid", @"sample-key", @"sample.api", @"1.0", @{@"x-t": @"1700000000", @"x-sid": NSNull.null}) == nil,
        @"会话字段类型错误不能悄悄参与签名");
    NSArray *malformedLocation = [CampusMtopProbeSignData(body, @"sample-utdid", @"sample-key", @"sample.api", @"1.0",
        @{@"x-t": @"1700000000", @"x-location": @"one,two,three"}) componentsSeparatedByString:@"&"];
    Check([malformedLocation[11] length] == 0 && [malformedLocation[12] length] == 0, @"多项 location 按已核对分支留空");
    Check(!CampusMtopProbeFactorsComplete((id)@"not-dictionary", nil) &&
        !CampusMtopProbeFactorsComplete(@{@"x-sign": @"sample", @"x-mini-wua": @"sample", @"x-umt": @42, @"x-sgext": @"sample"}, nil),
        @"返回类型和字段类型错误不能判定完整签名");
}
static void RunCase(int number) {
    scenario = number;
    previousInput = nil;
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
            if (number == 4) Check(signCalls == 2 && [report containsString:@"必需安全字段不完整"] &&
                [report containsString:@"缺少签名，无法比较"], @"非空但不完整的字典不能判定签名成功");
            if (number == 5) Check(signCalls == 2 && [report containsString:@"778"] &&
                [report containsString:@"缺少签名，无法比较"], @"有 SDK 错误时即使字段齐全也不能判定成功");
            if (number == 6) Check(signCalls == 2 && [report containsString:@"相同，需继续分析"], @"固定签名不能当作随新输入变化");
            completedTests++;
            if (number < 6) RunCase(number + 1);
            else { [[NSFileManager defaultManager] removeItemAtPath:folder error:nil]; printf("%d 项原生检查流程测试通过。\n", completedTests); exit(0); }
        }];
}

int main(void) {
    @autoreleasepool {
        CheckInputContract();
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
