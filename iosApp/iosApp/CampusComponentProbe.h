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
@end

NS_ASSUME_NONNULL_END
