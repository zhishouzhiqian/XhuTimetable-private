#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 仅启用真实候选组件时提供实现，使 Swift/Objective-C 开关不一致时链接失败。
FOUNDATION_EXPORT void CampusComponentProbeRequireEnabled(void);

/// 返回固定步骤和数值错误码，不返回签名、设备标识或安全资源内容。
@interface CampusComponentProbe : NSObject
+ (void)runAtResourcePath:(NSString *)path
              appKeyHint:(nullable NSString *)appKeyHint
                progress:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))progress
              completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion
    NS_SWIFT_NAME(run(atResourcePath:appKeyHint:progress:completion:));

/// 诊断对照：不因资源不完整而跳过 SDK，直接在对照目录上执行，用于区分
/// “没有读到目标资源”与“读到后被拒绝”。不改变正式检查入口的行为，
/// 也不放宽正式入口的资源完整性校验。每个变体必须使用新的应用进程。
+ (void)runDiagnosticAtResourcePath:(NSString *)path
                            variant:(NSString *)variant
                           progress:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))progress
                         completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion
    NS_SWIFT_NAME(runDiagnostic(atResourcePath:variant:progress:completion:));

/// 对照变体列表（id 与标题）；内容全部由导入资源就地派生，不新增任何素材。
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)diagnosticVariants
    NS_SWIFT_NAME(diagnosticVariants());
@end

NS_ASSUME_NONNULL_END
