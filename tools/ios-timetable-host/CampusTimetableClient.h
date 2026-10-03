#import <Foundation/Foundation.h>
#import "../ios-original-probe/OriginalNetworkProbe.h"
NS_ASSUME_NONNULL_BEGIN
// 固定业务操作；SDK 对象与会话只存于本实例的串行队列。
@interface CampusTimetableClient : NSObject
- (void)perform:(NSString *)action payload:(NSString *)payload completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion;
@end
NSDictionary * _Nullable CampusTimetableDevice(NSDictionary *payload, NSString *number);
NSDictionary * _Nullable CampusTimetableOrder(NSDictionary *row, NSDictionary * _Nullable detail);
NS_ASSUME_NONNULL_END
