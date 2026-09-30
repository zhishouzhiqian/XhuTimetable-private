#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 返回固定步骤和数值错误码，不返回签名、设备标识或安全资源内容。
@interface CampusComponentProbe : NSObject
+ (void)runAtResourcePath:(NSString *)path completion:(void (^)(NSArray<NSDictionary<NSString *, NSString *> *> *))completion;
@end

NS_ASSUME_NONNULL_END
