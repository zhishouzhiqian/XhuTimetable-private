#import "ProbeResourceTrace.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    dev_t device;
    ino_t inode;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    unsigned int attempts, opened, sameFile, sameContent, differentContent, unreadable;
    unsigned int fopenCalls, openCalls;
    int lastError;
    int referenceAvailable;
} ProbeFileObservation;

typedef struct {
    char name[160];
    unsigned long long size;
    char digest12[13];
    char entry[8];
    int error;
    int stage;
} ProbeScopedFile;

typedef struct {
    char stage[96];
    ProbeFileObservation files[2];
    unsigned int scopedCount;
    int scopedOverflow;
} ProbeStageMark;

enum { ProbeScopedFileLimit = 48, ProbeStageMarkLimit = 16, ProbeStageNameLimit = 96 };

static const char *ProbeNames[] = {"yw_1222.jpg", "yw_1222_mwua.jpg"};
static char ProbeCanaryPath[1024];
static ProbeFileObservation ProbeCanary;
static BOOL ProbeTraceActive;
static CampusProbeTraceOptions ProbeTraceOptions;
static ProbeFileObservation ProbeFiles[2];
static ProbeScopedFile ProbeScopedFiles[ProbeScopedFileLimit];
static unsigned int ProbeScopedFileCount;
static BOOL ProbeScopedOverflow;
static ProbeStageMark ProbeStageMarks[ProbeStageMarkLimit];
static unsigned int ProbeStageMarkCount;
static char ProbeScopeRoot[1024];
static size_t ProbeScopeRootLength;
static pthread_mutex_t ProbeTraceMutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned int ProbeOpenDepth;
static _Thread_local unsigned int ProbeInternalReadDepth;
static FILE *(*ProbeOriginalFopen)(const char *, const char *);
static int (*ProbeOriginalOpen)(const char *, int, ...);
static pthread_once_t ProbeResolveOnce = PTHREAD_ONCE_INIT;

static void ProbeResolveFopen(void) {
    ProbeOriginalFopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    ProbeOriginalOpen = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
}

// 读取 fd 的摘要；顺序位置不变（调用方用 pread）。返回 NO 表示无法核对内容。
static BOOL ProbeReadDigest(int fd, unsigned char digest[CC_SHA256_DIGEST_LENGTH],
        unsigned long long *sizeOut) {
    struct stat info;
    if (fstat(fd, &info) != 0) return NO;
    if (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 65536) return NO;
    size_t size = (size_t)info.st_size;
    unsigned char *bytes = malloc(size);
    if (!bytes) return NO;
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = pread(fd, bytes + offset, size - offset, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (size_t)count;
    }
    BOOL readable = offset == size;
    if (readable) {
        CC_SHA256(bytes, (CC_LONG)size, digest);
        if (sizeOut) *sizeOut = (unsigned long long)size;
    }
    memset(bytes, 0, size);
    free(bytes);
    return readable;
}

static int ProbeStageIndexLocked(void) {
    return ProbeStageMarkCount > 0 ? (int)ProbeStageMarkCount - 1 : -1;
}

