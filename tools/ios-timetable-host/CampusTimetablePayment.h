#import "CampusTimetablePaymentProtocol.h"
typedef void (^CampusPaymentCompletion)(id result, NSString *error);
typedef void (^CampusPaymentQuery)(CampusOriginalPurpose purpose, NSDictionary *selection, CampusPaymentCompletion completion);
@interface CampusTimetablePayment : NSObject
- (instancetype)initWithQuery:(CampusPaymentQuery)query load:(NSDictionary *(^)(void))load
    save:(void (^)(NSDictionary *))save clear:(void (^)(void))clear;
- (void)resetQuote;
- (void)perform:(NSString *)action input:(NSDictionary *)input owner:(NSString *)owner completion:(CampusPaymentCompletion)completion;
@end
NSDictionary *CampusPaymentLoad(void);
void CampusPaymentSave(NSDictionary *intent);
void CampusPaymentClear(void);
