#import "ProbeResourceTrace.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <dirent.h>
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
    char entry[16];
    int error;
    int stage;
} ProbeScopedFile;

// 宿主通道计数：AVMP/uvm 宿主函数表里可用的路径入口，以及 Foundation 读方法。
typedef struct {
    unsigned int calls, target, targetSame, targetDiff, scoped, outside;
} ProbeHostRecord;

typedef int ProbeHostChannelIndex;

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
    ProbeHostChannelNSData = 0,
    ProbeHostChannelNSString,
    ProbeHostChannelFileManager,
    ProbeHostChannelFileHandle,
    ProbeHostChannelBundle,
    ProbeHostChannelAccess,
    ProbeHostChannelOpendir,
    ProbeHostChannelCount,
};

static const char *ProbeHostChannelNames[ProbeHostChannelCount] = {
    "NSData", "NSString", "NSFileManager", "NSFileHandle", "NSBundle",
    "access", "opendir",
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
static ProbeHostRecord ProbeHost[ProbeHostChannelCount];
static pthread_mutex_t ProbeTraceMutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned int ProbeOpenDepth;
static _Thread_local unsigned int ProbeInternalReadDepth;
// Foundation 读方法执行期间抑制 C 层入口，避免同一次读取被两层重复计数。
static _Thread_local unsigned int ProbeHostDepth;
static FILE *(*ProbeOriginalFopen)(const char *, const char *);
static int (*ProbeOriginalOpen)(const char *, int, ...);
static int (*ProbeOriginalAccess)(const char *, int);
static DIR *(*ProbeOriginalOpendir)(const char *);
static pthread_once_t ProbeResolveOnce = PTHREAD_ONCE_INIT;

static void ProbeResolveFopen(void) {
    ProbeOriginalFopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    ProbeOriginalOpen = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    ProbeOriginalAccess = (int (*)(const char *, int))dlsym(RTLD_NEXT, "access");
    ProbeOriginalOpendir = (DIR *(*)(const char *))dlsym(RTLD_NEXT, "opendir");
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

// 内容型宿主通道（NSData 等）已经拿到字节，直接按内容记录目录内文件身份。
static void ProbeRecordScopedContentLocked(NSString *path, NSData *content, const char *channel) {
    if (!(ProbeTraceOptions & CampusProbeTraceOptionsScopedFiles)) return;
    if (content.length == 0 || content.length > 65536) return;
    if (ProbeScopedFileCount >= (unsigned int)ProbeScopedFileLimit) { ProbeScopedOverflow = YES; return; }
    const char *full = path.fileSystemRepresentation;
    if (!full) return;
    const char *name = strrchr(full, '/');
    name = name ? name + 1 : full;
    ProbeScopedFile *entry = &ProbeScopedFiles[ProbeScopedFileCount++];
    if (strcmp(name, "yw_1222.jpg") == 0 || strcmp(name, "yw_1222_mwua.jpg") == 0 ||
        strcmp(name, "Info.plist") == 0 || strcmp(name, "init.config") == 0 || strcmp(name, "update.config") == 0) {
        snprintf(entry->name, sizeof(entry->name), "%s", name);
    } else {
        unsigned char tag[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(full, (CC_LONG)strlen(full), tag);
        snprintf(entry->name, sizeof(entry->name), "file-%02x%02x%02x%02x%02x%02x",
            tag[0], tag[1], tag[2], tag[3], tag[4], tag[5]);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(content.bytes, (CC_LONG)content.length, digest);
    entry->size = (unsigned long long)content.length;
    for (int i = 0; i < 6; i++) snprintf(entry->digest12 + i * 2, 3, "%02x", digest[i]);
    snprintf(entry->entry, sizeof(entry->entry), "%s", channel);
    entry->error = 0;
    entry->stage = ProbeStageIndexLocked();
}

static BOOL ProbePathInScope(const char *path) {
    if (!ProbeScopeRootLength) return NO;
    // 相同前缀的兄弟目录和任意相对文件名均不能证明属于参考目录。
    return strncmp(path, ProbeScopeRoot, ProbeScopeRootLength) == 0 &&
        path[ProbeScopeRootLength] == '/';
}

// matched 传 -2 表示按路径自行分类；-1 表示已知非目标；0/1 表示已知目标索引。
static void ProbeRecordHost(ProbeHostChannelIndex channel, NSString *path, int matched, NSData *content) {
    if (ProbeInternalReadDepth > 0 || ProbeHostDepth > 0) return;
    // swizzle 安装后全程生效；非活动期用无锁快路径避免每次 Foundation 读都加锁。
    // 该读为良性竞态，加锁后会再次核对 ProbeTraceActive。
    if (!ProbeTraceActive) return;
    pthread_mutex_lock(&ProbeTraceMutex);
    if (!ProbeTraceActive || !(ProbeTraceOptions & CampusProbeTraceOptionsHostChannels)) {
        pthread_mutex_unlock(&ProbeTraceMutex);
        return;
    }
    ProbeHostRecord *record = &ProbeHost[channel];
    record->calls++;
    BOOL inScope = NO;
    if (matched == -2) {
        matched = -1;
        if (path.length > 0) {
            const char *base = path.lastPathComponent.UTF8String;
            if (base) {
                for (int i = 0; i < 2; i++) {
                    if (strcmp(base, ProbeNames[i]) == 0) { matched = i; break; }
                }
            }
        }
    }
    if (path.length > 0) {
        const char *full = path.fileSystemRepresentation;
        // 对照目录本身被探测（opendir/access 目录）同样记入目录内。
        if (full) inScope = ProbePathInScope(full) ||
            (ProbeScopeRootLength && strncmp(full, ProbeScopeRoot, ProbeScopeRootLength) == 0 &&
                full[ProbeScopeRootLength] == '\0');
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
    pthread_mutex_unlock(&ProbeTraceMutex);
}

static void ProbeObserveHostPath(ProbeHostChannelIndex channel, const char *path) {
    if (!path || ProbeInternalReadDepth > 0 || ProbeHostDepth > 0) return;
    NSString *text = [NSString stringWithUTF8String:path];
    if (!text) return;
    ProbeRecordHost(channel, text, -2, nil);
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

// access/opendir 出现在候选 SGMain 的 AVMP/uvm 宿主函数表中，
// 是字节码在不能调用 fopen/open 的情况下可用的路径探测手段。
// stat/lstat/readdir 在 Darwin 存在 $INODE64 符号重定向（macOS 桩测试目标会把
// 调用改写成 readdir$INODE64 等），拦截命中不可靠，不作为可断言的观察通道；
// fstat 只接受 fd，无法按路径记账。
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

#pragma mark - Foundation 读方法拦截

static id (*ProbeOriginalNSDataWithContentsOfFile)(id, SEL, NSString *);
static id (*ProbeOriginalNSDataWithContentsOfFileOptionsError)(id, SEL, NSString *, NSDataReadingOptions, NSError **);
static id (*ProbeOriginalNSStringWithContentsOfFileEncodingError)(id, SEL, NSString *, NSStringEncoding, NSError **);
static id (*ProbeOriginalFileManagerContentsAtPath)(id, SEL, NSString *);
static BOOL (*ProbeOriginalFileManagerFileExists)(id, SEL, NSString *);
static BOOL (*ProbeOriginalFileManagerFileExistsIsDirectory)(id, SEL, NSString *, BOOL *);
static id (*ProbeOriginalFileManagerAttributes)(id, SEL, NSString *, NSError **);
static id (*ProbeOriginalFileHandleForReading)(id, SEL, NSString *);
static NSString *(*ProbeOriginalBundlePathForResource)(id, SEL, NSString *, NSString *);

static id ProbeNSDataWithContentsOfFile(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataWithContentsOfFile(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSData, path, -2, [result isKindOfClass:NSData.class] ? result : nil);
    return result;
}

static id ProbeNSDataWithContentsOfFileOptionsError(id self, SEL selector, NSString *path,
        NSDataReadingOptions options, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSDataWithContentsOfFileOptionsError(self, selector, path, options, error);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelNSData, path, -2, [result isKindOfClass:NSData.class] ? result : nil);
    return result;
}

static id ProbeNSStringWithContentsOfFileEncodingError(id self, SEL selector, NSString *path,
        NSStringEncoding encoding, NSError **error) {
    ProbeHostDepth++;
    id result = ProbeOriginalNSStringWithContentsOfFileEncodingError(self, selector, path, encoding, error);
    ProbeHostDepth--;
    // 文本解码结果不能等价于文件字节，因此不做内容核对，只记录路径命中。
    ProbeRecordHost(ProbeHostChannelNSString, path, -2, nil);
    return result;
}

static id ProbeFileManagerContentsAtPath(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileManagerContentsAtPath(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileManager, path, -2, [result isKindOfClass:NSData.class] ? result : nil);
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

// NSFileHandle 只记录路径命中；读取句柄内容会移动调用方位置，不做内容核对。
static id ProbeFileHandleForReading(id self, SEL selector, NSString *path) {
    ProbeHostDepth++;
    id result = ProbeOriginalFileHandleForReading(self, selector, path);
    ProbeHostDepth--;
    ProbeRecordHost(ProbeHostChannelFileHandle, path, -2, nil);
    return result;
}

static NSString *ProbeBundlePathForResource(id self, SEL selector, NSString *name, NSString *type) {
    ProbeHostDepth++;
    NSString *result = ProbeOriginalBundlePathForResource(self, selector, name, type);
    ProbeHostDepth--;
    int matched = -2;
    if (result.length == 0) {
        // 解析失败时没有路径可分类，改用被查询的资源名判断指向哪张目标图片。
        // ProbeNames 去掉 .jpg 扩展名后即 pathForResource: 的 name 实参。
        if ([name isEqualToString:@"yw_1222"]) matched = 0;
        else if ([name isEqualToString:@"yw_1222_mwua"]) matched = 1;
        else matched = -1;
    }
    ProbeRecordHost(ProbeHostChannelBundle, result.length > 0 ? result : nil, matched, nil);
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
    // 类方法是元类上的实例方法，因此统一用元类安装。
    complete = complete && ProbeInstallInterceptor(object_getClass(NSData.class), @selector(dataWithContentsOfFile:),
        (IMP)ProbeNSDataWithContentsOfFile, (IMP *)&ProbeOriginalNSDataWithContentsOfFile);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSData.class), @selector(dataWithContentsOfFile:options:error:),
        (IMP)ProbeNSDataWithContentsOfFileOptionsError, (IMP *)&ProbeOriginalNSDataWithContentsOfFileOptionsError);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSString.class), @selector(stringWithContentsOfFile:encoding:error:),
        (IMP)ProbeNSStringWithContentsOfFileEncodingError, (IMP *)&ProbeOriginalNSStringWithContentsOfFileEncodingError);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(contentsAtPath:),
        (IMP)ProbeFileManagerContentsAtPath, (IMP *)&ProbeOriginalFileManagerContentsAtPath);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(fileExistsAtPath:),
        (IMP)ProbeFileManagerFileExists, (IMP *)&ProbeOriginalFileManagerFileExists);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:),
        (IMP)ProbeFileManagerFileExistsIsDirectory, (IMP *)&ProbeOriginalFileManagerFileExistsIsDirectory);
    complete = complete && ProbeInstallInterceptor(NSFileManager.class, @selector(attributesOfItemAtPath:error:),
        (IMP)ProbeFileManagerAttributes, (IMP *)&ProbeOriginalFileManagerAttributes);
    complete = complete && ProbeInstallInterceptor(object_getClass(NSFileHandle.class), @selector(fileHandleForReadingAtPath:),
        (IMP)ProbeFileHandleForReading, (IMP *)&ProbeOriginalFileHandleForReading);
    complete = complete && ProbeInstallInterceptor(NSBundle.class, @selector(pathForResource:ofType:),
        (IMP)ProbeBundlePathForResource, (IMP *)&ProbeOriginalBundlePathForResource);
    return complete;
}

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
    ProbeCanaryPath[0] = '\0';
    memset(&ProbeCanary, 0, sizeof(ProbeCanary));
    memset(ProbeHost, 0, sizeof(ProbeHost));
    pthread_mutex_unlock(&ProbeTraceMutex);
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen || !ProbeOriginalOpen) return NO;
    BOOL hostChannels = (options & CampusProbeTraceOptionsHostChannels) != 0;
    if (hostChannels) {
        if (!ProbeOriginalAccess || !ProbeOriginalOpendir) return NO;
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
    // 宿主通道同样需要自检：未命中就不得宣称“该通道未被使用”。
    unsigned int hostTargets = 0;
    if (hostChannels) {
        for (NSString *path in probePaths) {
            const char *base = path.lastPathComponent.UTF8String;
            BOOL target = NO;
            for (int i = 0; i < 2; i++) {
                if (base && strcmp(base, ProbeNames[i]) == 0) { target = YES; break; }
            }
            if (target) hostTargets++;
        }
        for (NSString *path in probePaths) {
            [NSData dataWithContentsOfFile:path];
            [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
            [[NSFileManager defaultManager] contentsAtPath:path];
            [[NSFileManager defaultManager] fileExistsAtPath:path];
            [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
            access(path.fileSystemRepresentation, F_OK);
        }
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
    if (hostChannels) {
        const ProbeHostChannelIndex contentChannels[] = {
            ProbeHostChannelNSData, ProbeHostChannelNSString, ProbeHostChannelFileManager,
            ProbeHostChannelAccess,
        };
        for (unsigned int index = 0; index < sizeof(contentChannels) / sizeof(contentChannels[0]); index++) {
            const ProbeHostRecord *record = &ProbeHost[contentChannels[index]];
            // FileManager 每路径触发多个读方法，故用 >= 断言命中而非精确相等。
            valid = valid && record->calls >= probePaths.count && record->target >= hostTargets;
        }
        valid = valid && ProbeHost[ProbeHostChannelOpendir].calls >= 1;
    }
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    memset(ProbeScopedFiles, 0, sizeof(ProbeScopedFiles));
    ProbeScopedFileCount = 0;
    ProbeScopedOverflow = NO;
    memset(ProbeStageMarks, 0, sizeof(ProbeStageMarks));
    ProbeStageMarkCount = 0;
    ProbeCanaryPath[0] = '\0';
    memset(&ProbeCanary, 0, sizeof(ProbeCanary));
    memset(ProbeHost, 0, sizeof(ProbeHost));
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
            @"result": @"统计 AVMP 宿主表可用的路径入口与 Foundation 读方法；命中可证明该通道被调用，零命中仍不能证明未读取"}];
        for (int index = 0; index < ProbeHostChannelCount; index++) {
            const ProbeHostRecord *record = &host[index];
            [rows addObject:@{@"step": [@"宿主通道：" stringByAppendingString:
                [NSString stringWithUTF8String:ProbeHostChannelNames[index]]],
                @"result": [NSString stringWithFormat:@"调用 %u；目标命中 %u（内容一致 %u，不同 %u）；目录内 %u；目录外 %u",
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
