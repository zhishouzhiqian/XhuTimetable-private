#import <Foundation/Foundation.h>
#import "../ios-original-probe/OriginalNetworkProbe.h"
NS_ASSUME_NONNULL_BEGIN
// 固定业务操作；SDK 对象在串行队列内使用，会话由独立 Keychain 项保存并经服务端验证。
@interface CampusTimetableClient : NSObject
- (void)perform:(NSString *)action payload:(NSString *)payload completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion;
@end
NSDictionary * _Nullable CampusSessionLoad(NSDictionary *context);
void CampusSessionSave(NSDictionary *session, NSDictionary *context);
void CampusSessionClear(void);
NSDictionary * _Nullable CampusTimetableDevice(NSDictionary *payload, NSString *number);
NSDictionary * _Nullable CampusTimetableOrder(NSDictionary *row, NSDictionary * _Nullable detail);
NS_ASSUME_NONNULL_END
