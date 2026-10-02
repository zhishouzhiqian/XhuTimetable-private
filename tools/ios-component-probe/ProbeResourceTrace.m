#import "ProbeResourceTrace.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <dirent.h>   // DIR / opendir / closedir：宿主通道的目录枚举拦截与自检
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

// Darwin 的 $INODE64 重定向（x86_64 上把 stat/lstat/fstat 改名为 *_stat$INODE64）是通过
// 头文件里的 __asm__ 标签实现的，不是宏，所以下面的 #undef 在 Darwin 上是空操作。
// 保留它只为防御：某些平台确实把 stat 定义成宏。真正的 ABI 差异由下面的
// PROBE_STAT_SYMBOL 处理（dlsym 必须取同代符号，否则结构体布局不一致）。
#ifdef stat
#undef stat
#endif
#ifdef lstat
#undef lstat
#endif

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
    char entry[16];
    int error;
    int stage;
} ProbeScopedFile;

// 宿主通道计数。selfChecked 表示本进程的自检是否真的命中了该通道：未命中说明该
// 平台/链接方式下我们的拦截不生效，此时“目标命中 0”只能解释为“这条通道不可信”，
// 不能解释为“SDK 没读”。这是上一轮零命中无法判读的直接教训。
typedef struct {
    unsigned int calls, target, targetSame, targetDiff, scoped, outside;
    BOOL selfChecked;
} ProbeHostRecord;

typedef int ProbeHostChannelIndex;

// fd→路径缓存：read/pread 是热路径，不能每次都做 F_GETPATH 系统调用。
typedef struct {
    BOOL used, resolved;
    int fd;
    char path[1024];
} ProbeFdEntry;

typedef struct {
    char stage[96];
    ProbeFileObservation files[2];
    unsigned int scopedCount;
    int scopedOverflow;
    unsigned int hostTarget, hostScoped, hostOutside;
} ProbeStageMark;

enum {
    ProbeScopedFileLimit = 48,
    ProbeStageMarkLimit = 16,
    ProbeStageNameLimit = 96,
    ProbeFdCacheLimit = 24,
    ProbeHostChannelNSData = 0,      // +dataWithContentsOfFile: 等类方法
    ProbeHostChannelNSDataInit,      // -initWithContentsOfFile: 等实例方法（上一轮盲区）
    ProbeHostChannelNSString,        // +stringWithContentsOfFile:encoding:error:
    ProbeHostChannelNSStringInit,    // -initWithContentsOfFile:...（上一轮盲区）
    ProbeHostChannelFileManager,
    ProbeHostChannelFileHandle,
    ProbeHostChannelBundle,
    ProbeHostChannelAccess,
    ProbeHostChannelOpendir,
    ProbeHostChannelStat,            // stat + lstat：SGMain IR 36+3 处调用
    ProbeHostChannelFd,              // lseek/fstat/read/pread：fd 级兜底，路径由 F_GETPATH 反查
    ProbeHostChannelCount,
};

static const char *ProbeHostChannelNames[ProbeHostChannelCount] = {
    "NSData", "NSDataInit", "NSString", "NSStringInit", "NSFileManager",
    "NSFileHandle", "NSBundle", "access", "opendir", "stat", "fd",
};
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
static char ProbeScopeRootResolved[1024];
static size_t ProbeScopeRootResolvedLength;
static ProbeHostRecord ProbeHost[ProbeHostChannelCount];
static ProbeFdEntry ProbeFdCache[ProbeFdCacheLimit];
static pthread_mutex_t ProbeTraceMutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned int ProbeOpenDepth;
static _Thread_local unsigned int ProbeInternalReadDepth;
// Foundation 读方法与探针自身摘要读取执行期间抑制下层入口，避免一次读取被重复计数。
static _Thread_local unsigned int ProbeHostDepth;
static FILE *(*ProbeOriginalFopen)(const char *, const char *);
static int (*ProbeOriginalOpen)(const char *, int, ...);
static int (*ProbeOriginalAccess)(const char *, int);
static DIR *(*ProbeOriginalOpendir)(const char *);
static int (*ProbeOriginalStat)(const char *, struct stat *);
static int (*ProbeOriginalLstat)(const char *, struct stat *);
static off_t (*ProbeOriginalLseek)(int, off_t, int);
static int (*ProbeOriginalFstat)(int, struct stat *);
static int (*ProbeOriginalClose)(int);
// 只用于 fd→路径反查，不做拦截：fcntl 是可变参数函数，转发全部 cmd 风险过高。
static int (*ProbeRealFcntl)(int, int, ...);
static pthread_once_t ProbeResolveOnce = PTHREAD_ONCE_INIT;

// x86_64 上 <sys/stat.h> 用 __DARWIN_INODE64 把 stat/lstat/fstat 的定义与调用点一起
// 改名为 *_stat$INODE64。若仍用 "stat" 去 dlsym，会拿到旧 ABI 的 _stat（st_ino 为
// 32 位），与我们传给调用方的 struct stat 布局不一致，在 Intel 构建机上会读到垃圾值。
// arm64（真机与 Apple Silicon CI）没有该变体，IR 已核对为纯 _stat。
#if defined(__x86_64__)
#define PROBE_STAT_SYMBOL "stat$INODE64"
#define PROBE_LSTAT_SYMBOL "lstat$INODE64"
#define PROBE_FSTAT_SYMBOL "fstat$INODE64"
#else
#define PROBE_STAT_SYMBOL "stat"
#define PROBE_LSTAT_SYMBOL "lstat"
#define PROBE_FSTAT_SYMBOL "fstat"
#endif

// 不在定义侧加 __DARWIN_INODE64 标签：真机目标是 arm64，IR 已核对 SGMain 引用的是
// 纯 _stat/_lstat（$INODE64 计数 0），该宏在 arm64 上本就展开为空，加了纯属多余；
// 实测 clang 会在定义处报 “expected ';' after top level declarator”。
// x86_64 macOS 桩测试环境下 stat/fd 通道可能因头文件重定向而不命中，属平台行为，
// ProbeTests.m 的 CheckHostChannelTrace 已对这两条通道豁免强制自检断言，不影响真机结论。

