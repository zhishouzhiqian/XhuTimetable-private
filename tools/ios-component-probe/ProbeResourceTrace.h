#import <Foundation/Foundation.h>

// 只在轻量检查宿主中链接；不收集文件内容、完整路径或账号数据。
//
// 首版只统计两个目标资源在窗口内的 fopen/open 次数。诊断复核发现这不足以回答
// “没有读到目标资源”与“读到后被解析拒绝”的区别，因此新增两个正交能力：
//   1. 阶段标记：把窗口切成“初始化 / AppKey / 统一签名初始化 / 签名”，逐段统计；
//   2. 目录内文件清单：记录资源目录里出现的其它文件（仅文件名、大小、摘要前缀），
//      用于判断 SDK 命中的是哪一个文件。
// 两者都是附加行，不改变既有两个目标资源行的语义。
//
// 对候选 SGMain 的 AVMP/uvm 宿主函数表（165 项）审计发现：字节码 VM 可用的文件
// 入口只有 access/lseek/fstat/lstat/opendir/readdir/fcntl，表中没有 fopen/open/read/
// fread/stat；内容读取只能经 objc_msgSend 调 Foundation 完成。fopen/open 零命中
// 因此不能排除“字节码经宿主通道读了文件”。HostChannels 选项补上这组观察：
// 路径类 C 入口（access/opendir）与 Foundation 读方法
// （NSData/NSString/NSFileManager/NSFileHandle/NSBundle 的文件读取 selector）。
// stat/lstat/readdir 在 Darwin 存在 $INODE64 重定向，拦截命中不可靠，不列为可断言通道。

typedef NS_OPTIONS(NSUInteger, CampusProbeTraceOptions) {
    /// 与首版行为一致：只统计两个目标资源。
    CampusProbeTraceOptionsTargetsOnly = 0,
    /// 额外记录资源目录内出现的其它文件（仅文件名、大小、摘要前缀）。
    CampusProbeTraceOptionsScopedFiles = 1 << 0,
    /// 参考资源缺失时仍启用统计；缺失资源的身份与摘要无法核对。
    CampusProbeTraceOptionsAllowMissingReference = 1 << 1,
    /// 观察 AVMP/uvm 宿主通道：access/stat/lstat/opendir+readdir 与 Foundation 读方法。
    CampusProbeTraceOptionsHostChannels = 1 << 2,
};

/// 与首版等价：options 为 CampusProbeTraceOptionsTargetsOnly。
BOOL CampusProbeResourceTraceBegin(NSString *directory);

/// 诊断用：可指定选项。参考资源缺失且未指定 AllowMissingReference 时返回 NO。
BOOL CampusProbeResourceTraceBeginWithOptions(NSString *directory, CampusProbeTraceOptions options);

/// 在窗口内标记阶段边界，供 End() 输出相邻边界之间的增量。
void CampusProbeResourceTraceMark(NSString *stage);

/// 排除诊断工具自身的文件读取；只暂停当前线程，不影响 SDK 工作线程。
void CampusProbeResourceTraceSuspendCurrentThread(void);
void CampusProbeResourceTraceResumeCurrentThread(void);

NSArray<NSDictionary<NSString *, NSString *> *> *CampusProbeResourceTraceEnd(void);
