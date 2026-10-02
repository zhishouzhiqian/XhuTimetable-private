#import "ProbeContainerSnapshot.h"
#import "ProbeResourceTrace.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string.h>

static const NSUInteger CampusProbeSnapshotEntryLimit = 64;
static const NSUInteger CampusProbeSnapshotVisitLimit = 600;
static const size_t CampusProbeSnapshotFileByteLimit = 65536;
static NSString *const CampusProbeSnapshotStatus = @"__probe_scan_status__";

@implementation CampusProbeContainerSnapshot

+ (NSString *)digestOfFile:(NSString *)path {
    // 不跟随符号链接；只读有限字节，避免文件增长导致无界读取。
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) { close(fd); return nil; }
    unsigned long long size = (unsigned long long)info.st_size;
    if (size > CampusProbeSnapshotFileByteLimit) {
        close(fd);
        return [NSString stringWithFormat:@"%llu:未计算摘要", size];
    }
    unsigned char bytes[65537];
    size_t count = 0;
    BOOL readable = YES;
    while (count < sizeof(bytes)) {
        ssize_t value = read(fd, bytes + count, sizeof(bytes) - count);
        if (value < 0 && errno == EINTR) continue;
        if (value < 0) { readable = NO; break; }
        if (value == 0) break;
        count += (size_t)value;
    }
    close(fd);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (readable && count <= CampusProbeSnapshotFileByteLimit) CC_SHA256(bytes, (CC_LONG)count, digest);
    memset(bytes, 0, sizeof(bytes));
    if (!readable) return [NSString stringWithFormat:@"%llu:无法读取", size];
    if (count > CampusProbeSnapshotFileByteLimit) return [NSString stringWithFormat:@"%llu:读取期间超限", size];
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
    return [NSString stringWithFormat:@"%zu:%@", count, hash];
}

+ (NSDictionary<NSString *, NSString *> *)capture {
    NSMutableDictionary<NSString *, NSString *> *manifest = [NSMutableDictionary dictionary];
    // 采样自身的 open 不能冒充 SDK 访问；其它线程的 SDK 读取仍然可见。
    CampusProbeResourceTraceSuspendCurrentThread();
    @try {
        NSString *root = NSHomeDirectory();
        NSDirectoryEnumerator<NSString *> *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:root];
        NSUInteger visited = 0;
        BOOL limited = NO;
        for (NSString *relative in enumerator) {
            if (++visited > CampusProbeSnapshotVisitLimit || manifest.count >= CampusProbeSnapshotEntryLimit) {
                limited = YES; break;
            }
            if ([relative.lastPathComponent hasPrefix:@"CampusProbeDiagnostic-"]) {
                [enumerator skipDescendants]; continue;
            }
            NSString *path = [root stringByAppendingPathComponent:relative];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
            NSString *value = [self digestOfFile:path];
            if (value) manifest[relative] = value;
        }
        manifest[CampusProbeSnapshotStatus] = limited ? @"达到扫描上限" : @"扫描结束";
    } @finally { CampusProbeResourceTraceResumeCurrentThread(); }
    return manifest;
}

+ (NSString *)tagForPath:(NSString *)path {
    // 仅报告本进程稳定的匿名标签；不展示相对路径、文件名或文件内容摘要。
    static NSString *salt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ salt = NSUUID.UUID.UUIDString; });
    NSData *data = [[salt stringByAppendingString:path] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *tag = [NSMutableString stringWithString:@"file-"];
    for (int i = 0; i < 6; i++) [tag appendFormat:@"%02x", digest[i]];
    return tag;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)diffSince:(NSDictionary<NSString *, NSString *> *)before
                                                        label:(NSString *)label {
    NSDictionary<NSString *, NSString *> *after = [self capture];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    NSMutableSet<NSString *> *keys = [NSMutableSet setWithArray:before.allKeys];
    [keys addObjectsFromArray:after.allKeys];
    [keys removeObject:CampusProbeSnapshotStatus];
    for (NSString *key in [[keys allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *previous = before[key], *current = after[key];
        if (previous && current && [previous isEqualToString:current]) continue;
        NSString *change = previous == nil ? @"新增" : current == nil ? @"本次未采集到（可能删除或扫描范围变化）" : @"内容或属性变化";
        NSString *size = [[(current ?: previous) componentsSeparatedByString:@":"] firstObject];
        [rows addObject:@{@"step": [NSString stringWithFormat:@"沙盒变化（%@）：%@", label, [self tagForPath:key]],
            @"result": [NSString stringWithFormat:@"%@；%@ 字节；不能据此判定为 SDK 缓存", change, size]}];
    }
    if (rows.count == 0) {
        [rows addObject:@{@"step": [NSString stringWithFormat:@"沙盒变化（%@）", label],
            @"result": @"有限扫描内未观察到变化；不能排除未覆盖文件或内存缓存"}];
    }
    [rows addObject:@{@"step": [NSString stringWithFormat:@"沙盒扫描范围（%@）", label],
        @"result": [NSString stringWithFormat:@"之前：%@；之后：%@；最多 600 项、64 个文件，单文件摘要上限 64 KiB",
            before[CampusProbeSnapshotStatus] ?: @"未知", after[CampusProbeSnapshotStatus] ?: @"未知"]}];
    return rows;
}
@end