static void ProbeResolveFopen(void) {
    ProbeOriginalFopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    ProbeOriginalOpen = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    ProbeOriginalAccess = (int (*)(const char *, int))dlsym(RTLD_NEXT, "access");
    ProbeOriginalOpendir = (DIR *(*)(const char *))dlsym(RTLD_NEXT, "opendir");
    ProbeOriginalStat = (int (*)(const char *, struct stat *))dlsym(RTLD_NEXT, PROBE_STAT_SYMBOL);
    ProbeOriginalLstat = (int (*)(const char *, struct stat *))dlsym(RTLD_NEXT, PROBE_LSTAT_SYMBOL);
    ProbeOriginalLseek = (off_t (*)(int, off_t, int))dlsym(RTLD_NEXT, "lseek");
    ProbeOriginalFstat = (int (*)(int, struct stat *))dlsym(RTLD_NEXT, PROBE_FSTAT_SYMBOL);
    ProbeOriginalClose = (int (*)(int))dlsym(RTLD_NEXT, "close");
    ProbeRealFcntl = (int (*)(int, int, ...))dlsym(RTLD_NEXT, "fcntl");
}

// 读取 fd 的摘要；顺序位置不变（调用方用 pread）。返回 NO 表示无法核对内容。
static BOOL ProbeReadDigest(int fd, unsigned char digest[CC_SHA256_DIGEST_LENGTH],
        unsigned long long *sizeOut) {
    // 摘要读取会触发我们自己的 fstat/pread 拦截，必须抑制，否则递归计数甚至死锁。
    ProbeHostDepth++;
    struct stat info;
    BOOL usable = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) &&
        info.st_size > 0 && info.st_size <= 65536;
    size_t size = usable ? (size_t)info.st_size : 0;
    unsigned char *bytes = usable ? malloc(size) : NULL;
    BOOL readable = NO;
    if (bytes) {
        size_t offset = 0;
        while (offset < size) {
            ssize_t count = pread(fd, bytes + offset, size - offset, (off_t)offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            offset += (size_t)count;
        }
        readable = offset == size;
        if (readable) {
            CC_SHA256(bytes, (CC_LONG)size, digest);
            if (sizeOut) *sizeOut = (unsigned long long)size;
        }
        memset(bytes, 0, size);
        free(bytes);
    }
    ProbeHostDepth--;
    return readable;
}

static int ProbeStageIndexLocked(void) {
    return ProbeStageMarkCount > 0 ? (int)ProbeStageMarkCount - 1 : -1;
}

