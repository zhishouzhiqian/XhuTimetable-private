#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 有界沙盒清单差集，不依赖 hook 命中。变化只能作为文件状态线索，
// 不能证明文件由 SDK 生成、被 SDK 消费或是当前失败的缓存根因。
//
// 报告只输出本进程匿名标签与大小；路径及内容摘要仅用于内存中的比较。
@interface CampusProbeContainerSnapshot : NSObject

/// 内部清单：相对路径 -> "size:hash"，另有扫描状态。不得直接复制到报告。
+ (NSDictionary<NSString *, NSString *> *)capture;

/// 本进程匿名标签；传入相同沙盒相对路径时可关联写事件与扫描差集。
/// 不是跨进程标识，不得将传入路径直接写入报告。
+ (NSString *)tagForPath:(NSString *)path;

/// 与 before 比较，报告新增、变化、未再次采集到及扫描范围。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)diffSince:(NSDictionary<NSString *, NSString *> *)before
                                                        label:(NSString *)label;

@end

NS_ASSUME_NONNULL_END