static void ProbeRecordScopedLocked(const char *path, int fd, int error, BOOL stdio) {
    if (!(ProbeTraceOptions & CampusProbeTraceOptionsScopedFiles)) return;
    if (fd < 0) return;
    if (ProbeScopedFileCount >= (unsigned int)ProbeScopedFileLimit) { ProbeScopedOverflow = YES; return; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    unsigned long long size = 0;
    if (!ProbeReadDigest(fd, digest, &size)) return;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    ProbeScopedFile *entry = &ProbeScopedFiles[ProbeScopedFileCount++];
    // 固定资源名可以展示；SDK 生成的其它文件名可能包含标识，用匿名标签区分。
    if (strcmp(name, "yw_1222.jpg") == 0 || strcmp(name, "yw_1222_mwua.jpg") == 0 ||
        strcmp(name, "Info.plist") == 0 || strcmp(name, "init.config") == 0 || strcmp(name, "update.config") == 0) {
        snprintf(entry->name, sizeof(entry->name), "%s", name);
    } else {
        unsigned char tag[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(path, (CC_LONG)strlen(path), tag);
        snprintf(entry->name, sizeof(entry->name), "file-%02x%02x%02x%02x%02x%02x",
            tag[0], tag[1], tag[2], tag[3], tag[4], tag[5]);
    }
    entry->size = size;
    for (int i = 0; i < 6; i++) snprintf(entry->digest12 + i * 2, 3, "%02x", digest[i]);
    snprintf(entry->entry, sizeof(entry->entry), "%s", stdio ? "fopen" : "open");
    entry->error = error;
    entry->stage = ProbeStageIndexLocked();
}

static BOOL ProbePathInScope(const char *path) {
    if (!ProbeScopeRootLength) return NO;
    // 相同前缀的兄弟目录和任意相对文件名均不能证明属于参考目录。
    return strncmp(path, ProbeScopeRoot, ProbeScopeRootLength) == 0 &&
        path[ProbeScopeRootLength] == '/';
}

// 两个入口共用同一窗口，覆盖 SDK 工作线程；互斥保护快照及最多 64 KiB 的摘要读取。
static void ProbeObserveFile(const char *path, int fd, int error, BOOL stdio) {
    if (!path || ProbeInternalReadDepth > 0) return;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    pthread_mutex_lock(&ProbeTraceMutex);
    if (!ProbeTraceActive) { pthread_mutex_unlock(&ProbeTraceMutex); return; }
    if (ProbeCanaryPath[0] && strcmp(path, ProbeCanaryPath) == 0) {
        if (stdio) ProbeCanary.fopenCalls++; else ProbeCanary.openCalls++;
        struct stat info;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
        if (fd >= 0 && fstat(fd, &info) == 0 &&
            info.st_dev == ProbeCanary.device && info.st_ino == ProbeCanary.inode) {
            ProbeCanary.sameFile++;
            if (ProbeReadDigest(fd, digest, NULL) &&
                memcmp(digest, ProbeCanary.digest, sizeof(digest)) == 0) ProbeCanary.sameContent++;
        }
        pthread_mutex_unlock(&ProbeTraceMutex);
        return;
    }
    for (int i = 0; i < 2; i++) {
        if (strcmp(name, ProbeNames[i]) == 0) {
            ProbeFileObservation *observation = &ProbeFiles[i];
            observation->attempts++;
            if (stdio) observation->fopenCalls++; else observation->openCalls++;
            if (fd < 0) { observation->lastError = error; break; }
            observation->opened++;
            struct stat info;
            if (fstat(fd, &info) != 0) { observation->unreadable++; break; }
            if (observation->referenceAvailable &&
                info.st_dev == observation->device && info.st_ino == observation->inode) {
                observation->sameFile++;
            }
            unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
            if (!ProbeReadDigest(fd, digest, NULL)) { observation->unreadable++; break; }
            if (!observation->referenceAvailable) break;
            if (memcmp(digest, observation->digest, sizeof(digest)) == 0) observation->sameContent++;
            else observation->differentContent++;
            break;
        }
    }
    if (ProbePathInScope(path)) ProbeRecordScopedLocked(path, fd, error, stdio);
    pthread_mutex_unlock(&ProbeTraceMutex);
}

// 委托原函数并保留 errno；嵌套调用只记最外层，避免 fopen 内部调用 open 时重复计数。
FILE *fopen(const char *path, const char *mode) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen) { errno = ENOSYS; return NULL; }
    errno = before;
    ProbeOpenDepth++;
    FILE *stream = ProbeOriginalFopen(path, mode);
    int after = errno;
    ProbeOpenDepth--;
    if (ProbeOpenDepth == 0 && mode && mode[0] == 'r') ProbeObserveFile(path, stream ? fileno(stream) : -1, after, YES);
    errno = after;
    return stream;
}

int open(const char *path, int flags, ...) {
    int before = errno;
    int mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int); // Darwin 的 mode_t 经过可变参数整型提升。
        va_end(args);
    }
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalOpen) { errno = ENOSYS; return -1; }
    errno = before;
    ProbeOpenDepth++;
    int fd = flags & O_CREAT ? ProbeOriginalOpen(path, flags, mode) : ProbeOriginalOpen(path, flags);
    int after = errno;
    ProbeOpenDepth--;
    if (ProbeOpenDepth == 0 && (flags & O_ACCMODE) != O_WRONLY) ProbeObserveFile(path, fd, after, NO);
    errno = after;
    return fd;
}