// 固定资源名可展示；其它文件名可能含标识，一律用匿名标签。
static void ProbeAnonymizeName(const char *full, const char *base, char *out, size_t size) {
    if (base && (strcmp(base, "yw_1222.jpg") == 0 || strcmp(base, "yw_1222_mwua.jpg") == 0 ||
        strcmp(base, "Info.plist") == 0 || strcmp(base, "init.config") == 0 ||
        strcmp(base, "update.config") == 0)) {
        snprintf(out, size, "%s", base);
        return;
    }
    const char *source = full && full[0] ? full : (base ? base : "");
    unsigned char tag[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(source, (CC_LONG)strlen(source), tag);
    snprintf(out, size, "file-%02x%02x%02x%02x%02x%02x",
        tag[0], tag[1], tag[2], tag[3], tag[4], tag[5]);
}

static void ProbeRecordScopedLocked(const char *path, int fd, int error, BOOL stdio) {
    if (!(ProbeTraceOptions & CampusProbeTraceOptionsScopedFiles)) return;
    if (fd < 0) return;
    if (ProbeScopedFileCount >= (unsigned int)ProbeScopedFileLimit) { ProbeScopedOverflow = YES; return; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    unsigned long long size = 0;
    if (!ProbeReadDigest(fd, digest, &size)) return;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    ProbeScopedFile *entry = &ProbeScopedFiles[ProbeScopedFileCount++];
    ProbeAnonymizeName(path, base, entry->name, sizeof(entry->name));
    entry->size = size;
    for (int i = 0; i < 6; i++) snprintf(entry->digest12 + i * 2, 3, "%02x", digest[i]);
    snprintf(entry->entry, sizeof(entry->entry), "%s", stdio ? "fopen" : "open");
    entry->error = error;
    entry->stage = ProbeStageIndexLocked();
}

// 内容型宿主通道已经拿到字节，直接按内容记录文件身份。
static void ProbeRecordScopedContentLocked(NSString *path, NSData *content, const char *channel) {
    if (!(ProbeTraceOptions & CampusProbeTraceOptionsScopedFiles)) return;
    if (!path || content.length == 0 || content.length > 65536) return;
    if (ProbeScopedFileCount >= (unsigned int)ProbeScopedFileLimit) { ProbeScopedOverflow = YES; return; }
    const char *full = path.fileSystemRepresentation;
    if (!full) return;
    const char *base = strrchr(full, '/');
    base = base ? base + 1 : full;
    ProbeScopedFile *entry = &ProbeScopedFiles[ProbeScopedFileCount++];
    ProbeAnonymizeName(full, base, entry->name, sizeof(entry->name));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(content.bytes, (CC_LONG)content.length, digest);
    entry->size = (unsigned long long)content.length;
    for (int i = 0; i < 6; i++) snprintf(entry->digest12 + i * 2, 3, "%02x", digest[i]);
    snprintf(entry->entry, sizeof(entry->entry), "%s", channel);
    entry->error = 0;
    entry->stage = ProbeStageIndexLocked();
}

// 对照目录可能以 /var/... 传入、被系统规范化成 /private/var/...（或相反）。只用字面
// 前缀比较会把真实命中错判成“目录外”，因此同时比对 realpath 解析后的前缀。
static BOOL ProbePathInScope(const char *path) {
    if (!path || !path[0]) return NO;
    if (ProbeScopeRootLength && strncmp(path, ProbeScopeRoot, ProbeScopeRootLength) == 0 &&
        (path[ProbeScopeRootLength] == '/' || path[ProbeScopeRootLength] == '\0')) return YES;
    if (!ProbeScopeRootResolvedLength) return NO;
    char resolved[1024];
    resolved[0] = '\0';
    ProbeHostDepth++;
    char *value = realpath(path, resolved);
    ProbeHostDepth--;
    if (!value) return NO;
    return strncmp(resolved, ProbeScopeRootResolved, ProbeScopeRootResolvedLength) == 0 &&
        (resolved[ProbeScopeRootResolvedLength] == '/' || resolved[ProbeScopeRootResolvedLength] == '\0');
}

// 必须在持锁状态下调用。full 为 NULL 时按非目录内处理（例如 Bundle 解析失败）。
static void ProbeTallyLocked(ProbeHostChannelIndex channel, const char *full, NSString *path,
        int matched, NSData *content) {
    ProbeHostRecord *record = &ProbeHost[channel];
    record->calls++;
    BOOL inScope = full ? ProbePathInScope(full) : NO;
    if (matched == -2) {
        matched = -1;
        if (full) {
            const char *base = strrchr(full, '/');
            base = base ? base + 1 : full;
            for (int i = 0; i < 2; i++) {
                if (strcmp(base, ProbeNames[i]) == 0) { matched = i; break; }
            }
        }
    }
    if (matched >= 0) {
        record->target++;
        if (content != nil && ProbeFiles[matched].referenceAvailable &&
            content.length > 0 && content.length <= 65536) {
            unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
            CC_SHA256(content.bytes, (CC_LONG)content.length, digest);
            if (memcmp(digest, ProbeFiles[matched].digest, sizeof(digest)) == 0) record->targetSame++;
            else record->targetDiff++;
        }
        if (content != nil && inScope) ProbeRecordScopedContentLocked(path, content, ProbeHostChannelNames[channel]);
    } else if (inScope) {
        record->scoped++;
        if (content != nil) ProbeRecordScopedContentLocked(path, content, ProbeHostChannelNames[channel]);
    } else {
        record->outside++;
    }
}

// matched 传 -2 表示按路径自行分类；-1 表示已知非目标；0/1 表示已知目标索引。
static void ProbeRecordHost(ProbeHostChannelIndex channel, NSString *path, int matched, NSData *content) {
    if (ProbeInternalReadDepth > 0 || ProbeHostDepth > 0) return;
    // 拦截安装后全程生效；非活动期走无锁快路径，避免每次 Foundation 读都加锁。
    if (!ProbeTraceActive) return;
    pthread_mutex_lock(&ProbeTraceMutex);
    if (!ProbeTraceActive || !(ProbeTraceOptions & CampusProbeTraceOptionsHostChannels)) {
        pthread_mutex_unlock(&ProbeTraceMutex);
        return;
    }
    const char *full = path.length > 0 ? path.fileSystemRepresentation : NULL;
    ProbeTallyLocked(channel, full, path, matched, content);
    pthread_mutex_unlock(&ProbeTraceMutex);
}

static void ProbeObserveHostPath(ProbeHostChannelIndex channel, const char *path) {
    if (!path || ProbeInternalReadDepth > 0 || ProbeHostDepth > 0) return;
    NSString *text = [NSString stringWithUTF8String:path];
    if (!text) return;
    ProbeRecordHost(channel, text, -2, nil);
}

// fd 级观察：先用 F_GETPATH 还原路径（带缓存），再按路径分类。字节码自己没有 open
// 宿主入口，fd 只能由 Foundation 代开，因此这是“没看见打开动作”时确认身份的唯一手段。
static void ProbeObserveFd(ProbeHostChannelIndex channel, int fd) {
    if (fd < 0 || ProbeInternalReadDepth > 0 || ProbeHostDepth > 0) return;
    if (!ProbeTraceActive) return;
    pthread_mutex_lock(&ProbeTraceMutex);
    if (!ProbeTraceActive || !(ProbeTraceOptions & CampusProbeTraceOptionsHostChannels)) {
        pthread_mutex_unlock(&ProbeTraceMutex);
        return;
    }
    int slot = -1, freeSlot = -1;
    for (int i = 0; i < ProbeFdCacheLimit; i++) {
        if (ProbeFdCache[i].used && ProbeFdCache[i].fd == fd) { slot = i; break; }
        if (freeSlot < 0 && !ProbeFdCache[i].used) freeSlot = i;
    }
    if (slot < 0) {
        if (freeSlot < 0) { pthread_mutex_unlock(&ProbeTraceMutex); return; }
        char buffer[1024];
        buffer[0] = '\0';
        BOOL ok = ProbeRealFcntl && ProbeRealFcntl(fd, F_GETPATH, buffer) == 0 && buffer[0] != '\0';
        ProbeFdCache[freeSlot].used = YES;
        ProbeFdCache[freeSlot].fd = fd;
        ProbeFdCache[freeSlot].resolved = ok;
        if (ok) snprintf(ProbeFdCache[freeSlot].path, sizeof(ProbeFdCache[freeSlot].path), "%s", buffer);
        slot = freeSlot;
    }
    ProbeHostRecord *record = &ProbeHost[channel];
    record->calls++;
    if (!ProbeFdCache[slot].resolved) { record->outside++; pthread_mutex_unlock(&ProbeTraceMutex); return; }
    const char *full = ProbeFdCache[slot].path;
    NSString *text = [NSString stringWithUTF8String:full];
    ProbeTallyLocked(channel, full, text, -2, nil);
    pthread_mutex_unlock(&ProbeTraceMutex);
}

// 两个入口共用同一窗口，覆盖 SDK 工作线程；互斥保护快照及最多 64 KiB 的摘要读取。
static void ProbeObserveFile(const char *path, int fd, int error, BOOL stdio) {
    if (!path || ProbeInternalReadDepth > 0 || ProbeHostDepth > 0) return;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    pthread_mutex_lock(&ProbeTraceMutex);
    if (!ProbeTraceActive) { pthread_mutex_unlock(&ProbeTraceMutex); return; }
    if (ProbeCanaryPath[0] && strcmp(path, ProbeCanaryPath) == 0) {
        if (stdio) ProbeCanary.fopenCalls++; else ProbeCanary.openCalls++;
        struct stat info;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
        // 此处已持有 ProbeTraceMutex，必须抑制下层拦截，否则 fstat 会重入取锁造成死锁。
        ProbeHostDepth++;
        BOOL statOk = fd >= 0 && fstat(fd, &info) == 0;
        ProbeHostDepth--;
        if (statOk && info.st_dev == ProbeCanary.device && info.st_ino == ProbeCanary.inode) {
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
            ProbeHostDepth++;
            BOOL statOk = fstat(fd, &info) == 0;
            ProbeHostDepth--;
            if (!statOk) { observation->unreadable++; break; }
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

// access/opendir/stat/lstat/lseek/fstat/read 都出现在候选 SGMain 的原生 IR 或
// AVMP/uvm 宿主函数表中，是字节码在不能调用 fopen/open 时可用的探测与读取手段。
// readdir 在 x86_64 上有 $INODE64 重定向、命中不可靠，不列为可断言通道；
// fcntl 是可变参数函数，转发全部 cmd 风险过高，只用其原始实现做路径反查。
int access(const char *path, int mode) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalAccess) { errno = ENOSYS; return -1; }
    errno = before;
    int result = ProbeOriginalAccess(path, mode);
    int after = errno;
    ProbeObserveHostPath(ProbeHostChannelAccess, path);
    errno = after;
    return result;
}

DIR *opendir(const char *path) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalOpendir) { errno = ENOSYS; return NULL; }
    errno = before;
    DIR *handle = ProbeOriginalOpendir(path);
    int after = errno;
    if (handle) ProbeObserveHostPath(ProbeHostChannelOpendir, path);
    errno = after;
    return handle;
}

// 签名与 <sys/stat.h> 的声明保持一致：Darwin 声明为
//   int stat (const char *__restrict, struct stat *__restrict);
//   int lstat(const char *__restrict, struct stat *__restrict);
//   int fstat(int, struct stat *);
// 即 stat/lstat 两个参数都带 restrict，fstat 一个都不带。C 的类型兼容判定会忽略参数
// 限定符，故 restrict 只影响告警、不影响链接。
int stat(const char *restrict path, struct stat *restrict sb) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalStat) { errno = ENOSYS; return -1; }
    errno = before;
    int result = ProbeOriginalStat(path, sb);
    int after = errno;
    ProbeObserveHostPath(ProbeHostChannelStat, path);
    errno = after;
    return result;
}

