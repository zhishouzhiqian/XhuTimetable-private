#import "../ios-original-probe/OriginalNetworkProbe.h"
// 金额全部使用整数分；固定目的与正文，不提供通用支付请求入口。
BOOL CampusPaymentPurpose(CampusOriginalPurpose purpose);
NSString *CampusPaymentBody(CampusOriginalPurpose purpose, NSDictionary *input);
BOOL CampusPaymentDataValid(NSDictionary *data, CampusOriginalPurpose purpose);
NSString *CampusPaymentIdentifier(id value);
NSString *CampusPaymentProgramIdentifier(id value);
long long CampusPaymentCents(id value);
NSString *CampusPaymentYuan(long long value);
NSDictionary *CampusPaymentRenderInput(NSDictionary *payload, NSString *resNo, NSString *key);
NSDictionary *CampusPaymentQuote(NSDictionary *input, NSDictionary *quote);
NSDictionary *CampusPaymentCreateInput(NSDictionary *input, NSDictionary *quote, id sequence);
NSString *CampusPaymentCreated(NSDictionary *input, NSDictionary *order);
NSString *CampusPaymentCheckout(NSDictionary *pending, NSDictionary *data);
NSString *CampusPaymentWechat(NSDictionary *pending, NSDictionary *checkout, NSArray *methods);
void CampusPaymentFail(NSString *code);
