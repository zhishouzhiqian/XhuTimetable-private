#import "ProbeResourceTrace.h"
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
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
    int lastError;
} ProbeFileObservation;

static const char *ProbeNames[] = {"yw_1222.jpg", "yw_1222_mwua.jpg"};
static _Thread_local BOOL ProbeTraceActive;
static _Thread_local ProbeFileObservation ProbeFiles[2];
static FILE *(*ProbeOriginalFopen)(const char *, const char *);
static pthread_once_t ProbeResolveOnce = PTHREAD_ONCE_INIT;

static void ProbeResolveFopen(void) {
    ProbeOriginalFopen = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
}

// 候选 SDK 静态库有直接 fopen 引用。委托原函数，不改变打开模式、返回流或文件位置。
// 只观察当前线程检查阶段的两个同名资源；其他线程或 open/mmap 通道不在覆盖范围。
FILE *fopen(const char *path, const char *mode) {
    int before = errno;
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen) { errno = ENOSYS; return NULL; }
    errno = before;
    FILE *stream = ProbeOriginalFopen(path, mode);
    int after = errno;
    if (ProbeTraceActive && path && mode && mode[0] == 'r') {
        const char *name = strrchr(path, '/');
        name = name ? name + 1 : path;
        for (int i = 0; i < 2; i++) {
            if (strcmp(name, ProbeNames[i]) != 0) continue;
            ProbeFileObservation *observation = &ProbeFiles[i];
            observation->attempts++;
            if (!stream) { observation->lastError = after; break; }
            observation->opened++;
            int fd = fileno(stream);
            struct stat info;
            if (fstat(fd, &info) != 0) { observation->unreadable++; break; }
            if (info.st_dev == observation->device && info.st_ino == observation->inode) observation->sameFile++;
            if (!S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 65536) {
                observation->unreadable++; break;
            }
            size_t size = (size_t)info.st_size;
            unsigned char *bytes = malloc(size);
            if (!bytes) { observation->unreadable++; break; }
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
            break;
        }
    }
    errno = after;
    return stream;
}

BOOL CampusProbeResourceTraceBegin(NSString *directory) {
    ProbeTraceActive = NO;
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    pthread_once(&ProbeResolveOnce, ProbeResolveFopen);
    if (!ProbeOriginalFopen) return NO;
    for (int i = 0; i < 2; i++) {
        NSString *path = [directory stringByAppendingPathComponent:@(ProbeNames[i])];
        NSData *data = [NSData dataWithContentsOfFile:path];
        struct stat info;
        if (!data.length || data.length > 65536 || stat(path.fileSystemRepresentation, &info) != 0) return NO;
        ProbeFiles[i].device = info.st_dev;
        ProbeFiles[i].inode = info.st_ino;
        CC_SHA256(data.bytes, (CC_LONG)data.length, ProbeFiles[i].digest);
    }
    ProbeTraceActive = YES;
    return YES;
}

NSArray<NSDictionary<NSString *, NSString *> *> *CampusProbeResourceTraceEnd(void) {
    BOOL wasActive = ProbeTraceActive;
    ProbeTraceActive = NO;
    if (!wasActive) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {
        ProbeFileObservation value = ProbeFiles[i];
        NSString *result = value.attempts == 0 ?
            @"未观察到同步 fopen；不能据此判定 SDK 未读取文件" :
            [NSString stringWithFormat:@"打开尝试 %u，成功 %u；同一导入文件 %u；内容一致 %u，不同 %u，无法校验 %u；最近打开失败 errno %d",
                value.attempts, value.opened, value.sameFile, value.sameContent,
                value.differentContent, value.unreadable, value.lastError];
        [rows addObject:@{@"step": [@"SDK 文件访问：" stringByAppendingString:@(ProbeNames[i])], @"result": result}];
    }
    memset(ProbeFiles, 0, sizeof(ProbeFiles));
    return rows;
}
