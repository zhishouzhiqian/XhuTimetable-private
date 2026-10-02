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
#import "ProbeContainerSnapshot.h"
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>

static int managerCalls, initCalls, signCalls, completedTests;
static BOOL failInitialization;
static NSString *folder;
static BOOL unifiedPathMatched;
// 诊断对照在临时目录上执行，不再是导入目录；仅该模式放宽桩组件的路径断言。
static BOOL diagnosticsRun;
static int scenario;
static NSString *previousInput;
static NSString *managerPath;
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
    NSString *bundlePath = params[@"customBundelPath"];
    unifiedPathMatched = [bundlePath isEqualToString:managerPath] && params[@"customBundlePath"] == nil;
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
    Check(code == nil && ([path isEqualToString:folder] ||
        (diagnosticsRun && [path.pathExtension isEqualToString:@"bundle"])),
        @"管理器应使用默认 authCode；正式检查只用已校验的资源目录，诊断对照允许临时目录");
    managerCalls++;
    managerPath = [path copy];
    if (diagnosticsRun) {
        Check(![[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:@"yw_1222.jpg"]] &&
            ![[NSFileManager defaultManager] fileExistsAtPath:[path stringByAppendingPathComponent:@"yw_1222_mwua.jpg"]],
            @"两图缺失变体必须在实际 SDK 目录中缺少两图");
    }
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
static void CheckDiagnosticTrace(void) {
    NSString *main = [folder stringByAppendingPathComponent:@"yw_1222.jpg"];
    NSString *missing = [folder stringByAppendingPathComponent:@"trace-missing"];
    CampusProbeTraceOptions options = CampusProbeTraceOptionsAllowMissingReference | CampusProbeTraceOptionsScopedFiles;
    Check(!CampusProbeResourceTraceBeginWithOptions(missing, options), @"哨兵写入失败不得宣称自检通过");
    Check(CampusProbeResourceTraceEnd().count == 0, @"自检失败不得留下活动窗口");
    NSString *empty = [folder stringByAppendingPathComponent:@"trace-empty"];
    [[NSFileManager defaultManager] createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:nil];
    Check(CampusProbeResourceTraceBeginWithOptions(empty, options), @"两图缺失时必须校验哨兵的两个入口");
    CheckReportResult(CampusProbeResourceTraceEnd(), @"SDK 文件入口：yw_1222.jpg", @"fopen 0，open 0；包含工作线程，不包含自检");
    Check([[NSFileManager defaultManager] contentsOfDirectoryAtPath:empty error:nil].count == 0, @"哨兵自检后应清理自身文件");

    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"阶段测试应启用观察");
    CampusProbeResourceTraceMark(@"窗口开始");
    FILE *stream = fopen(main.fileSystemRepresentation, "rb");
    Check(stream != NULL, @"第一阶段应打开资源"); fclose(stream);
    CampusProbeResourceTraceMark(@"第一段结束");
    CampusProbeResourceTraceSuspendCurrentThread();
    stream = fopen(main.fileSystemRepresentation, "rb");
    Check(stream != NULL, @"内部读取仍应正常执行"); fclose(stream);
    [CampusProbeContainerSnapshot capture];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int fd = open(main.fileSystemRepresentation, O_RDONLY);
        Check(fd >= 0, @"暂停宿主采样不得影响其它线程"); close(fd);
        dispatch_semaphore_signal(done);
    });
    Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"工作线程测试应完成");
    CampusProbeResourceTraceResumeCurrentThread();
    int fd = open(main.fileSystemRepresentation, O_RDONLY);
    Check(fd >= 0, @"第二阶段应打开资源"); close(fd);
    CampusProbeResourceTraceSuspendCurrentThread();
    NSString *sibling = [folder stringByAppendingString:@"-other"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sibling withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *other = [sibling stringByAppendingPathComponent:@"private-scope-file.dat"];
    [@"mock" writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CampusProbeResourceTraceResumeCurrentThread();
    fd = open(other.fileSystemRepresentation, O_RDONLY);
    Check(fd >= 0, @"同前缀目录测试文件应可读取"); close(fd);
    CampusProbeResourceTraceMark(@"第二段结束");
    NSArray *rows = CampusProbeResourceTraceEnd();
    CheckReportResult(rows, @"阶段文件访问：第一段结束",
        @"yw_1222.jpg：1 次（成功 1）；yw_1222_mwua.jpg：0 次（成功 0）；目录内已记录访问 1");
    CheckReportResult(rows, @"阶段文件访问：第二段结束",
        @"yw_1222.jpg：2 次（成功 2）；yw_1222_mwua.jpg：0 次（成功 0）；目录内已记录访问 2");
    Check(ReportResult(rows, @"窗口文件 4") == nil, @"相同前缀的兄弟目录不得冒充参考目录");
    [[NSFileManager defaultManager] removeItemAtPath:sibling error:nil];
    puts("诊断跟踪测试覆盖：哨兵失败、缺图自检、阶段增量、内部采样排除、跨线程及目录边界。");
}
// 宿主通道：AVMP 字节码不能调用 fopen/open，内容读取只能经 objc_msgSend 走 Foundation；
// 路径探测走 access/opendir。本测试验证这些通道都被观察且身份/内容可比对。
static void CheckHostChannelTrace(void) {
    NSString *main = [folder stringByAppendingPathComponent:@"yw_1222.jpg"];
    // 目录外文件在窗口开启前创建、结束后删除，避免原子写入的内部
    // fileExistsAtPath 调用污染 NSFileManager 通道计数。
    NSString *outside = [NSTemporaryDirectory() stringByAppendingPathComponent:@"probe-host-outside.jpg"];
    [@"outside" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CampusProbeTraceOptions options = CampusProbeTraceOptionsScopedFiles | CampusProbeTraceOptionsHostChannels;
    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"宿主通道自检应全部命中后才允许宣称窗口有效");
    CampusProbeResourceTraceMark(@"宿主阶段");
    // 内容通道：读取目标文件，应记为目标命中且内容与参考一致。
    NSData *content = [NSData dataWithContentsOfFile:main];
    Check(content != nil, @"桩环境应能读取目标文件");
    NSString *text = [NSString stringWithContentsOfFile:main encoding:NSISOLatin1StringEncoding error:NULL];
    Check(text != nil, @"字符串通道应可用");
    NSData *viaManager = [[NSFileManager defaultManager] contentsAtPath:main];
    Check(viaManager != nil, @"NSFileManager 通道应可用");
    // 路径通道：access 目标文件与 opendir 对照目录。
    Check(access(main.fileSystemRepresentation, F_OK) == 0, @"access 应命中目标文件");
    DIR *handle = opendir(folder.fileSystemRepresentation);
    Check(handle != NULL, @"目录应可打开");
    closedir(handle);
    // 采样排除：宿主通道同样受内部读取深度约束。
    CampusProbeResourceTraceSuspendCurrentThread();
    [NSData dataWithContentsOfFile:main];
    access(main.fileSystemRepresentation, F_OK);
    CampusProbeResourceTraceResumeCurrentThread();
    // 目录外读取应记为目录外，不冒充目录内命中。
    [NSData dataWithContentsOfFile:outside];
    NSArray *rows = CampusProbeResourceTraceEnd();
    [[NSFileManager defaultManager] removeItemAtPath:outside error:nil];
    Check(ReportResult(rows, @"宿主通道说明") != nil, @"启用宿主通道后必须输出说明行");
    // NSData：自检清零后 1 次目标读取 + 1 次目录外读取；目标内容一致 1。
    CheckReportResult(rows, @"宿主通道：NSData", @"调用 2；目标命中 1（内容一致 1，不同 0）；目录内 0；目录外 1");
    CheckReportResult(rows, @"宿主通道：NSString", @"调用 1；目标命中 1（内容一致 0，不同 0）；目录内 0；目录外 0");
    CheckReportResult(rows, @"宿主通道：NSFileManager", @"调用 1；目标命中 1（内容一致 1，不同 0）；目录内 0；目录外 0");
    CheckReportResult(rows, @"宿主通道：access", @"调用 1；目标命中 1（内容一致 0，不同 0）；目录内 0；目录外 0");
    CheckReportResult(rows, @"宿主通道：opendir", @"调用 1；目标命中 0（内容一致 0，不同 0）；目录内 1；目录外 0");
    // 未调用的通道必须如实报 0，不得伪造命中。
    CheckReportResult(rows, @"宿主通道：NSFileHandle", @"调用 0；目标命中 0（内容一致 0，不同 0）；目录内 0；目录外 0");
    CheckReportResult(rows, @"宿主通道：NSBundle", @"调用 0；目标命中 0（内容一致 0，不同 0）；目录内 0；目录外 0");
    // 阶段行：Mark 在操作前，故“宿主阶段”为 0，全部命中汇入 End 补的“窗口结束”。
    CheckReportResult(rows, @"阶段宿主通道：宿主阶段", @"目标命中 0；目录内 0；目录外 0");
    NSString *hostEndRow = ReportResult(rows, @"阶段宿主通道：窗口结束");
    Check([hostEndRow containsString:@"目标命中 4"] && [hostEndRow containsString:@"目录内 1"] &&
        [hostEndRow containsString:@"目录外 1"],
        @"窗口结束阶段应汇总 4 次目标命中、1 次目录内与 1 次目录外");
    // 内容型通道读到的目标文件应出现在窗口文件清单，入口标注通道名。
    BOOL foundNSDataEntry = NO;
    for (NSDictionary *row in rows) {
        if ([row[@"step"] hasPrefix:@"窗口文件 "] && [row[@"result"] containsString:@"入口 NSData"]) foundNSDataEntry = YES;
    }
    Check(foundNSDataEntry, @"NSData 读到的目标文件必须进入窗口文件清单");
    for (NSDictionary *row in rows) {
        Check(![row[@"result"] containsString:folder] && ![row[@"result"] containsString:@"private-"], @"宿主通道不得泄露路径或内容");
    }
    Check(CampusProbeResourceTraceEnd().count == 0, @"结束后不能返回上一次结果");
    puts("宿主通道测试覆盖：Foundation 读方法、access/opendir、采样排除、目录边界与身份内容核对。");
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
    diagnosticsRun = number == 13;
    // 13 从完整来源派生缺图目录；14 移除来源后验证正式入口仍拦住 SDK。
    if (number == 14) {
        [[NSFileManager defaultManager] removeItemAtPath:[folder stringByAppendingPathComponent:@"yw_1222.jpg"] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[folder stringByAppendingPathComponent:@"yw_1222_mwua.jpg"] error:nil];
    }
    if (number == 2) [@"changed" writeToFile:[folder stringByAppendingPathComponent:@"yw_1222.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (number == 3) [@"mock" writeToFile:[folder stringByAppendingPathComponent:@"yw_1222.jpg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    __block NSUInteger progressCount = 0;
    NSLog(@"SG ERROR: 999\n"); // 作用域外的日志不得污染下一次结果。
    void (^probeProgress)(NSArray<NSDictionary<NSString *, NSString *> *> *) =
        ^(NSArray<NSDictionary<NSString *, NSString *> *> *rows) { progressCount++; };
    void (^probeCompletion)(NSArray<NSDictionary<NSString *, NSString *> *> *) =
        ^(NSArray<NSDictionary<NSString *, NSString *> *> *rows) {
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
            else if (number != 14) Check(unifiedPathMatched, @"统一签名必须收到已校验资源路径，参数拼写为 customBundelPath");
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
            } else if (number != 2 && number < 13) {
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
            } else if (number != 2 && number != 14) {
                CheckReportResult(rows, @"AppKey 底层错误", @"未捕获同步数字错误码；不能据此判定底层成功");
            }
            if (number == 13) {
                Check(managerCalls == 1 && initCalls == 1, @"诊断对照必须在资源不完整时仍然进入 SDK");
                Check([ReportResult(rows, @"诊断对照模式") containsString:@"变体"], @"诊断报告必须标明对照变体");
                Check(ReportResult(rows, @"诊断对照资源：yw_1222.jpg") != nil &&
                    ReportResult(rows, @"诊断对照资源：yw_1222_mwua.jpg") != nil,
                    @"诊断报告必须列出每个资源在对照目录中的实际状态");
                Check(ReportResult(rows, @"阶段文件访问：窗口开始") != nil, @"诊断报告必须给出阶段文件访问统计");
                Check([[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"yw_1222.jpg"]]
                    isEqualToData:[@"mock" dataUsingEncoding:NSUTF8StringEncoding]], @"诊断不得修改导入来源");
                Check(![[NSFileManager defaultManager] fileExistsAtPath:managerPath], @"完成后应清理自己创建的对照目录");
            }
            if (number == 14) {
                Check(managerCalls == 0, @"正式入口仍必须在资源不完整时拦在 SDK 之前");
                Check(ReportResult(rows, @"诊断对照模式") == nil, @"正式入口不得输出诊断对照行");
                [CampusComponentProbe runDiagnosticAtResourcePath:folder variant:@"baseline"
                    progress:^(NSArray *ignored) {} completion:^(NSArray *failed) {
                        Check(managerCalls == 0 && [ReportResult(failed, @"诊断对照模式") containsString:@"未调用 SDK"],
                            @"诊断基线不得把损坏来源当作有效对照");
                    }];
            }
            completedTests++;
            if (number < 14) RunCase(number + 1);
            else { [[NSFileManager defaultManager] removeItemAtPath:folder error:nil]; printf("%d 项原生检查流程测试通过。\n", completedTests); exit(0); }
        };
    // 13 走诊断入口（资源不完整也必须进入 SDK），14 走正式入口（必须仍然拦在 SDK 之前）。
    if (number == 13) {
        [CampusComponentProbe runDiagnosticAtResourcePath:folder variant:@"both-missing"
            progress:probeProgress completion:probeCompletion];
    } else {
        [CampusComponentProbe runAtResourcePath:folder
            appKeyHint:number == 0 || number >= 7 ? nil : @"mock-input-key"
            progress:probeProgress completion:probeCompletion];
    }
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
        CheckDiagnosticTrace();
        CheckHostChannelTrace();
        dispatch_async(dispatch_get_main_queue(), ^{ RunCase(0); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Check(NO, @"原生测试超时"); });
        dispatch_main();
    }
}
