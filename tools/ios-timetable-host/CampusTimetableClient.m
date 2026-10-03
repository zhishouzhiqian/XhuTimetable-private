#import "CampusTimetableClient.h"

__attribute__((visibility("default"))) const char *CampusTimetableHostVersion = "xhu-campus-timetable-host:1";

void CampusOriginalProbeNetworkRun(NSDictionary *, NSString *, void (^)(NSArray *), void (^)(NSDictionary *), void (^)(NSArray *));
NSURLRequest *CampusTimetableAccountRequest(NSDictionary *, NSDictionary *, CampusOriginalPurpose, NSDictionary *, NSString *);

@interface CampusTimetableClient ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSDictionary *context;
@property(nonatomic, copy) NSDictionary *session;
@property(nonatomic) BOOL busy;
@end

@implementation CampusTimetableClient
- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("vip.mystery0.campus.client", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)query:(CampusOriginalPurpose)purpose selection:(NSDictionary *)selection code:(NSString *)code
    completion:(void (^)(NSDictionary *, NSString *))completion {
    NSURLRequest *request = nil;
    @try { request = CampusTimetableAccountRequest(self.context, self.session, purpose, selection, code); }
    @catch (NSException *exception) { }
    if (!request) { completion(nil, @"洗衣请求签名或参数校验失败。"); return; }
    CampusOriginalAccountSend(request, purpose, ^(NSDictionary *outcome, NSDictionary *evidence) {
        dispatch_async(self.queue, ^{
            if ([outcome[@"requiresLogin"] boolValue]) { self.session = nil; completion(nil, @"SESSION_EXPIRED"); }
            else if (![outcome[@"success"] boolValue] || !evidence) completion(nil, @"洗衣查询失败，请检查网络后重试。");
            else completion(evidence, nil);
        });
    });
}
- (void)runningDetails:(NSArray *)rows index:(NSUInteger)index results:(NSMutableArray *)results
    completion:(void (^)(id, NSString *))completion {
    if (index == rows.count) { completion([results copy], nil); return; }
    NSDictionary *row = rows[index];
    NSMutableDictionary *selection = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"bizOrderId", @"mixBuyerId", @"isvOrderId"]) {
        id value = [key isEqual:@"bizOrderId"] ? (row[@"bizOrderIdStr"] ?: row[key]) : row[key];
        if (value) selection[key] = value;
    }
    if (selection.count != 3) { completion(nil, @"运行订单身份字段缺失，未查询详情。"); return; }
    [self query:CampusOriginalPurposeOrderDetail selection:selection code:nil completion:^(NSDictionary *evidence, NSString *error) {
        if (error) { completion(nil, error); return; }
        NSDictionary *order = CampusTimetableOrder(row, evidence[@"payload"][@"data"][@"response"]);
        if (!order) { completion(nil, @"订单详情与本人列表不一致。"); return; }
        [results addObject:order];
        [self runningDetails:rows index:index + 1 results:results completion:completion];
    }];
}
- (void)perform:(NSString *)action payload:(NSString *)payload completion:(void (^)(NSString *, NSString *))completion {
    dispatch_async(self.queue, ^{
        if (self.busy) { completion(nil, @"上一项洗衣查询尚未结束，请稍后重试。"); return; }
        self.busy = YES;
        void (^finish)(id, NSString *) = ^(id result, NSString *error) {
            self.busy = NO;
            NSData *bytes = result && !error ? [NSJSONSerialization dataWithJSONObject:result options:0 error:nil] : nil;
            completion(bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil,
                error ?: (bytes ? nil : @"洗衣返回值校验失败。"));
        };
        @try {
            NSData *bytes = payload.length <= 8192 ? [payload dataUsingEncoding:NSUTF8StringEncoding] : nil;
            id input = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
            if (![input isKindOfClass:NSDictionary.class]) { finish(nil, @"洗衣参数无效。"); return; }
            if ([action isEqual:@"initialize"]) {
                if (self.context) { finish(@{}, nil); return; }
                __block NSDictionary *prepared = nil;
                CampusOriginalProbeNetworkRun(NSBundle.mainBundle.infoDictionary[@"CampusOriginalProbe"], NSBundle.mainBundle.bundlePath,
                    nil, ^(NSDictionary *ready) { prepared = ready; }, ^(NSArray *unused) {
                        dispatch_async(self.queue, ^{ self.context = prepared; finish(prepared ? @{} : nil, prepared ? nil : @"校园组件初始化或设备注册未通过。"); });
                    });
                return;
            }
            if ([action isEqual:@"logout"]) { self.session = nil; finish(@{}, nil); return; }
            if ([action isEqual:@"hasSession"]) { finish(@{@"present": @(self.session != nil)}, nil); return; }
            if (!self.context) { finish(nil, @"校园客户端尚未初始化。"); return; }
            if ([action isEqual:@"authorizationUrl"]) {
                NSURL *url = CampusOriginalAuthorizationURL(self.context[@"x-appkey"]);
                finish(url ? @{@"url": url.absoluteString} : nil, nil); return;
            }
            if ([action isEqual:@"exchange"]) {
                self.session = nil;
                if ([input count] != 1 || ![input[@"code"] isKindOfClass:NSString.class]) { finish(nil, @"授权结果无效。"); return; }
                [self query:CampusOriginalPurposeLogin selection:nil code:input[@"code"] completion:^(NSDictionary *evidence, NSString *error) {
                    if (evidence) self.session = @{@"sid": evidence[@"sid"], @"uid": evidence[@"uid"]};
                    finish(evidence ? @{} : nil, error);
                }]; return;
            }
            if (!self.session) { finish(nil, @"SESSION_EXPIRED"); return; }
            if ([action isEqual:@"verify"]) {
                [self query:CampusOriginalPurposeProfile selection:nil code:nil completion:^(NSDictionary *evidence, NSString *error) { finish(evidence ? @{} : nil, error); }]; return;
            }
            if ([action isEqual:@"device"]) {
                NSString *number = CampusOriginalMachineNumber(input[@"resNo"]);
                if ([input count] != 1 || ![number isEqual:input[@"resNo"]]) { finish(nil, @"机器编号无效。"); return; }
                [self query:CampusOriginalPurposeDeviceInfo selection:@{@"resNo": number} code:nil completion:^(NSDictionary *evidence, NSString *error) {
                    finish(evidence ? CampusTimetableDevice(evidence[@"payload"], number) : nil, error);
                }]; return;
            }
            if ([action isEqual:@"running"] || [action isEqual:@"history"]) {
                BOOL running = [action isEqual:@"running"];
                [self query:running ? CampusOriginalPurposeOrders : CampusOriginalPurposeHistory selection:nil code:nil
                    completion:^(NSDictionary *evidence, NSString *error) {
                        if (error) { finish(nil, error); return; }
                        NSArray *rows = evidence[@"payload"][@"data"][running ? @"urgentOrderListResponse" : @"orderListResponses"];
                        if (running) {
                            // 列表的剩余秒数以收到列表的单调时间为基准，不把详情查询耗时加回倒计时。
                            NSNumber *sampledAt = @((long long)(NSProcessInfo.processInfo.systemUptime * 1000));
                            [self runningDetails:rows index:0 results:[NSMutableArray array] completion:^(id orders, NSString *detailError) {
                                finish(orders ? @{@"orders": orders, @"observedAt": sampledAt} : nil, detailError);
                            }];
                        }
                        else {
                            NSMutableArray *result = [NSMutableArray array];
                            for (NSDictionary *row in rows) {
                                NSDictionary *order = CampusTimetableOrder(row, nil);
                                if (!order) { finish(nil, @"历史订单字段未通过校验。"); return; }
                                [result addObject:order];
                            }
                            finish(result, nil);
                        }
                    }]; return;
            }
            finish(nil, @"当前整合测试不支持此操作。");
        } @catch (NSException *exception) { finish(nil, @"洗衣客户端处理失败，请重试。"); }
    });
}
@end
