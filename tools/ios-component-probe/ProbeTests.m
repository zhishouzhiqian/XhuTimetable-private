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

// 与 ProbeResourceTrace.m 保持一致：撤掉可能存在的 $INODE64 重定向宏。
// 注意真机 arm64 的 IR 已核对为纯符号（$INODE64 计数 0），重定向只影响 x86_64 macOS 桩测试。
#ifdef stat
#undef stat
#endif
#ifdef lstat
#undef lstat
#endif

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

// 宿主通道行格式为「<自检状态>；调用 N；目标命中 N（内容一致 N，不同 N）；目录内 N；目录外 N」。
// Foundation 的内部转调可能影响观察次数，因此场景中的命中数一般只要求下限。
// 但每个通道每次观察必须恰好归入目标、目录内或目录外一类，这项恒等式必须精确成立。
typedef struct {
    BOOL selfChecked;
    unsigned int calls, target, targetSame, targetDiff, scoped, outside;
} ProbeHostReport;

static BOOL ParseHostRow(NSString *text, ProbeHostReport *out) {
    if (text.length == 0) return NO;
    ProbeHostReport value = {0};
    value.selfChecked = [text hasPrefix:@"自检命中"];
    // NSScanner 的 scanInt: 只接受 int*；报告字段是 unsigned int，
    // 直接取地址强制转换会造成指针类型不匹配，故用 int 承接后再收窄。
    int parsed = 0;
    NSRange anchor = [text rangeOfString:@"调用 "];
    if (anchor.location == NSNotFound) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:[text substringFromIndex:anchor.location]];
    if (![scanner scanString:@"调用 " intoString:NULL] || ![scanner scanInt:&parsed]) return NO;
    value.calls = (unsigned int)parsed;
    const char *labels[] = {"目标命中 ", "内容一致 ", "，不同 ", "目录内 ", "目录外 "};
    unsigned int *targets[] = {&value.target, &value.targetSame, &value.targetDiff,
        &value.scoped, &value.outside};
    for (unsigned int index = 0; index < sizeof(labels) / sizeof(labels[0]); index++) {
        NSString *label = [NSString stringWithUTF8String:labels[index]];
        NSRange range = [text rangeOfString:label];
        if (range.location == NSNotFound) return NO;
        scanner = [NSScanner scannerWithString:[text substringFromIndex:range.location]];
        if (![scanner scanString:label intoString:NULL] || ![scanner scanInt:&parsed]) return NO;
        *targets[index] = (unsigned int)parsed;
    }
    if (out) *out = value;
    return YES;
}