void CampusProbeResourceTraceMark(NSString *stage) {
    if (stage.length == 0) return;
    pthread_mutex_lock(&ProbeTraceMutex);
    if (ProbeTraceActive && ProbeStageMarkCount < (unsigned int)ProbeStageMarkLimit) {
        ProbeStageMark *mark = &ProbeStageMarks[ProbeStageMarkCount++];
        memset(mark, 0, sizeof(*mark));
        snprintf(mark->stage, sizeof(mark->stage), "%s",
            [stage UTF8String] ? [stage UTF8String] : "未命名阶段");
        memcpy(mark->files, ProbeFiles, sizeof(mark->files));
        mark->scopedCount = ProbeScopedFileCount;
        mark->scopedOverflow = ProbeScopedOverflow ? 1 : 0;
    }
    pthread_mutex_unlock(&ProbeTraceMutex);
}

void CampusProbeResourceTraceSuspendCurrentThread(void) { ProbeInternalReadDepth++; }
void CampusProbeResourceTraceResumeCurrentThread(void) {
    if (ProbeInternalReadDepth > 0) ProbeInternalReadDepth--;
}

BOOL CampusProbeResourceTraceBegin(NSString *directory) {
    return CampusProbeResourceTraceBeginWithOptions(directory, CampusProbeTraceOptionsTargetsOnly);
}