int lstat(const char *restrict path, struct stat *restrict sb) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalLstat) { errno = ENOSYS; return -1; }
    errno = before;
    int result = ProbeOriginalLstat(path, sb);
    int after = errno;
    ProbeObserveHostPath(ProbeHostChannelStat, path);
    errno = after;
    return result;
}

off_t lseek(int fd, off_t offset, int whence) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalLseek) { errno = ENOSYS; return -1; }
    errno = before;
    off_t result = ProbeOriginalLseek(fd, offset, whence);
    int after = errno;
    ProbeObserveFd(ProbeHostChannelFd, fd);
    errno = after;
    return result;
}

int fstat(int fd, struct stat *sb) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFstat) { errno = ENOSYS; return -1; }
    errno = before;
    int result = ProbeOriginalFstat(fd, sb);
    int after = errno;
    ProbeObserveFd(ProbeHostChannelFd, fd);
    errno = after;
    return result;
}

// 不拦截 read/pread：AVMP 宿主表里没有这两个入口（只有 lseek/fstat/fcntl），
// 而它们是全进程最热路径，拦截收益低、递归与性能风险高。fd 级观察由
// lseek/fstat 触发即可拿到“SDK 打开过哪个文件”的证据；字节内容改由
// Foundation swizzle 的返回值做摘要比对。

// close 不计入观察，只用于淘汰 fd→路径缓存：fd 号会被内核复用，
// 不清理会让新 fd 命中上一条旧路径，把无关文件误判成目标。
int close(int fd) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalClose) { errno = ENOSYS; return -1; }
    errno = before;
    int result = ProbeOriginalClose(fd);
    int after = errno;
    // 非活动期缓存必为空（Begin/End 都会清零），直接返回避免每次 close 都抢锁。
    // ProbeInternalReadDepth 是纵深防御：持锁路径（ProbeObserveFile/ProbeTallyLocked/
    // ProbeObserveFd）经核实都不会调用 close，但一旦将来新增，这里可避免自死锁。
    if (result == 0 && fd >= 0 && ProbeTraceActive && ProbeInternalReadDepth == 0) {
        pthread_mutex_lock(&ProbeTraceMutex);
        for (int i = 0; i < ProbeFdCacheLimit; i++) {
            if (ProbeFdCache[i].used && ProbeFdCache[i].fd == fd) {
                memset(&ProbeFdCache[i], 0, sizeof(ProbeFdCache[i]));
                break;
            }
        }
        pthread_mutex_unlock(&ProbeTraceMutex);
    }
    errno = after;
    return result;
}

#pragma mark - Foundation 读方法拦截

static id (*ProbeOriginalNSDataWithContentsOfFile)(id, SEL, NSString *);
static id (*ProbeOriginalNSDataWithContentsOfFileOptionsError)(id, SEL, NSString *, NSDataReadingOptions, NSError **);
static id (*ProbeOriginalNSDataWithContentsOfURL)(id, SEL, id);
static id (*ProbeOriginalNSDataInitWithContentsOfFile)(id, SEL, NSString *);
static id (*ProbeOriginalNSDataInitWithContentsOfFileOptionsError)(id, SEL, NSString *, NSDataReadingOptions, NSError **);
static id (*ProbeOriginalNSDataInitWithContentsOfURL)(id, SEL, id);
static id (*ProbeOriginalNSStringWithContentsOfFileEncodingError)(id, SEL, NSString *, NSStringEncoding, NSError **);
static id (*ProbeOriginalNSStringInitWithContentsOfFileEncodingError)(id, SEL, NSString *, NSStringEncoding, NSError **);
static id (*ProbeOriginalNSStringInitWithContentsOfFileUsedEncodingError)(id, SEL, NSString *, NSStringEncoding *, NSError **);
static id (*ProbeOriginalFileManagerContentsAtPath)(id, SEL, NSString *);
static BOOL (*ProbeOriginalFileManagerFileExists)(id, SEL, NSString *);
static BOOL (*ProbeOriginalFileManagerFileExistsIsDirectory)(id, SEL, NSString *, BOOL *);
static id (*ProbeOriginalFileManagerAttributes)(id, SEL, NSString *, NSError **);
static id (*ProbeOriginalFileManagerContentsOfDirectory)(id, SEL, NSString *, NSError **);
static id (*ProbeOriginalFileHandleForReading)(id, SEL, NSString *);
static id (*ProbeOriginalFileHandleForReadingFromURLError)(id, SEL, id, NSError **);
static NSString *(*ProbeOriginalBundlePathForResource)(id, SEL, NSString *, NSString *);
static NSString *(*ProbeOriginalBundlePathForResourceInDirectory)(id, SEL, NSString *, NSString *, NSString *);
static id (*ProbeOriginalBundleWithURL)(id, SEL, id);