static ProbeHostReport HostReport(NSArray *rows, NSString *channel) {
    ProbeHostReport value = {0};
    NSString *text = ReportResult(rows, [@"宿主通道：" stringByAppendingString:channel]);
    Check(ParseHostRow(text, &value),
        [NSString stringWithFormat:@"宿主通道 %@ 的报告行必须可解析：%@", channel, text ?: @"缺失"]);
    return value;
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
static void CheckFdTraceIdentity(void) {
    NSString *main = [folder stringByAppendingPathComponent:@"yw_1222.jpg"];
    NSString *outside = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"private-fd-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Check([@"outside" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil],
        @"fd 测试的目录外文件应创建成功");
    // 所有打开动作放在窗口前，窗口内只制造可精确计数的 lseek。
    enum { descriptorCount = 32 };
    int descriptors[descriptorCount];
    for (int i = 0; i < descriptorCount; i++) {
        descriptors[i] = open(main.fileSystemRepresentation, O_RDONLY);
        Check(descriptors[i] >= 0, @"fd 测试应打开目标文件");
    }
    int outsideFd = open(outside.fileSystemRepresentation, O_RDONLY);
    Check(outsideFd >= 0, @"fd 测试应打开目录外文件");
    int pipeFds[2];
    Check(pipe(pipeFds) == 0, @"fd 测试应创建无文件路径的管道");
    CampusProbeTraceOptions options = CampusProbeTraceOptionsHostChannels;

    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"fd 数量对照窗口应有效");
    for (int i = 0; i < descriptorCount; i++) {
        Check(lseek(descriptors[i], 0, SEEK_SET) == 0, @"目标描述符应可定位");
    }
    ProbeHostReport many = HostReport(CampusProbeResourceTraceEnd(), @"fd");
    Check(many.calls == many.target + many.scoped + many.outside, @"fd 调用与分类必须精确守恒");
    if (many.selfChecked) {
        Check(many.calls == descriptorCount && many.target == descriptorCount,
            @"超过旧缓存 24 槽后仍必须逐次计数，且不得重复计数");
    }

    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"fd 身份替换窗口应有效");
    Check(lseek(descriptors[0], 0, SEEK_SET) == 0, @"替换前应观察到目标身份");
    Check(dup2(outsideFd, descriptors[0]) == descriptors[0], @"dup2 应替换同一个 fd 的文件身份");
    Check(lseek(descriptors[0], 0, SEEK_SET) == 0, @"替换后目录外文件应可定位");
    Check(dup2(descriptors[1], descriptors[0]) == descriptors[0], @"dup2 应恢复目标身份");
    Check(lseek(descriptors[0], 0, SEEK_SET) == 0, @"恢复后应观察到目标身份");
    ProbeHostReport replaced = HostReport(CampusProbeResourceTraceEnd(), @"fd");
    Check(replaced.calls == replaced.target + replaced.scoped + replaced.outside,
        @"fd 身份替换后的计数必须守恒");
    if (replaced.selfChecked) {
        Check(replaced.calls == 3 && replaced.target == 2 && replaced.outside == 1,
            @"fd 必须按当前身份归类，不能依赖 close 清理旧缓存");
    }

    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"fd 无路径窗口应有效");
    errno = 0;
    off_t pipeOffset = lseek(pipeFds[0], 0, SEEK_SET);
    int pipeError = errno;
    ProbeHostReport unresolved = HostReport(CampusProbeResourceTraceEnd(), @"fd");
    Check(pipeOffset == -1 && pipeError == ESPIPE, @"观察器不得改变 lseek 失败结果和 errno");
    Check(unresolved.calls == unresolved.target + unresolved.scoped + unresolved.outside,
        @"无法反查路径的 fd 计数必须守恒");
    if (unresolved.selfChecked) {
        Check(unresolved.calls == 1 && unresolved.outside == 1 && unresolved.target == 0,
            @"无法反查路径也必须记录一次调用，不得丢弃或伪造目标身份");
    }
    for (int i = 0; i < descriptorCount; i++) close(descriptors[i]);
    close(outsideFd);
    close(pipeFds[0]); close(pipeFds[1]);
    [[NSFileManager defaultManager] removeItemAtPath:outside error:nil];
}

