#import <Foundation/Foundation.h>

// 只在轻量检查宿主中链接；不收集文件内容、完整路径或账号数据。
//
// 首版只统计两个目标资源在窗口内的 fopen/open 次数。诊断复核发现这不足以回答
// “没有读到目标资源”与“读到后被解析拒绝”的区别，因此新增两个正交能力：
//   1. 阶段标记：把窗口切成“初始化 / AppKey / 统一签名初始化 / 签名”，逐段统计；
//   2. 目录内文件清单：记录资源目录里出现的其它文件（仅文件名、大小、摘要前缀），
//      用于判断 SDK 命中的是哪一个文件。
// 两者都是附加行，不改变既有两个目标资源行的语义。

typedef NS_OPTIONS(NSUInteger, CampusProbeTraceOptions) {
    /// 与首版行为一致：只统计两个目标资源。
    CampusProbeTraceOptionsTargetsOnly = 0,
    /// 额外记录资源目录内出现的其它文件（仅文件名、大小、摘要前缀）。
    CampusProbeTraceOptionsScopedFiles = 1 << 0,
    /// 参考资源缺失时仍启用统计；缺失资源的身份与摘要无法核对。
    CampusProbeTraceOptionsAllowMissingReference = 1 << 1,
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