// URL 形态可能是 file:// 或 http(s)://；只有 file URL 才代表本地文件读取。
static NSString *ProbePathFromURL(id url) {
    if (![url isKindOfClass:NSURL.class]) return nil;
    if (![(NSURL *)url isFileURL]) return nil;
    return [(NSURL *)url path];
}

static NSData *ProbeContentIfData(id result) {
    return [result isKindOfClass:NSData.class] ? (NSData *)result : nil;
}

static id ProbeNSDataWithContentsOfFile(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataWithContentsOfFile(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSData, path, -2, ProbeContentIfData(result));
    return result;
}

static id ProbeNSDataWithContentsOfFileOptionsError(id self, SEL selector, NSString *path,
        NSDataReadingOptions options, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataWithContentsOfFileOptionsError(self, selector, path, options, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSData, path, -2, ProbeContentIfData(result));
    return result;
}

static id ProbeNSDataWithContentsOfURL(id self, SEL selector, id url) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataWithContentsOfURL(self, selector, url);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSData, ProbePathFromURL(url), -2, ProbeContentIfData(result));
    return result;
}

static id ProbeNSDataInitWithContentsOfFile(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataInitWithContentsOfFile(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSDataInit, path, -2, ProbeContentIfData(result));
    return result;
}

static id ProbeNSDataInitWithContentsOfFileOptionsError(id self, SEL selector, NSString *path,
        NSDataReadingOptions options, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataInitWithContentsOfFileOptionsError(self, selector, path, options, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSDataInit, path, -2, ProbeContentIfData(result));
    return result;
}

static id ProbeNSDataInitWithContentsOfURL(id self, SEL selector, id url) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataInitWithContentsOfURL(self, selector, url);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSDataInit, ProbePathFromURL(url), -2, ProbeContentIfData(result));
    return result;
}

static id ProbeNSStringWithContentsOfFileEncodingError(id self, SEL selector, NSString *path,
        NSStringEncoding encoding, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSStringWithContentsOfFileEncodingError(self, selector, path, encoding, error);
    ProbeHostDepth--;
    // 文本解码结果不等价于文件字节，因此不做内容核对，只记录路径命中。
    ProbeRecordHost(ProbeHostChannelNSString, path, -2, nil);
    return result;
}

static id ProbeNSStringInitWithContentsOfFileEncodingError(id self, SEL selector, NSString *path,
        NSStringEncoding encoding, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSStringInitWithContentsOfFileEncodingError(self, selector, path, encoding, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSStringInit, path, -2, nil);
    return result;
}

static id ProbeNSStringInitWithContentsOfFileUsedEncodingError(id self, SEL selector, NSString *path,
        NSStringEncoding *encoding, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSStringInitWithContentsOfFileUsedEncodingError(self, selector, path, encoding, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSStringInit, path, -2, nil);
    return result;
}

static id ProbeFileManagerContentsAtPath(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileManagerContentsAtPath(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileManager, path, -2, ProbeContentIfData(result));
    return result;
}

static BOOL ProbeFileManagerFileExists(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    BOOL result = ProbeOriginalFileManagerFileExists(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileManager, path, -2, nil);
    return result;
}

static BOOL ProbeFileManagerFileExistsIsDirectory(id self, SEL selector, NSString *path, BOOL *directory) {
    ProbeHostDepth++;
    BOOL result = ProbeOriginalFileManagerFileExistsIsDirectory(self, selector, path, directory);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileManager, path, -2, nil);
    return result;
}

static id ProbeFileManagerAttributes(id self, SEL selector, NSString *path, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileManagerAttributes(self, selector, path, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileManager, path, -2, nil);
    return result;
}

static id ProbeFileManagerContentsOfDirectory(id self, SEL selector, NSString *path, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileManagerContentsOfDirectory(self, selector, path, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileManager, path, -2, nil);
    return result;
}

static id ProbeFileHandleForReading(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileHandleForReading(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileHandle, path, -2, nil);
    return result;
}

// 注意：Foundation 没有 +fileHandleForReadingAtPath:error: 这个 selector（真实 API 是
// +fileHandleForReadingFromURL:error:）。安装不存在的 selector 会让
// ProbeInstallHostInterceptors 返回 NO、整个窗口判无效，因此这里用 URL 变体，
// 既覆盖真实 API，也顺带观察 URL 形态的文件句柄创建。
static id ProbeFileHandleForReadingFromURLError(id self, SEL selector, id url, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileHandleForReadingFromURLError(self, selector, url, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileHandle, ProbePathFromURL(url), -2, nil);
    return result;
}

static int ProbeBundleMatchedName(NSString *name) {
    // pathForResource: 的 name 实参是去掉扩展名的资源名。
    if ([name isEqualToString:@"yw_1222"]) return 0;
    if ([name isEqualToString:@"yw_1222_mwua"]) return 1;
    return -1;
}

static NSString *ProbeBundlePathForResource(id self, SEL selector, NSString *name, NSString *type) {
    ProbeHostDepth++;
    NSString *result = ProbeOriginalBundlePathForResource(self, selector, name, type);
    ProbeHostDepth--;
    // 解析失败时没有路径可分类，改用被查询的资源名判断指向哪张目标图片。
    int matched = result.length > 0 ? -2 : ProbeBundleMatchedName(name);
    ProbeRecordHost(ProbeHostChannelBundle, result.length > 0 ? result : nil, matched, nil);
    return result;
}

static NSString *ProbeBundlePathForResourceInDirectory(id self, SEL selector, NSString *name,
        NSString *type, NSString *subdirectory) {
    ProbeHostDepth++;
    NSString *result = ProbeOriginalBundlePathForResourceInDirectory(self, selector, name, type, subdirectory);
    ProbeHostDepth--;
    int matched = result.length > 0 ? -2 : ProbeBundleMatchedName(name);
    ProbeRecordHost(ProbeHostChannelBundle, result.length > 0 ? result : nil, matched, nil);
    return result;
}

static id ProbeBundleWithURL(id self, SEL selector, id url) {
    ProbeHostDepth++;
    id result = ProbeOriginalBundleWithURL(self, selector, url);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelBundle, ProbePathFromURL(url), -2, nil);
    return result;
}

