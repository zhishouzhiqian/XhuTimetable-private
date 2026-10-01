#import <Foundation/Foundation.h>

// 只在轻量检查宿主中链接；不收集文件内容、完整路径或账号数据。
BOOL CampusProbeResourceTraceBegin(NSString *directory);
NSArray<NSDictionary<NSString *, NSString *> *> *CampusProbeResourceTraceEnd(void);
