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
} ProbeFileObservation;

static const char *ProbeNames[] = {"yw_1222.jpg", "yw_1222_mwua.jpg"};
static BOOL ProbeTraceActive;
static ProbeFileObservation ProbeFiles[2];
static pthread_mutex_t ProbeTraceMutex = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned int ProbeOpenDepth;
static FILE *(*ProbeOriginalFopen)(const char *, const char *);
static int (*ProbeOriginalOpen)(const char *, int, ...);
static pthread_once_t ProbeResolveOnce = PTHREAD_ONCE_INIT;

static void ProbeResolveFopen(void) {
    ProbeOriginalFopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
    ProbeOriginalOpen = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
}

// 两个入口共用同一窗口，覆盖 SDK 工作线程；互斥保护快照及最多 64 KiB 的摘要读取。
static void ProbeObserveFile(const char *path, int fd, int error, BOOL stdio) {
    if (path) {
        const char *name = strrchr(path, '/');
        name = name ? name + 1 : path;
        for (int i = 0; i < 2; i++) {
            if (strcmp(name, ProbeNames[i]) != 0) continue;
            pthread_mutex_lock(&ProbeTraceMutex);
            if (!ProbeTraceActive) { pthread_mutex_unlock(&ProbeTraceMutex); return; }
            ProbeFileObservation *observation = &ProbeFiles[i];
            observation->attempts++;
            if (stdio) observation->fopenCalls++; else observation->openCalls++;
            if (fd < 0) { observation->lastError = error; goto finished; }
            observation->opened++;
            struct stat info;
            if (fstat(fd, &info) != 0) { observation->unreadable++; goto finished; }
            if (info.st_dev == observation->device && info.st_ino == observation->inode) observation->sameFile++;
            if (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 65536) {
                observation->unreadable++; goto finished;
            }
            size_t size = (size_t)info.st_size;
            unsigned char *bytes = malloc(size);
            if (!bytes) { observation->unreadable++; goto finished; }
            size_t offset = 0;
            while (offset < size) {
                ssize_t count = pread(fd, bytes + offset, size - offset, (off_t)offset);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                offset += (size_t)count;
            }
            if (offset == size) {
                unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(bytes, (CC_LONG)size, digest);
                if (memcmp(digest, observation->digest, sizeof(digest)) == 0) observation->sameContent++;
                else observation->differentContent++;
            } else observation->unreadable++;
            memset(bytes, 0, size);
            free(bytes);
        finished:
            pthread_mutex_unlock(&ProbeTraceMutex);
            break;
        }
    }
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

BOOL CampusProbeResourceTraceBegin(NSString *directory) {
    pthread_mutex_lock(&ProbeTraceMutex);
    ProbeTraceActive = NO;
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    pthread_mutex_unlock(&ProbeTraceMutex);
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen || !ProbeOriginalOpen) return NO;
    ProbeFileObservation references[2] = {0};
    for (int i = 0; i < 2; i++) {
        NSString *path = [directory stringByAppendingPathComponent:@(ProbeNames[i])];
        NSData *data = [NSData dataWithContentsOfFile:path];
        struct stat info;
        if (!data.length || data.length > 65536 || stat(path.fileSystemRepresentation, &info) != 0) return NO;
        references[i].device = info.st_dev;
        references[i].inode = info.st_ino;
        CC_SHA256(data.bytes, (CC_LONG)data.length, references[i].digest);
    }
    pthread_mutex_lock(&ProbeTraceMutex);
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    ProbeTraceActive = YES;
    pthread_mutex_unlock(&ProbeTraceMutex);
    // 在运行中的 IPA 内验证两个入口均可观察，随后清空自检计数，避免冒充 SDK 读取。
    for (int i = 0; i < 2; i++) {
        NSString *path = [directory stringByAppendingPathComponent:@(ProbeNames[i])];
        FILE *stream = fopen(path.fileSystemRepresentation, "rb");
        if (stream) fclose(stream);
        int fd = open(path.fileSystemRepresentation, O_RDONLY);
        if (fd >= 0) close(fd);
    }
    pthread_mutex_lock(&ProbeTraceMutex);
    BOOL valid = YES;
    for (int i = 0; i < 2; i++) {
        valid = valid && ProbeFiles[i].fopenCalls == 1 && ProbeFiles[i].openCalls == 1 &&
            ProbeFiles[i].sameFile == 2 && ProbeFiles[i].sameContent == 2;
    }
    memcpy(ProbeFiles, references, sizeof(ProbeFiles));
    ProbeTraceActive = valid;
    pthread_mutex_unlock(&ProbeTraceMutex);
    return valid;
}

NSArray<NSDictionary<NSString *, NSString *> *> *CampusProbeResourceTraceEnd(void) {
    pthread_mutex_lock(&ProbeTraceMutex);
    BOOL wasActive = ProbeTraceActive;
    ProbeTraceActive = NO;
    ProbeFileObservation snapshot[2];
    memcpy(snapshot, ProbeFiles, sizeof(snapshot));
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    pthread_mutex_unlock(&ProbeTraceMutex);
    if (!wasActive) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        ProbeFileObservation value = snapshot[i];
        NSString *result = value.attempts == 0 ?
            @"窗口内未观察到 fopen/open；不能据此判定 SDK 未读取文件" :
            [NSString stringWithFormat:@"打开尝试 %u，成功 %u；同一导入文件 %u；内容一致 %u，不同 %u，无法校验 %u；最近打开失败 errno %d",
                value.attempts, value.opened, value.sameFile, value.sameContent,
                value.differentContent, value.unreadable, value.lastError];
        [rows addObject:@{@"step": [@"SDK 文件访问：" stringByAppendingString:@(ProbeNames[i])], @"result": result}];
        [rows addObject:@{@"step": [@"SDK 文件入口：" stringByAppendingString:@(ProbeNames[i])],
            @"result": [NSString stringWithFormat:@"fopen %u，open %u；包含工作线程，不包含自检", value.fopenCalls, value.openCalls]}];
    }
    return rows;
}