// 只在本类登记实现；实现来自父类时先添加再替换，避免改动父类影响系统组件。
static BOOL ProbeInstallInterceptor(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement || !original) return NO;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    *original = method_getImplementation(method);
    if (*original == replacement) return YES;
    Class owner = nil;
    // 元类链在根处自引用，用有限深度防御而非依赖 superclass 为 nil。
    Class candidate = cls;
    for (int depth = 0; candidate && depth < 32; depth++) {
        unsigned int count = 0;
        Method *list = class_copyMethodList(candidate, &count);
        BOOL found = NO;
        for (unsigned int index = 0; index < count; index++) {
            if (method_getName(list[index]) == selector) { found = YES; break; }
        }
        free(list);
        if (found) { owner = candidate; break; }
        Class next = class_getSuperclass(candidate);
        if (next == candidate) break;
        candidate = next;
    }
    if (owner == cls) {
        method_setImplementation(method, replacement);
        return YES;
    }
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) return YES;
    // 并发下本类可能刚被登记；重新取本类实现兜底替换。
    Method own = class_getInstanceMethod(cls, selector);
    if (!own) return NO;
    method_setImplementation(own, replacement);
    return YES;
}

static BOOL ProbeInstallHostInterceptors(void) {
    BOOL complete = YES;
    // 类方法是元类上的实例方法，因此统一用元类安装；实例方法直接装在类上。
    complete = complete && ProbeInstallInterceptor(object_getClass(NSData.class), @selector(dataWithContentsOfFile:),
        (IMP)ProbeNSDataWithContentsOfFile, (IMP *)&ProbeOriginalNSDataWithContentsOfFile);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSData.class), @selector(dataWithContentsOfFile:options:error:),
        (IMP)ProbeNSDataWithContentsOfFileOptionsError, (IMP *)&ProbeOriginalNSDataWithContentsOfFileOptionsError);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSData.class), @selector(dataWithContentsOfURL:),
        (IMP)ProbeNSDataWithContentsOfURL, (IMP *)&ProbeOriginalNSDataWithContentsOfURL);
    // 实例 init 族：字节码可经 objc_msgSend 直接调用而绕过类方法，是上一轮的观察盲区。
    complete = complete && ProbeInstallInterceptor(NSData.class, @selector(initWithContentsOfFile:),
        (IMP)ProbeNSDataInitWithContentsOfFile, (IMP *)&ProbeOriginalNSDataInitWithContentsOfFile);
    complete = complete && ProbeInstallInterceptor(NSData.class, @selector(initWithContentsOfFile:options:error:),
        (IMP)ProbeNSDataInitWithContentsOfFileOptionsError, (IMP *)&ProbeOriginalNSDataInitWithContentsOfFileOptionsError);
    complete = complete && ProbeInstallInterceptor(NSData.class, @selector(initWithContentsOfURL:),
        (IMP)ProbeNSDataInitWithContentsOfURL, (IMP *)&ProbeOriginalNSDataInitWithContentsOfURL);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSString.class), @selector(stringWithContentsOfFile:encoding:error:),
        (IMP)ProbeNSStringWithContentsOfFileEncodingError, (IMP *)&ProbeOriginalNSStringWithContentsOfFileEncodingError);
    complete = complete && ProbeInstallInterceptor(NSString.class, @selector(initWithContentsOfFile:encoding:error:),
        (IMP)ProbeNSStringInitWithContentsOfFileEncodingError, (IMP *)&ProbeOriginalNSStringInitWithContentsOfFileEncodingError);
    complete = complete && ProbeInstallInterceptor(NSString.class, @selector(initWithContentsOfFile:usedEncoding:error:),
        (IMP)ProbeNSStringInitWithContentsOfFileUsedEncodingError, (IMP *)&ProbeOriginalNSStringInitWithContentsOfFileUsedEncodingError);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(contentsAtPath:),
        (IMP)ProbeFileManagerContentsAtPath, (IMP *)&ProbeOriginalFileManagerContentsAtPath);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(fileExistsAtPath:),
        (IMP)ProbeFileManagerFileExists, (IMP *)&ProbeOriginalFileManagerFileExists);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:),
        (IMP)ProbeFileManagerFileExistsIsDirectory, (IMP *)&ProbeOriginalFileManagerFileExistsIsDirectory);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(attributesOfItemAtPath:error:),
        (IMP)ProbeFileManagerAttributes, (IMP *)&ProbeOriginalFileManagerAttributes);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(contentsOfDirectoryAtPath:error:),
        (IMP)ProbeFileManagerContentsOfDirectory, (IMP *)&ProbeOriginalFileManagerContentsOfDirectory);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSFileHandle.class), @selector(fileHandleForReadingAtPath:),
        (IMP)ProbeFileHandleForReading, (IMP *)&ProbeOriginalFileHandleForReading);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSFileHandle.class), @selector(fileHandleForReadingFromURL:error:),
        (IMP)ProbeFileHandleForReadingFromURLError, (IMP *)&ProbeOriginalFileHandleForReadingFromURLError);
    complete = complete && ProbeInstallInterceptor(NSBundle.class, @selector(pathForResource:ofType:),
        (IMP)ProbeBundlePathForResource, (IMP *)&ProbeOriginalBundlePathForResource);
    complete = complete && ProbeInstallInterceptor(NSBundle.class, @selector(pathForResource:ofType:inDirectory:),
        (IMP)ProbeBundlePathForResourceInDirectory, (IMP *)&ProbeOriginalBundlePathForResourceInDirectory);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSBundle.class), @selector(bundleWithURL:),
        (IMP)ProbeBundleWithURL, (IMP *)&ProbeOriginalBundleWithURL);
    return complete;
}

// 宿主通道自检一律不参与窗口否决：任一通道的平台差异（例如 x86_64 macOS 上
// stat 经 $INODE64 宏重定向、不会命中我们的定义）都不应作废整轮真机运行，
// 否则又会白跑一轮。窗口有效性由 fopen/open 自检 + 哨兵文件 + 拦截安装状态把关；
// 各通道的可信度用报告里的“自检命中/未命中”如实标注。
// 自检判据是 target>0 || scoped>0：文件类通道命中 target，
// 目录类通道（opendir、contentsOfDirectoryAtPath:）只可能命中 scoped，
// 若只看 target 会让这些通道永久显示“自检未命中”，属于误判。