BOOL CampusProbeResourceTraceBeginWithOptions(NSString *directory, CampusProbeTraceOptions options) {
    pthread_mutex_lock(&ProbeTraceMutex);
    ProbeTraceActive = NO;
    ProbeTraceOptions = options;
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    memset(ProbeScopedFiles, 0, sizeof(ProbeScopedFiles));
    ProbeScopedFileCount = 0;
    ProbeScopedOverflow = NO;
    memset(ProbeStageMarks, 0, sizeof(ProbeStageMarks));
    ProbeStageMarkCount = 0;
    ProbeScopeRoot[0] = '\0';
    ProbeScopeRootLength = 0;
    ProbeCanaryPath[0] = '\0';
    memset(&ProbeCanary, 0, sizeof(ProbeCanary));
    pthread_mutex_unlock(&ProbeTraceMutex);
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen || !ProbeOriginalOpen) return NO;
    BOOL allowMissing = (options & CampusProbeTraceOptionsAllowMissingReference) != 0;
    ProbeFileObservation references[2] = {0};
    NSString *canaryPath = [directory stringByAppendingPathComponent:
        [@"probe-canary-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    for (int i = 0; i < 2; i++) {
        NSString *path = [directory stringByAppendingPathComponent:
            [NSString stringWithUTF8String:ProbeNames[i]]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        struct stat info;
        if (!data.length || data.length > 65536 || stat(path.fileSystemRepresentation, &info) != 0) {
            if (!allowMissing) return NO;
            continue;
        }
        references[i].device = info.st_dev;
        references[i].inode = info.st_ino;
        references[i].referenceAvailable = 1;
        CC_SHA256(data.bytes, (CC_LONG)data.length, references[i].digest);
    }
    // 参考资源缺失时用临时哨兵文件证明宿主跟踪入口在本进程内可用。
    BOOL needCanary = NO;
    for (int i = 0; i < 2; i++) {
        if (!references[i].referenceAvailable) needCanary = YES;
    }
    if (needCanary) {
        NSData *canaryData = [@"probe" dataUsingEncoding:NSUTF8StringEncoding];
        struct stat info;
        if (strlen(canaryPath.fileSystemRepresentation) >= sizeof(ProbeCanaryPath) ||
            ![canaryData writeToFile:canaryPath atomically:YES] ||
            stat(canaryPath.fileSystemRepresentation, &info) != 0) {
            [[NSFileManager defaultManager] removeItemAtPath:canaryPath error:nil];
            return NO;
        }
        snprintf(ProbeCanaryPath, sizeof(ProbeCanaryPath), "%s", canaryPath.fileSystemRepresentation);
        ProbeCanary.device = info.st_dev;
        ProbeCanary.inode = info.st_ino;
        CC_SHA256(canaryData.bytes, (CC_LONG)canaryData.length, ProbeCanary.digest);
    }
    const char *root = directory.fileSystemRepresentation;
    pthread_mutex_lock(&ProbeTraceMutex);
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    if (root) {
        snprintf(ProbeScopeRoot, sizeof(ProbeScopeRoot), "%s", root);
        ProbeScopeRootLength = strlen(ProbeScopeRoot);
    }
    ProbeTraceActive = YES;
    pthread_mutex_unlock(&ProbeTraceMutex);
    // 在运行中的 IPA 内验证两个入口均可观察，随后清空自检计数，避免冒充 SDK 读取。
    NSMutableArray<NSString *> *probePaths = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        if (!references[i].referenceAvailable) continue;
        [probePaths addObject:[directory stringByAppendingPathComponent:[NSString stringWithUTF8String:ProbeNames[i]]]];
    }
    if (needCanary) [probePaths addObject:canaryPath];
    for (NSString *path in probePaths) {
        FILE *stream = fopen(path.fileSystemRepresentation, "rb");
        if (stream) fclose(stream);
        int fd = open(path.fileSystemRepresentation, O_RDONLY);
        if (fd >= 0) close(fd);
    }
    pthread_mutex_lock(&ProbeTraceMutex);
    BOOL valid = !needCanary || (ProbeCanary.fopenCalls == 1 && ProbeCanary.openCalls == 1 &&
        ProbeCanary.sameFile == 2 && ProbeCanary.sameContent == 2);
    for (int i = 0; i < 2; i++) {
        // 参考资源缺失时无法核对身份与摘要；入口可用性由哨兵文件单独验证。
        if (!references[i].referenceAvailable) continue;
        valid = valid && ProbeFiles[i].fopenCalls == 1 && ProbeFiles[i].openCalls == 1 &&
            ProbeFiles[i].sameFile == 2 && ProbeFiles[i].sameContent == 2;
    }
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    memset(ProbeScopedFiles, 0, sizeof(ProbeScopedFiles));
    ProbeScopedFileCount = 0;
    ProbeScopedOverflow = NO;
    memset(ProbeStageMarks, 0, sizeof(ProbeStageMarks));
    ProbeStageMarkCount = 0;
    ProbeCanaryPath[0] = '\0';
    memset(&ProbeCanary, 0, sizeof(ProbeCanary));
    ProbeTraceActive = valid;
    pthread_mutex_unlock(&ProbeTraceMutex);
    if (needCanary) [[NSFileManager defaultManager] removeItemAtPath:canaryPath error:nil];
    return valid;
}

static NSString *ProbeObservationText(const ProbeFileObservation *value) {
    if (!value->referenceAvailable && value->attempts == 0) {
        return @"窗口内未观察到 fopen/open；参考文件缺失，无法核对身份与摘要";
    }
    if (value->attempts == 0) {
        return @"窗口内未观察到 fopen/open；不能据此判定 SDK 未读取文件";
    }
    if (!value->referenceAvailable) {
        return [NSString stringWithFormat:@"打开尝试 %u，成功 %u；参考文件缺失，仅统计入口",
            value->attempts, value->opened];
    }
    return [NSString stringWithFormat:@"打开尝试 %u，成功 %u；同一导入文件 %u；内容一致 %u，不同 %u，无法校验 %u；最近打开失败 errno %d",
        value->attempts, value->opened, value->sameFile, value->sameContent,
        value->differentContent, value->unreadable, value->lastError];
}