static void CheckWriteEventTrace(void) {
    NSString *path = [folder stringByAppendingPathComponent:@"private-write-event"];
    NSString *missing = [[folder stringByAppendingPathComponent:@"private-missing-parent"]
        stringByAppendingPathComponent:@"private-write-event"];
    NSData *input = [@"private-write-content" dataUsingEncoding:NSUTF8StringEncoding];
    CampusProbeResourceTraceSuspendCurrentThread();
    errno = EDOM;
    BOOL baselineFailure = [input writeToFile:missing atomically:YES];
    int baselineWriteError = errno;
    CampusProbeResourceTraceResumeCurrentThread();
    CampusProbeTraceOptions options = CampusProbeTraceOptionsWriteEvents;
    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"写入自检窗口应有效");
    NSArray *empty = CampusProbeResourceTraceEnd();
    NSString *status = ReportResult(empty, @"写入通道：NSData.writeToFile:atomically:");
    Check([status containsString:@"尝试 0；成功 0；失败 0；事件记录 0"], @"写入自检必须清零，不得冒充 SDK 写入");
    BOOL observed = [status hasPrefix:@"自检命中"];

    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"写入观察窗口应有效");
    CampusProbeResourceTraceMark(@"写入测试");
    Check([input writeToFile:path atomically:YES], @"正常写入结果应保留");
    errno = EDOM;
    BOOL failure = [input writeToFile:missing atomically:YES];
    int observedWriteError = errno;
    Check(!failure && failure == baselineFailure && observedWriteError == baselineWriteError,
        @"写入观察不得改变失败结果及 errno");
    CampusProbeResourceTraceSuspendCurrentThread();
    @try {
        Check([input writeToFile:path atomically:YES], @"暂停观察不应影响写入");
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            Check([input writeToFile:path atomically:YES], @"工作线程写入应成功");
            dispatch_semaphore_signal(done);
        });
        Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
            @"暂停当前线程时其它线程的写入应能完成");
    } @finally { CampusProbeResourceTraceResumeCurrentThread(); }
    NSArray *rows = CampusProbeResourceTraceEnd();
    status = ReportResult(rows, @"写入通道：NSData.writeToFile:atomically:");
    if (observed) {
        Check([status containsString:@"尝试 3；成功 2；失败 1；事件记录 3"],
            @"写入观察应独立统计成功、失败及工作线程，并排除暂停线程");
        Check([ReportResult(rows, @"写入事件：1") containsString:@"写入测试"], @"写入事件应关联阶段边界");
    }
    CheckReportResult(rows, @"SDK 文件入口：yw_1222.jpg", @"fopen 0，open 0；包含工作线程，不包含自检");
    CheckReportResult(rows, @"SDK 文件入口：yw_1222_mwua.jpg", @"fopen 0，open 0；包含工作线程，不包含自检");
    for (NSDictionary *row in rows) {
        NSString *text = [row[@"step"] stringByAppendingString:row[@"result"]];
        Check(![text containsString:folder] && ![text containsString:@"private-"] &&
            ![text containsString:@"probe-write-canary-"], @"写入报告不得泄露路径、文件名或输入内容");
    }

    Check(CampusProbeResourceTraceBeginWithOptions(folder, options), @"写入上限窗口应有效");
    for (int i = 0; i < 50; i++) Check([input writeToFile:path atomically:NO], @"重复写入应成功");
    status = ReportResult(CampusProbeResourceTraceEnd(), @"写入通道：NSData.writeToFile:atomically:");
    if (observed) {
        Check([status containsString:@"尝试 50；成功 50；失败 0；事件记录 48；达到记录上限"],
            @"写事件记录必须有界，溢出后仍统计调用总数");
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    Check(CampusProbeResourceTraceEnd().count == 0, @"写窗口结束后不得返回旧事件");
}