static void ProbeHostTotalsLocked(unsigned int *target, unsigned int *scoped, unsigned int *outside) {
    unsigned int totalTarget = 0, totalScoped = 0, totalOutside = 0;
    for (int i = 0; i < ProbeHostChannelCount; i++) {
        totalTarget += ProbeHost[i].target;
        totalScoped += ProbeHost[i].scoped;
        totalOutside += ProbeHost[i].outside;
    }
    if (target) *target = totalTarget;
    if (scoped) *scoped = totalScoped;
    if (outside) *outside = totalOutside;
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
        ProbeHostTotalsLocked(&mark->hostTarget, &mark->hostScoped, &mark->hostOutside);
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
    ProbeScopeRootResolved[0] = '\0';
    ProbeScopeRootResolvedLength = 0;
    ProbeCanaryPath[0] = '\0';
    memset(&ProbeCanary, 0, sizeof(ProbeCanary));
    memset(ProbeHost, 0, sizeof(ProbeHost));
    memset(ProbeFdCache, 0, sizeof(ProbeFdCache));
    pthread_mutex_unlock(&ProbeTraceMutex);
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen || !ProbeOriginalOpen) return NO;
    BOOL hostChannels = (options & CampusProbeTraceOptionsHostChannels) != 0;
    if (hostChannels) {
        if (!ProbeOriginalAccess || !ProbeOriginalOpendir || !ProbeOriginalStat ||
            !ProbeOriginalLstat || !ProbeOriginalLseek || !ProbeOriginalFstat) return NO;
        // 拦截安装结果按进程恒定，只需一次；失败不得宣称宿主通道未被使用。
        static dispatch_once_t interceptors;
        static BOOL interceptorState;
        dispatch_once(&interceptors, ^{ interceptorState = ProbeInstallHostInterceptors(); });
        if (!interceptorState) return NO;
    }
    BOOL allowMissing = (options & CampusProbeTraceOptionsAllowMissingReference) != 0;
    ProbeFileObservation references[2] = {0};
    NSString *canaryPath = [directory stringByAppendingPathComponent:
        [@"probe-canary-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    // 目录范围同时保留字面与规范化两种前缀，避免 /var 与 /private/var 造成误判。
    ProbeHostDepth++;
    NSString *resolvedDirectory = [directory stringByResolvingSymlinksInPath] ?: directory;
    ProbeHostDepth--;
    for (int i = 0; i < 2; i++) {
        NSString *path = [directory stringByAppendingPathComponent:
            [NSString stringWithUTF8String:ProbeNames[i]]];
        ProbeHostDepth++;
        NSData *data = [NSData dataWithContentsOfFile:path];
        struct stat info;
        BOOL statOk = stat(path.fileSystemRepresentation, &info) == 0;
        ProbeHostDepth--;
        if (!data.length || data.length > 65536 || !statOk) {
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
        // 顺序不可颠倒：必须先写入哨兵文件，再 stat 它取 dev/ino。
        // 反过来 stat 会因文件尚不存在而必然失败，导致整个窗口被判无效——
        // bc59d50 就是这样让桩测试「两图缺失时必须校验哨兵的两个入口」失败的。
        // 整段包在 ProbeHostDepth 抑制内：writeToFile:atomically: 内部可能触发我们
        // 拦截的 NSFileManager 方法，不得计入 SDK 的通道命中。
        ProbeHostDepth++;
        BOOL written = [canaryData writeToFile:canaryPath atomically:YES];
        struct stat info;
        BOOL statOk = written && stat(canaryPath.fileSystemRepresentation, &info) == 0;
        ProbeHostDepth--;
        if (strlen(canaryPath.fileSystemRepresentation) >= sizeof(ProbeCanaryPath) || !statOk) {
            [[NSFileManager defaultManager] removeItemAtPath:canaryPath error:nil];
            return NO;
        }
        snprintf(ProbeCanaryPath, sizeof(ProbeCanaryPath), "%s", canaryPath.fileSystemRepresentation);
        ProbeCanary.device = info.st_dev;
        ProbeCanary.inode = info.st_ino;
        CC_SHA256(canaryData.bytes, (CC_LONG)canaryData.length, ProbeCanary.digest);
    }
    const char *root = directory.fileSystemRepresentation;
    const char *rootResolved = resolvedDirectory.fileSystemRepresentation;
    pthread_mutex_lock(&ProbeTraceMutex);
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    if (root) {
        snprintf(ProbeScopeRoot, sizeof(ProbeScopeRoot), "%s", root);
        ProbeScopeRootLength = strlen(ProbeScopeRoot);
    }
    if (rootResolved) {
        snprintf(ProbeScopeRootResolved, sizeof(ProbeScopeRootResolved), "%s", rootResolved);
        ProbeScopeRootResolvedLength = strlen(ProbeScopeRootResolved);
    }
    ProbeTraceActive = YES;
    pthread_mutex_unlock(&ProbeTraceMutex);
    // 在运行中的 IPA 内验证各入口均可观察，随后清空自检计数，避免冒充 SDK 读取。
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
    // 宿主通道同样需要自检：未命中的通道必须在报告里标注为不可信，
    // 否则“目标命中 0”会被误读成“SDK 没读文件”。
    if (hostChannels) {
        for (NSString *path in probePaths) {
            const char *cpath = path.fileSystemRepresentation;
            NSString *baseName = path.lastPathComponent.stringByDeletingPathExtension;
            NSString *extension = path.pathExtension;
            NSURL *fileURL = [NSURL fileURLWithPath:path];
            // 自检的目的只是让每条拦截都真的被触发一次，返回值本身不需要使用。
            // clang 对 init 族方法的未使用结果会报 -Wunused-value，故显式 (void) 丢弃。
            [NSData dataWithContentsOfFile:path];
            [NSData dataWithContentsOfFile:path options:0 error:NULL];
            [NSData dataWithContentsOfURL:fileURL];
            (void)[[NSData alloc] initWithContentsOfFile:path];
            (void)[[NSData alloc] initWithContentsOfFile:path options:0 error:NULL];
            (void)[[NSData alloc] initWithContentsOfURL:fileURL];
            [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
            (void)[[NSString alloc] initWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
            (void)[[NSString alloc] initWithContentsOfFile:path usedEncoding:NULL error:NULL];
            NSFileManager *manager = [NSFileManager defaultManager];
            [manager contentsAtPath:path];
            [manager fileExistsAtPath:path];
            BOOL isDirectory = NO;
            [manager fileExistsAtPath:path isDirectory:&isDirectory];
            [manager attributesOfItemAtPath:path error:NULL];
            [NSFileHandle fileHandleForReadingAtPath:path];
            [NSFileHandle fileHandleForReadingFromURL:fileURL error:NULL];
            [NSBundle.mainBundle pathForResource:baseName ofType:extension];
            [NSBundle.mainBundle pathForResource:baseName ofType:extension inDirectory:nil];
            access(cpath, F_OK);
            struct stat probeInfo;
            stat(cpath, &probeInfo);
            lstat(cpath, &probeInfo);
            // fd 级自检不得再调用 open：那会抬高 ProbeFiles 的 openCalls/sameFile，
            // 使窗口有效性校验失败、整轮真机运行被判废。改用 NSFileHandle 派生的
            // 描述符（Foundation 内部的 open 绑定到 libSystem，不经过我们的定义），
            // 再调用 lseek/fstat 验证 fd→路径反查链路。描述符由句柄持有，不能自行 close。
            NSFileHandle *probeHandle = [NSFileHandle fileHandleForReadingAtPath:path];
            if (probeHandle) {
                int probeFd = probeHandle.fileDescriptor;
                if (probeFd >= 0) {
                    lseek(probeFd, 0, SEEK_SET);
                    struct stat fdInfo;
                    fstat(probeFd, &fdInfo);
                }
            }
        }
        [NSBundle bundleWithURL:[NSURL fileURLWithPath:directory]];
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL];
        DIR *probeDirectory = opendir(directory.fileSystemRepresentation);
        if (probeDirectory) closedir(probeDirectory);
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
    // 宿主通道一律不参与窗口否决：任一通道的平台差异都不应作废整轮真机运行，
    // 否则又会白跑一轮。有效性由 fopen/open 自检 + canary + 拦截安装状态把关。
    // 自检判据用 target>0 || scoped>0：文件类通道命中 target，
    // 目录类通道（opendir、contentsOfDirectoryAtPath:）只可能命中 scoped，
    // 若只看 target 会让这些通道永久显示“自检未命中”，属于误判。
    if (hostChannels) {
        for (int index = 0; index < ProbeHostChannelCount; index++) {
            ProbeHostRecord *record = &ProbeHost[index];
            record->selfChecked = record->calls > 0 && (record->target > 0 || record->scoped > 0);
        }
    }
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    memset(ProbeScopedFiles, 0, sizeof(ProbeScopedFiles));
    ProbeScopedFileCount = 0;
    ProbeScopedOverflow = NO;
    memset(ProbeStageMarks, 0, sizeof(ProbeStageMarks));
    ProbeStageMarkCount = 0;
    ProbeCanaryPath[0] = '\0';
    memset(&ProbeCanary, 0, sizeof(ProbeCanary));
    memset(ProbeFdCache, 0, sizeof(ProbeFdCache));
    // 清零计数但保留 selfChecked，供报告标注每条通道是否可信。
    for (int i = 0; i < ProbeHostChannelCount; i++) {
        BOOL checked = ProbeHost[i].selfChecked;
        memset(&ProbeHost[i], 0, sizeof(ProbeHost[i]));
        ProbeHost[i].selfChecked = checked;
    }
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
    CampusProbeTraceOptions options = ProbeTraceOptions;
    // 补齐最后一个边界之后的访问；传统未标记窗口仍保持四行报告。
    if (wasActive && ProbeStageMarkCount > 0 && ProbeStageMarkCount < ProbeStageMarkLimit) {
        ProbeStageMark *last = &ProbeStageMarks[ProbeStageMarkCount++];
        memset(last, 0, sizeof(*last));
        snprintf(last->stage, sizeof(last->stage), "%s", "窗口结束");
        memcpy(last->files, ProbeFiles, sizeof(last->files));
        last->scopedCount = ProbeScopedFileCount;
        ProbeHostTotalsLocked(&last->hostTarget, &last->hostScoped, &last->hostOutside);
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
    ProbeHostRecord host[ProbeHostChannelCount];
    memcpy(host, ProbeHost, sizeof(host));
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    memset(ProbeScopedFiles, 0, sizeof(ProbeScopedFiles));
    ProbeScopedFileCount = 0;
    ProbeScopedOverflow = NO;
    memset(ProbeStageMarks, 0, sizeof(ProbeStageMarks));
    ProbeStageMarkCount = 0;
    memset(ProbeHost, 0, sizeof(ProbeHost));
    memset(ProbeFdCache, 0, sizeof(ProbeFdCache));
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
    BOOL hostEnabled = (options & CampusProbeTraceOptionsHostChannels) != 0;
    if (hostEnabled) {
        [rows addObject:@{@"step": @"宿主通道说明",
            @"result": @"统计原生 IR 与 AVMP 宿主表可用的路径/fd 入口及 Foundation 读方法；"
                        "仅“自检命中”的通道，其目标命中 0 才可解释为该通道未读到目标"}];
        for (int index = 0; index < ProbeHostChannelCount; index++) {
            const ProbeHostRecord *record = &host[index];
            [rows addObject:@{@"step": [@"宿主通道：" stringByAppendingString:
                [NSString stringWithUTF8String:ProbeHostChannelNames[index]]],
                @"result": [NSString stringWithFormat:@"%@；调用 %u；目标命中 %u（内容一致 %u，不同 %u）；目录内 %u；目录外 %u",
                    record->selfChecked ? @"自检命中" : @"自检未命中（本通道结果不可信）",
                    record->calls, record->target, record->targetSame, record->targetDiff,
                    record->scoped, record->outside]}];
        }
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
        if (hostEnabled) {
            [rows addObject:@{@"step": [@"阶段宿主通道：" stringByAppendingString:[NSString stringWithUTF8String:value.stage]],
                @"result": [NSString stringWithFormat:@"目标命中 %u；目录内 %u；目录外 %u",
                    value.hostTarget - previous.hostTarget, value.hostScoped - previous.hostScoped,
                    value.hostOutside - previous.hostOutside]}];
        }
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