NSArray<NSDictionary<NSString *, NSString *> *> *CampusProbeResourceTraceEnd(void) {
    pthread_mutex_lock(&ProbeTraceMutex);
    BOOL wasActive = ProbeTraceActive;
    // 补齐最后一个边界之后的访问；传统未标记窗口仍保持四行报告。
    if (wasActive && ProbeStageMarkCount > 0 && ProbeStageMarkCount < ProbeStageMarkLimit) {
        ProbeStageMark *last = &ProbeStageMarks[ProbeStageMarkCount++];
        memset(last, 0, sizeof(*last));
        snprintf(last->stage, sizeof(last->stage), "%s", "窗口结束");
        memcpy(last->files, ProbeFiles, sizeof(last->files));
        last->scopedCount = ProbeScopedFileCount;
    }
    ProbeTraceActive = NO;
    ProbeFileObservation snapshot[2];
    memcpy(snapshot, ProbeFiles, sizeof(snapshot));
    ProbeScopedFile scoped[ProbeScopedFileLimit];
    memcpy(scoped, ProbeScopedFiles, sizeof(scoped));
    unsigned int scopedCount = ProbeScopedFileCount;
    BOOL scopedOverflow = ProbeScopedOverflow;
    ProbeStageMark marks[ProbeStageMarkLimit];
    memcpy(marks, ProbeStageMarks, sizeof(marks));
    unsigned int markCount = ProbeStageMarkCount;
    CampusProbeTraceOptions options = ProbeTraceOptions;
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    memset(ProbeScopedFiles, 0, sizeof(ProbeScopedFiles));
    ProbeScopedFileCount = 0;
    ProbeScopedOverflow = NO;
    memset(ProbeStageMarks, 0, sizeof(ProbeStageMarks));
    ProbeStageMarkCount = 0;
    ProbeTraceOptions = CampusProbeTraceOptionsTargetsOnly;
    pthread_mutex_unlock(&ProbeTraceMutex);
    if (!wasActive) return @[];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        [rows addObject:@{@"step": [@"SDK 文件访问：" stringByAppendingString:[NSString stringWithUTF8String:ProbeNames[i]]],
            @"result": ProbeObservationText(&snapshot[i])}];
        [rows addObject:@{@"step": [@"SDK 文件入口：" stringByAppendingString:[NSString stringWithUTF8String:ProbeNames[i]]],
            @"result": [NSString stringWithFormat:@"fopen %u，open %u；包含工作线程，不包含自检",
                snapshot[i].fopenCalls, snapshot[i].openCalls]}];
    }
    for (unsigned int index = 0; index < markCount; index++) {
        ProbeStageMark value = marks[index];
        ProbeStageMark previous = {0};
        if (index > 0) previous = marks[index - 1];
        [rows addObject:@{@"step": [@"阶段文件访问：" stringByAppendingString:[NSString stringWithUTF8String:value.stage]],
            @"result": [NSString stringWithFormat:@"yw_1222.jpg：%u 次（成功 %u）；yw_1222_mwua.jpg：%u 次（成功 %u）；目录内已记录访问 %u",
                value.files[0].attempts - previous.files[0].attempts, value.files[0].opened - previous.files[0].opened,
                value.files[1].attempts - previous.files[1].attempts, value.files[1].opened - previous.files[1].opened,
                value.scopedCount - previous.scopedCount]}];
    }
    if ((options & CampusProbeTraceOptionsScopedFiles) && scopedCount > 0) {
        for (unsigned int index = 0; index < scopedCount; index++) {
            ProbeScopedFile value = scoped[index];
            NSString *start = value.stage >= 0 && value.stage < (int)markCount ?
                [NSString stringWithUTF8String:marks[value.stage].stage] : @"窗口开始前";
            NSString *finish = value.stage + 1 >= 0 && value.stage + 1 < (int)markCount ?
                [NSString stringWithUTF8String:marks[value.stage + 1].stage] : @"窗口结束";
            NSString *stage = [NSString stringWithFormat:@"%@ → %@", start, finish];
            [rows addObject:@{@"step": [NSString stringWithFormat:@"窗口文件 %u", index + 1],
                @"result": [NSString stringWithFormat:@"%@；%llu 字节；摘要 %s；入口 %s；阶段 %@",
                    [NSString stringWithUTF8String:value.name], value.size, value.digest12, value.entry, stage]}];
        }
        if (scopedOverflow) {
            [rows addObject:@{@"step": @"窗口文件", @"result": @"条目已达上限，后续文件未记录"}];
        }
    }
    return rows;
}