static void CheckHostChannelTrace(void) {
    NSString *main = [folder stringByAppendingPathComponent:@"yw_1222.jpg"];
    // 目录外文件在窗口开启前创建、结束后删除，避免原子写入的内部
    // fileExistsAtPath 调用污染 NSFileManager 通道计数。
    NSString *outside = [NSTemporaryDirectory() stringByAppendingPathComponent:@"probe-host-outside.jpg"];
    // 目录外且匹配安全资源命名域的文件：用于验证「目录外安全资源命名」的命中分支。
    // 名字必须不等于 yw_1222.jpg / yw_1222_mwua.jpg，否则会被当成目标命中而污染计数。
    NSString *outsideSecurity = [NSTemporaryDirectory() stringByAppendingPathComponent:@"yw_probe_outside.jpg"];
    // 故意不用 .jpg 命名的用户文件：验证收窄后的匹配不会把普通图片名记进报告。
    NSString *outsideUserPhoto = [NSTemporaryDirectory() stringByAppendingPathComponent:@"IMG_1234.JPG"];
    for (NSString *path in @[outside, outsideSecurity, outsideUserPhoto]) {
        [@"outside" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    CampusProbeTraceOptions options = CampusProbeTraceOptionsScopedFiles | CampusProbeTraceOptionsHostChannels;
    Check(CampusProbeResourceTraceBeginWithOptions(folder, options),
        @"拦截安装或 fopen/open 自检失败时不得宣称窗口有效");
    CampusProbeResourceTraceMark(@"宿主阶段");
    // 类方法通道。
    NSData *content = [NSData dataWithContentsOfFile:main];
    Check(content != nil, @"桩环境应能读取目标文件");
    // 实例 init 与 URL 通道：上一轮真机零命中的直接盲区，必须单独触发并单独断言。
    NSData *viaInit = [[NSData alloc] initWithContentsOfFile:main];
    Check(viaInit != nil, @"NSData 实例 init 通道应可用");
    NSData *viaURL = [[NSData alloc] initWithContentsOfURL:[NSURL fileURLWithPath:main]];
    Check(viaURL != nil, @"NSData URL 通道应可用");
    NSString *text = [NSString stringWithContentsOfFile:main encoding:NSISOLatin1StringEncoding error:NULL];
    Check(text != nil, @"字符串通道应可用");
    NSString *viaInitText = [[NSString alloc] initWithContentsOfFile:main
        encoding:NSISOLatin1StringEncoding error:NULL];
    Check(viaInitText != nil, @"NSString 实例 init 通道应可用");
    NSData *viaManager = [[NSFileManager defaultManager] contentsAtPath:main];
    Check(viaManager != nil, @"NSFileManager 通道应可用");
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:main];
    Check(fileHandle != nil, @"NSFileHandle 通道应可用");
    // Bundle 解析在桩环境必然失败，用于验证“无路径时按被查询资源名归类”。
    [NSBundle.mainBundle pathForResource:@"yw_1222" ofType:@"jpg"];
    // C 路径通道：access/stat/lstat/opendir。
    Check(access(main.fileSystemRepresentation, F_OK) == 0, @"access 应命中目标文件");
    struct stat probeInfo;
    Check(stat(main.fileSystemRepresentation, &probeInfo) == 0, @"stat 应命中目标文件");
    Check(lstat(main.fileSystemRepresentation, &probeInfo) == 0, @"lstat 应命中目标文件");
    DIR *handle = opendir(folder.fileSystemRepresentation);
    Check(handle != NULL, @"目录应可打开");
    closedir(handle);
    // fd 级通道：用句柄描述符触发 lseek/fstat，验证 F_GETPATH 反查能还原目标身份。
    int probeFd = fileHandle.fileDescriptor;
    Check(probeFd >= 0, @"句柄应提供有效描述符");
    Check(lseek(probeFd, 0, SEEK_SET) == 0, @"lseek 应成功以触发 fd 通道");
    struct stat fdInfo;
    Check(fstat(probeFd, &fdInfo) == 0, @"fstat 应成功以触发 fd 通道");
    // 采样排除：宿主通道同样受内部读取深度约束。
    CampusProbeResourceTraceSuspendCurrentThread();
    [NSData dataWithContentsOfFile:main];
    access(main.fileSystemRepresentation, F_OK);
    stat(main.fileSystemRepresentation, &probeInfo);
    CampusProbeResourceTraceResumeCurrentThread();
    // 目录外读取应记为目录外，不冒充目录内命中。
    [NSData dataWithContentsOfFile:outside];
    [NSData dataWithContentsOfFile:outsideSecurity];
    [NSData dataWithContentsOfFile:outsideUserPhoto];
    NSArray *rows = CampusProbeResourceTraceEnd();
    for (NSString *path in @[outside, outsideSecurity, outsideUserPhoto]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    Check(ReportResult(rows, @"宿主通道说明") != nil, @"启用宿主通道后必须输出说明行");

    // 每条通道都必须有报告行且自检命中，否则真机上的零命中无法解释。
    // 字面量步骤名在此显式断言，防止某条通道被静默丢弃而测试仍然通过。
    const char *channels[] = {"NSData", "NSDataInit", "NSString", "NSStringInit", "NSFileManager",
        "NSFileHandle", "NSBundle", "access", "opendir", "stat", "fd"};
    for (unsigned int index = 0; index < sizeof(channels) / sizeof(channels[0]); index++) {
        NSString *name = [NSString stringWithUTF8String:channels[index]];
        Check(ReportResult(rows, [@"宿主通道：" stringByAppendingString:name]) != nil,
            [NSString stringWithFormat:@"报告必须包含宿主通道 %@ 的行", name]);
        ProbeHostReport value = HostReport(rows, name);
        // stat/fd 两条通道是否自检命中，取决于 stat/lstat/fstat/lseek 的 C 符号在本平台
        // 能否绑定到探针定义（x86_64 macOS 有 $INODE64 变体，arm64 没有）。这属于平台行为，
        // 不是本测试要验证的探针逻辑，因此全平台豁免强制断言——真机报告会如实打印
        // “自检命中/未命中”，那才是判读依据。若在桩测试里强制要求，一旦平台差异就会白跑一轮 CI。
        BOOL platformDependent = [name isEqualToString:@"stat"] || [name isEqualToString:@"fd"];
        if (!platformDependent) {
            Check(value.selfChecked,
                [NSString stringWithFormat:@"宿主通道 %@ 必须自检命中，否则其零命中不可解释", name]);
        }
        Check(value.calls == value.target + value.scoped + value.outside,
            [NSString stringWithFormat:@"宿主通道 %@ 的总调用数必须等于分类之和", name]);
    }
    // 计数用 >= 断言：Foundation 内部可能转调 init 族，一次调用会计入两条通道。
    ProbeHostReport data = HostReport(rows, @"NSData");
    Check(data.target >= 1 && data.targetSame >= 1 && data.outside >= 1,
        @"NSData 通道应观察到目标读取、内容一致与目录外读取");
    ProbeHostReport dataInit = HostReport(rows, @"NSDataInit");
    Check(dataInit.target >= 1 && dataInit.targetSame >= 1, @"NSDataInit 通道应观察到目标读取与内容一致");
    ProbeHostReport string = HostReport(rows, @"NSString");
    Check(string.target >= 1, @"NSString 通道应观察到目标读取");
    ProbeHostReport stringInit = HostReport(rows, @"NSStringInit");
    Check(stringInit.target >= 1, @"NSStringInit 通道应观察到目标读取");
    ProbeHostReport manager = HostReport(rows, @"NSFileManager");
    Check(manager.target >= 1 && manager.targetSame >= 1, @"NSFileManager 通道应观察到目标读取与内容一致");
    Check(HostReport(rows, @"NSFileHandle").target >= 1, @"NSFileHandle 通道应观察到目标读取");
    Check(HostReport(rows, @"NSBundle").target >= 1, @"NSBundle 解析失败时也必须按资源名命中目标");
    Check(HostReport(rows, @"access").target >= 1, @"access 通道应观察到目标路径");
    ProbeHostReport directory = HostReport(rows, @"opendir");
    Check(directory.scoped >= 1 && directory.target == 0, @"opendir 只作用于目录，应记为目录内而非目标命中");
    // stat/fd 两条通道依赖 C 符号绑定，是否命中取决于平台（x86_64 的 $INODE64 重定向）。
    // 用 selfChecked 门控而非写死平台：自检命中说明绑定成功，此时才要求命中目标。
    // 计数只要求 >= 1 而不是精确值——例如 fd 通道需要 lseek 与 fstat 都命中才有 2，
    // 而 x86_64 上 fstat 有 $INODE64 变体、lseek 没有，可能只命中 1 次。
    // 真机 arm64 无该重定向（IR 已核对为纯 _stat），报告里会显示“自检命中”。
    ProbeHostReport statReport = HostReport(rows, @"stat");
    if (statReport.selfChecked) {
        Check(statReport.target >= 1, @"stat 通道自检命中后应观察到目标路径");
    }
    ProbeHostReport fdReport = HostReport(rows, @"fd");
    if (fdReport.selfChecked) {
        Check(fdReport.target >= 1, @"fd 通道自检命中后应经 F_GETPATH 反查出目标身份");
    }

    // 阶段行：Mark 在操作前，故“宿主阶段”为 0，全部命中汇入 End 补的“窗口结束”。
    CheckReportResult(rows, @"阶段宿主通道：宿主阶段", @"目标命中 0；目录内 0；目录外 0");
    NSString *hostEndRow = ReportResult(rows, @"阶段宿主通道：窗口结束");
    NSScanner *endScanner = [NSScanner scannerWithString:
        [hostEndRow substringFromIndex:[hostEndRow rangeOfString:@"目标命中 "].location]];
    int endTarget = 0;
    Check([endScanner scanString:@"目标命中 " intoString:NULL] && [endScanner scanInt:&endTarget],
        @"窗口结束阶段行必须可解析");
    // 下限按“平台无关且必然发生”的 target 命中次数计算，不押注 stat/fd 是否绑定成功、
    // 也不押注 Foundation 内部是否转调 init 族（转调只会让总数增加，不会减少）：
    //   NSData 1（dataWithContentsOfFile:）
    //   NSDataInit 2（initWithContentsOfFile: + initWithContentsOfURL:）
    //   NSString 1、NSStringInit 1、NSFileManager 1（contentsAtPath:）
    //   NSFileHandle 1、NSBundle 1（pathForResource: 解析失败按资源名归类）、access 1
    // 合计 9。原先写 10 会把通过与否押在 stat/fd 命中上，属于未验证的边界。
    Check(endTarget >= 9, @"窗口结束阶段应汇总各通道的目标命中");
    // 目录内/目录外同样用 >= 而非 containsString:@"目录内 1" 这类精确匹配：
    // 阶段行是各通道的汇总，Foundation 内部若对目录外路径产生任何一次调用就会变成 2，
    // 而精确字符串匹配会因此失败。这里只要求两类都被观察到——
    // 目录内来自 opendir(folder)，目录外来自对 outside 文件的读取。
    int endScoped = 0, endOutside = 0;
    NSScanner *scopedScanner = [NSScanner scannerWithString:
        [hostEndRow substringFromIndex:[hostEndRow rangeOfString:@"目录内 "].location]];
    NSScanner *outsideScanner = [NSScanner scannerWithString:
        [hostEndRow substringFromIndex:[hostEndRow rangeOfString:@"目录外 "].location]];
    Check([scopedScanner scanString:@"目录内 " intoString:NULL] && [scopedScanner scanInt:&endScoped] &&
        [outsideScanner scanString:@"目录外 " intoString:NULL] && [outsideScanner scanInt:&endOutside],
        @"窗口结束阶段行的目录内/目录外必须可解析");
    Check(endScoped >= 1, @"opendir 对照目录应被记为目录内命中");
    Check(endOutside >= 1, @"目录外读取应被记为目录外，不得冒充目录内命中");
    // 内容型通道读到的目标文件应出现在窗口文件清单，入口标注通道名。
    BOOL foundNSDataEntry = NO;
    for (NSDictionary *row in rows) {
        if ([row[@"step"] hasPrefix:@"窗口文件 "] && [row[@"result"] containsString:@"入口 NSData"]) foundNSDataEntry = YES;
    }
    Check(foundNSDataEntry, @"NSData 读到的目标文件必须进入窗口文件清单");
    // 目录外访问归类：本测试只制造一次目录外读取（outside 位于 NSTemporaryDirectory），
    // 因此合计至少 1 且必须落入“临时目录”类；各类别之和不得超过合计。
    NSString *outsideRow = ReportResult(rows, @"目录外访问归类");
    Check(outsideRow != nil, @"启用宿主通道后必须输出目录外访问归类行");
    NSScanner *scanner = [NSScanner scannerWithString:outsideRow];
    int outsideTotal = 0;
    Check([scanner scanString:@"合计 " intoString:NULL] && [scanner scanInt:&outsideTotal],
        @"目录外访问归类行必须可解析合计");
    Check(outsideTotal >= 1, @"目录外读取必须被归类计数");
    int bucketSum = 0;
    for (NSString *label in @[@"应用包内 ", @"临时目录 ", @"用户目录 ", @"系统目录 ", @"其它 "]) {
        NSRange range = [outsideRow rangeOfString:label];
        Check(range.location != NSNotFound,
            [NSString stringWithFormat:@"归类行必须包含 %@", label]);
        NSScanner *bucket = [NSScanner scannerWithString:[outsideRow substringFromIndex:range.location]];
        int value = 0;
        Check([bucket scanString:label intoString:NULL] && [bucket scanInt:&value],
            [NSString stringWithFormat:@"%@ 计数必须可解析", label]);
        bucketSum += value;
    }
    Check(bucketSum == outsideTotal, @"各类别计数之和必须等于合计，不得漏计或重复计");
    // outside 文件位于临时目录，必须被正确归类，而不是落进“其它”。
    NSRange tempRange = [outsideRow rangeOfString:@"临时目录 "];
    NSScanner *tempScanner = [NSScanner scannerWithString:[outsideRow substringFromIndex:tempRange.location]];
    int tempCount = 0;
    Check([tempScanner scanString:@"临时目录 " intoString:NULL] && [tempScanner scanInt:&tempCount],
        @"临时目录计数必须可解析");
    Check(tempCount >= 1, @"NSTemporaryDirectory 下的目录外读取必须归入临时目录类");
    // 安全资源命名行必须存在，且只记录 SecurityGuard 命名域的文件名。
    NSString *securityRow = ReportResult(rows, @"目录外安全资源命名");
    Check(securityRow != nil, @"必须输出目录外安全资源命名行（无命中时也要如实说明）");
    // 正例：目录外但符合 yw_ 命名域的文件必须被记录，证明命中分支可用。
    Check([securityRow containsString:@"yw_probe_outside.jpg"],
        @"匹配 yw_ 命名域的目录外文件必须被记录");
    // 反例：普通用户照片名（.JPG 扩展）绝不能进报告——这是收窄匹配规则的目的。
    Check(![securityRow containsString:@"IMG_1234"],
        @"普通图片文件名不得进入报告（隐私约束）");
    Check(![securityRow containsString:@"probe-host-outside"],
        @"非安全资源命名的目录外文件不得进入报告");
    // 扩展名直方图：三个目录外文件都是图片扩展名，且各类别之和等于合计。
    NSString *extRow = ReportResult(rows, @"目录外访问扩展名");
    Check(extRow != nil, @"必须输出目录外访问扩展名行");
    int extImage = 0;
    NSRange imageRange = [extRow rangeOfString:@"图片 "];
    Check(imageRange.location != NSNotFound, @"扩展名行必须包含图片类别");
    NSScanner *imageScanner = [NSScanner scannerWithString:[extRow substringFromIndex:imageRange.location]];
    Check([imageScanner scanString:@"图片 " intoString:NULL] && [imageScanner scanInt:&extImage],
        @"图片类别计数必须可解析");
    Check(extImage >= 3, @"三个目录外图片文件都应计入图片类别");
    int extSum = 0;
    for (NSString *label in @[@"图片 ", @"plist ", @"数据库/dat ", @"配置(json/xml/config) ",
                              @"无扩展名 ", @"其它 "]) {
        NSRange range = [extRow rangeOfString:label];
        Check(range.location != NSNotFound, [NSString stringWithFormat:@"扩展名行必须包含 %@", label]);
        NSScanner *bucket = [NSScanner scannerWithString:[extRow substringFromIndex:range.location]];
        int value = 0;
        Check([bucket scanString:label intoString:NULL] && [bucket scanInt:&value],
            [NSString stringWithFormat:@"%@ 计数必须可解析", label]);
        extSum += value;
    }
    Check(extSum == outsideTotal, @"扩展名各类别之和必须等于目录外合计");
    // 交叉校验：各通道的“目录外”之和必须等于归类合计。这两条计数走的是不同代码路径
    // （ProbeTallyLocked 与 ProbeRecordOutsideLocked 成对调用），相等才说明接线没漏。
    int channelOutsideSum = 0;
    for (unsigned int index = 0; index < sizeof(channels) / sizeof(channels[0]); index++) {
        channelOutsideSum += HostReport(rows,
            [NSString stringWithUTF8String:channels[index]]).outside;
    }
    Check(channelOutsideSum == outsideTotal,
        @"各通道目录外计数之和必须等于归类合计，否则存在漏计或重复计");
    for (NSDictionary *row in rows) {
        Check(![row[@"result"] containsString:folder] && ![row[@"result"] containsString:@"private-"], @"宿主通道不得泄露路径或内容");
    }
    Check(CampusProbeResourceTraceEnd().count == 0, @"结束后不能返回上一次结果");
    puts("宿主通道测试覆盖：Foundation 类方法与实例 init、access/stat/opendir、fd 反查、采样排除、目录边界与身份内容核对。");
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
        CheckFdTraceIdentity();
        CheckWriteEventTrace();
        dispatch_async(dispatch_get_main_queue(), ^{ RunCase(0); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Check(NO, @"原生测试超时"); });
        dispatch_main();
    }
}
