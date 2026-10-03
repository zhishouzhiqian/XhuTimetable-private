#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const CampusOriginalConfigAPI;
// 仅构造已核对的匿名配置请求；调用方提供原 SDK 编码方法与本次原始字段。
NSURLRequest *CampusOriginalConfigRequest(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSDictionary *factors, NSString *(^encode)(NSString *));
NSURLRequest *CampusOriginalConfigRequestChecked(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSDictionary *factors, NSString *(^encode)(NSString *), NSString *__autoreleasing *reason);
BOOL CampusOriginalConfigRequestInScope(NSURLRequest *request);
NSArray *CampusOriginalConfigPreflight(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSDictionary *factors, NSString *(^encode)(NSString *));
NSDictionary *CampusOriginalConfigOutcome(NSInteger status, NSData *body, NSInteger networkError,
    BOOL redirected, BOOL oversized);
void CampusOriginalConfigSend(NSURLRequest *request, void (^completion)(NSDictionary *));

typedef NS_ENUM(NSInteger, CampusOriginalPurpose) {
    CampusOriginalPurposeConfig, CampusOriginalPurposeRegister, CampusOriginalPurposeReuse
};
FOUNDATION_EXPORT NSString *const CampusOriginalRegisterAPI;
NSString *CampusOriginalRegistrationBody(NSString *utdid, NSString *platform, NSString *mac);
NSURLRequest *CampusOriginalDeviceRequest(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSString *body, NSDictionary *factors, NSString *deviceID,
    CampusOriginalPurpose purpose, NSString *(^encode)(NSString *), NSString *__autoreleasing *reason);
BOOL CampusOriginalDeviceRequestInScope(NSURLRequest *request, CampusOriginalPurpose purpose);
NSString *CampusOriginalRegisteredDevice(NSData *body);
void CampusOriginalDeviceSend(NSURLRequest *request, CampusOriginalPurpose purpose,
    void (^completion)(NSDictionary *, NSString *));
