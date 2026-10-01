// macOS 上使用桩组件验证检查流程，不运行厂商二进制或访问网络。
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <SecurityGuardSDK/Open/OpenSecurityGuardManager.h>
#import <SecurityGuardSDK/Open/OpenStaticDataStore/IOpenStaticDataStoreComponent.h>
#import <SecurityGuardSDK/Open/OpenSecurityBody/IOpenSecurityBodyComponent.h>
#import <SGMiddleTier/ISecurityGuardOpenUnifiedSecurity.h>
#import "CampusComponentProbe.h"
#import "CampusMtopProbeInput.h"
#import "ProbeResourceTrace.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>

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
- (NSString *)getAppKey:(NSNumber *)index authCode:(NSString *)code {
    Check(code == nil, @"静态配置应使用默认 authCode，不能用空字符串替代");
    if (scenario == 11) {
        FILE *resource = fopen([folder stringByAppendingPathComponent:@"yw_1222.jpg"].fileSystemRepresentation, "rb");
        Check(resource != NULL, @"桩 SDK 应能打开导入文件");
        fclose(resource);
    }
    if (scenario == 12) {
        dispatch_semaphore_t opened = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int fd = open([folder stringByAppendingPathComponent:@"yw_1222.jpg"].fileSystemRepresentation, O_RDONLY);
            Check(fd >= 0, @"SDK 工作线程应能打开导入文件"); close(fd);
            dispatch_semaphore_signal(opened);
        });
        Check(dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
            @"SDK 工作线程应完成读取");
    }
    if (scenario == 7) NSLog(@"%@", @"SG ERROR: 202\n, private-sdk-explanation");
    if (scenario == 8) NSLog(@"SG ERROR: %d\n", 203);
    if (scenario == 10) NSLog(@"%@", @"SG ERROR: 204\n");
    if (scenario == 9) {
        NSLog(@"SG ERROR: 202private-value");
        NSLog(@"SG ERROR: 123456\n");
        dispatch_semaphore_t logged = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSLog(@"SG ERROR: 202\n");
            dispatch_semaphore_signal(logged);
        });
        Check(dispatch_semaphore_wait(logged, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
            @"其他线程日志测试应完成");
    }
    return nil;
}
@end
@interface ProbeUnified : NSObject
@end
@implementation ProbeUnified
- (BOOL)init:(NSDictionary *)params error:(NSError **)error {
    initCalls++;
    Check(params[@"authCode"] == nil, @"统一初始化应省略可选 authCode");
    unifiedPathMatched = [params[@"customBundelPath"] isEqualToString:folder] &&
        params[@"customBundlePath"] == nil;
    if (failInitialization) { *error = [NSError errorWithDomain:@"Mock" code:445 userInfo:nil]; return NO; }
    return YES;
}
- (NSDictionary *)getSecurityFactors:(NSDictionary *)params error:(NSError **)error {
    signCalls++;
    Check(params[@"authCode"] == nil, @"离线签名应省略可选 authCode");
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
    Check(code == nil, @"登录安全字段应使用默认 authCode");
    return @"private-wua";
}
@end
@implementation OpenSecurityGuardManager
+ (instancetype)getInstance:(NSString *)code withCustomBundlePath:(NSString *)path error:(NSError **)error {
    Check(code == nil && [path isEqualToString:folder], @"管理器应使用默认 authCode 和已校验的资源目录");
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
static NSString *ReportResult(NSArray *rows, NSString *step) {
    for (NSDictionary *row in rows) {
        if ([row[@"step"] isEqualToString:step]) return row[@"result"];
    }
    return nil;
}
static void CheckReportResult(NSArray *rows, NSString *step, NSString *expected) {
    Check([ReportResult(rows, step) isEqualToString:expected],
        [NSString stringWithFormat:@"阶段“%@”应返回“%@”", step, expected]);
}
static void CheckResourceTrace(void) {
    NSString *original = [folder stringByAppendingPathComponent:@"yw_1222.jpg"];
    NSString *otherDirectory = [folder stringByAppendingPathComponent:@"other"];
    [[NSFileManager defaultManager] createDirectoryAtPath:otherDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *other = [otherDirectory stringByAppendingPathComponent:@"yw_1222.jpg"];
    [@"private-different-file" writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *missing = [folder stringByAppendingPathComponent:@"missing/yw_1222.jpg"];
    errno = EDOM;
    FILE *baseline = fopen(original.fileSystemRepresentation, "rb");
    int baselineError = errno;
    Check(baseline != NULL, @"基线文件应能打开");
    fclose(baseline);
    errno = EDOM;
    int baselineFd = open(original.fileSystemRepresentation, O_RDONLY);
    int baselineOpenError = errno;
    Check(baselineFd >= 0, @"open 基线应成功"); close(baselineFd);
    Check(CampusProbeResourceTraceBegin(folder), @"原文件访问函数与参考资源应可用");
    errno = EDOM;
    FILE *stream = fopen(original.fileSystemRepresentation, "rb");
    int observedError = errno;
    Check(stream != NULL && observedError == baselineError, @"观察器不能改变 fopen 返回值或 errno");
    Check(ftell(stream) == 0 && fgetc(stream) == 'm', @"摘要读取不能改变调用者的文件位置");
    fclose(stream);
    stream = fopen(other.fileSystemRepresentation, "rb");
    Check(stream != NULL, @"其他位置的同名文件应可打开"); fclose(stream);
    Check(fopen(missing.fileSystemRepresentation, "rb") == NULL && errno == ENOENT, @"打开失败应保留真实 errno");
    stream = fopen([folder stringByAppendingPathComponent:@"yw_1222_mwua.jpg"].fileSystemRepresentation, "rb");
    Check(stream != NULL, @"第二资源应可独立跟踪"); fclose(stream);
    stream = fopen([folder stringByAppendingPathComponent:@"Info.plist"].fileSystemRepresentation, "rb");
    Check(stream != NULL, @"普通文件不受影响"); fclose(stream);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FILE *background = fopen(original.fileSystemRepresentation, "rb");
        Check(background != NULL, @"其他线程应正常读文件"); fclose(background);
        dispatch_semaphore_signal(done);
    });
    Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"跨线程文件测试应完成");
    errno = EDOM;
    int fd = open(original.fileSystemRepresentation, O_RDONLY);
    int observedOpenError = errno;
    char first;
    Check(fd >= 0 && observedOpenError == baselineOpenError && lseek(fd, 0, SEEK_CUR) == 0 &&
        read(fd, &first, 1) == 1 && first == 'm', @"open 观察不得改变 errno 或文件位置");
    close(fd);
    Check(open(missing.fileSystemRepresentation, O_RDONLY) == -1 && errno == ENOENT, @"open 应保留失败 errno");
    NSString *created = [folder stringByAppendingPathComponent:@"created.dat"];
    fd = open(created.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
    struct stat createdInfo;
    Check(fd >= 0 && fstat(fd, &createdInfo) == 0 && (createdInfo.st_mode & 0077) == 0,
        @"open 必须正确转发 O_CREAT 的权限参数");
    Check(write(fd, "x", 1) == 1, @"非目标写入行为不应受影响"); close(fd);
    NSArray *rows = CampusProbeResourceTraceEnd();
    Check(rows.count == 4, @"报告只允许两个目标资源的访问与入口统计");
    CheckReportResult(rows, @"SDK 文件访问：yw_1222.jpg", [NSString stringWithFormat:
        @"打开尝试 6，成功 4；同一导入文件 3；内容一致 3，不同 1，无法校验 0；最近打开失败 errno %d", ENOENT]);
    CheckReportResult(rows, @"SDK 文件入口：yw_1222.jpg", @"fopen 4，open 2；包含工作线程，不包含自检");
    CheckReportResult(rows, @"SDK 文件访问：yw_1222_mwua.jpg",
        @"打开尝试 1，成功 1；同一导入文件 1；内容一致 1，不同 0，无法校验 0；最近打开失败 errno 0");
    for (NSDictionary *row in rows) {
        Check(![row[@"result"] containsString:folder] && ![row[@"result"] containsString:@"private-"], @"文件跟踪不得泄露路径或内容");
    }
    Check(CampusProbeResourceTraceEnd().count == 0, @"结束后不能返回上一次结果");
    Check(CampusProbeResourceTraceBegin(folder), @"新的观察应能开始");
    CheckReportResult(CampusProbeResourceTraceEnd(), @"SDK 文件访问：yw_1222.jpg",
        @"窗口内未观察到 fopen/open；不能据此判定 SDK 未读取文件");
    Check(!CampusProbeResourceTraceBegin([folder stringByAppendingPathComponent:@"missing"]), @"参考文件缺失应停止观察");
    Check(CampusProbeResourceTraceEnd().count == 0, @"准备失败不得留下活动观察");
    puts("文件访问跟踪：身份、摘要、位置、errno、跨线程汇总、open 权限转发及自检清零测试通过。");
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
    NSLog(@"SG ERROR: 999\n"); // 作用域外的日志不得污染下一次结果。
    [CampusComponentProbe runAtResourcePath:folder appKeyHint:number == 0 || number >= 7 ? nil : @"mock-input-key"
        progress:^(NSArray *rows) { progressCount++; }
        completion:^(NSArray *rows) {
            // 集合 description 是调试表示，可能将中文转义为 Unicode；断言直接读取报告字段。
            NSMutableArray *reportParts = [NSMutableArray array];
            for (NSDictionary *row in rows) {
                [reportParts addObject:row[@"step"]];
                [reportParts addObject:row[@"result"]];
            }
            NSString *report = [reportParts componentsJoinedByString:@"\n"];
            Check(progressCount > 0, @"应提供阶段进度");
            Check(![report containsString:@"private-"] && ![report containsString:@"mock-input-key"], @"报告不得包含安全字段或输入值");
            Check(![report containsString:folder], @"报告不得包含资源沙盒路径");
            if (number == 0) Check(initCalls == 1 && signCalls == 0, @"AppKey 为空仍应检查统一签名初始化");
            if (number == 1) {
                Check(initCalls == 1 && signCalls == 2, @"提供 AppKey 时应使用两个新输入生成签名");
                CheckReportResult(rows, @"生成本地签名字段", @"成功");
                CheckReportResult(rows, @"更换输入重新生成签名", @"成功");
                CheckReportResult(rows, @"两次签名比较", @"不同，已随输入变化");
            }
            if (number == 2) Check(managerCalls == 0, @"资源完整性失败时不能进入 SDK");
            else Check(unifiedPathMatched, @"统一签名必须收到已校验资源路径，参数拼写为 customBundelPath");
            if (number == 3) Check(initCalls == 1 && signCalls == 0 && [report containsString:@"445"], @"保留 SDK 错误码并禁止失败后的签名调用");
            if (number == 4) {
                Check(signCalls == 2, @"残缺字典场景应完成两次离线调用");
                CheckReportResult(rows, @"生成本地签名字段", @"必需安全字段不完整；不能判定签名成功");
                CheckReportResult(rows, @"更换输入重新生成签名", @"必需安全字段不完整；不能判定签名成功");
                CheckReportResult(rows, @"两次签名比较", @"缺少签名，无法比较");
            }
            if (number == 5) {
                Check(signCalls == 2, @"SDK 错误场景应完成两次离线调用");
                CheckReportResult(rows, @"生成本地签名字段", @"失败（SDK 错误码 778）");
                CheckReportResult(rows, @"更换输入重新生成签名", @"失败（SDK 错误码 778）");
                CheckReportResult(rows, @"两次签名比较", @"缺少签名，无法比较");
            }
            if (number == 6) {
                Check(signCalls == 2, @"固定签名场景应完成两次离线调用");
                CheckReportResult(rows, @"两次签名比较", @"相同，需继续分析");
            }
            if (number == 11 || number == 12) {
                CheckReportResult(rows, @"SDK 文件访问：yw_1222.jpg",
                    @"打开尝试 1，成功 1；同一导入文件 1；内容一致 1，不同 0，无法校验 0；最近打开失败 errno 0");
                CheckReportResult(rows, @"SDK 文件入口：yw_1222.jpg", number == 11 ?
                    @"fopen 1，open 0；包含工作线程，不包含自检" : @"fopen 0，open 1；包含工作线程，不包含自检");
            } else if (number != 2) {
                CheckReportResult(rows, @"SDK 文件访问：yw_1222.jpg", @"窗口内未观察到 fopen/open；不能据此判定 SDK 未读取文件");
            }
            if (number == 7 || number == 8) {
                CheckReportResult(rows, @"AppKey 底层错误", number == 7 ? @"SG ERROR: 202" : @"SG ERROR: 203");
                Check((ReportResult(rows, @"AppKey 错误解释") != nil) == (number == 7), @"仅已核对的 202 分支可解释为应用绑定不匹配");
                Check(signCalls == 0, @"底层诊断不能替代 AppKey 或触发签名");
            } else if (number == 10) {
                CheckReportResult(rows, @"AppKey 底层错误", @"SG ERROR: 204");
                CheckReportResult(rows, @"AppKey 错误解释", @"SDK 报告安全图片格式不正确；需核对 SDK 与资源的类别及版本兼容性，不能据此判定 Bundle ID 不匹配");
                Check(signCalls == 0, @"格式错误诊断不能触发签名");
            } else if (number != 2) {
                CheckReportResult(rows, @"AppKey 底层错误", @"未捕获同步数字错误码；不能据此判定底层成功");
            }
            completedTests++;
            if (number < 12) RunCase(number + 1);
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
        CheckResourceTrace();
        dispatch_async(dispatch_get_main_queue(), ^{ RunCase(0); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Check(NO, @"原生测试超时"); });
        dispatch_main();
    }
}
