#import "CampusTimetableClient.h"
#import "CampusTimetablePayment.h"
#include <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>

// 测试只替换固定 SDK/网络边界，不加载厂商组件、不发送请求。
NSDictionary *CampusPaymentLoad(void) { return @{}; }
void CampusPaymentSave(NSDictionary *intent) { NSCAssert(NO, @"生命周期测试不应写付款意图"); }
void CampusPaymentClear(void) { NSCAssert(NO, @"生命周期测试不应清付款意图"); }
void CampusPaymentDismiss(NSDictionary *intent) { NSCAssert(NO, @"生命周期测试不应退出付款意图"); }
static NSDictionary *savedSession;
static BOOL storageFails, sessionExpires;
static NSUInteger profileCalls;
NSDictionary *CampusSessionLoad(NSDictionary *context) { return savedSession; }
void CampusSessionSave(NSDictionary *session, NSDictionary *context) {
    if (storageFails) @throw [NSException exceptionWithName:@"SESSION_STORAGE_FAILED" reason:nil userInfo:nil];
    savedSession = [session copy];
}
void CampusSessionClear(void) { savedSession = nil; }
static NSArray *probeRows;
static BOOL probeReady;
static NSUInteger probeCalls;
void CampusOriginalProbeNetworkRun(NSDictionary *manifest, NSString *root,
    void (^progress)(NSArray *), void (^ready)(NSDictionary *), void (^completion)(NSArray *)) {
    probeCalls++;
    if (probeReady) ready(@{@"x-appkey": @"test"});
    completion(probeRows);
}
NSURLRequest *CampusTimetableAccountRequest(NSDictionary *context, NSDictionary *session,
    CampusOriginalPurpose purpose, NSDictionary *selection, NSString *code) {
    return purpose == CampusOriginalPurposeLogin || purpose == CampusOriginalPurposeProfile ? [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://example.invalid/"]] : nil;
}
void CampusOriginalAccountSend(NSURLRequest *request, CampusOriginalPurpose purpose,
    void (^completion)(NSDictionary *, NSDictionary *)) {
    if (purpose == CampusOriginalPurposeProfile) {
        profileCalls++;
        completion(sessionExpires ? @{@"requiresLogin": @YES} : @{@"success": @YES}, sessionExpires ? nil : @{@"verified": @YES});
        return;
    }
    NSCAssert(purpose == CampusOriginalPurposeLogin, @"测试仅允许桩登录与验证");
    completion(@{@"success": @YES}, @{@"sid": @"test-session", @"uid": @"test-user"});
}
NSURL *CampusOriginalAuthorizationURL(NSString *key) { return nil; }
NSString *CampusOriginalMachineNumber(NSString *number) { return number; }
NSDictionary *CampusTimetableDevice(NSDictionary *payload, NSString *number) { return nil; }
NSDictionary *CampusTimetableOrder(NSDictionary *row, NSDictionary *detail) { return nil; }

static NSDictionary *Call(CampusTimetableClient *client, NSString *action) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *response;
    [client perform:action payload:[action isEqual:@"exchange"] ? @"{\"code\":\"test-code\"}" : @"{}" completion:^(NSString *result, NSString *error) {
        response = @{@"result": result ?: NSNull.null, @"error": error ?: NSNull.null};
        dispatch_semaphore_signal(done);
    }];
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
        @"原生初始化回调超时");
    return response;
}

static void AssertSession(CampusTimetableClient *client, BOOL expected) {
    NSDictionary *response = Call(client, @"hasSession");
    NSCAssert(response[@"error"] == NSNull.null, @"会话查询失败");
    NSData *bytes = [response[@"result"] dataUsingEncoding:NSUTF8StringEncoding];
    id decoded = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    id present = [decoded isKindOfClass:NSDictionary.class] ? decoded[@"present"] : nil;
    // NSNumber 的 boolValue 会把数字 0/1 也当作布尔，必须检查 JSON 回读的真实类型。
    NSCAssert(present && CFGetTypeID((__bridge CFTypeRef)present) == CFBooleanGetTypeID(), @"会话字段不是 JSON 布尔");
    NSCAssert([present boolValue] == expected, @"会话状态与初始化/登录/退出不符");
}

int main(void) {
    @autoreleasepool {
        for (NSString *step in @[@"yw_1222.jpg", @"内部管理器", @"统一签名初始化", @"设备上下文",
            @"本次请求一致性", @"匿名配置响应", @"设备注册响应", @"带设备 ID 配置响应"]) {
            CampusTimetableClient *client = [CampusTimetableClient new];
            probeReady = NO;
            probeRows = @[@{@"step": step, @"result": @"未通过"},
                @{@"step": @"未知字段", @"result": @"private-token"}];
            NSDictionary *failed = Call(client, @"initialize");
            NSCAssert([failed[@"error"] hasPrefix:@"CAMPUS_INIT_FAILED\n"] &&
                [failed[@"error"] containsString:step] && ![failed[@"error"] containsString:@"private-token"],
                @"失败阶段丢失或带出未知字段");
            NSCAssert(failed[@"result"] == NSNull.null, @"初始化失败被误判成功");
            // 同一实例失败后仍可重试；成功后不再次注册设备。
            probeReady = YES;
            NSCAssert(Call(client, @"initialize")[@"error"] == NSNull.null, @"失败重试未恢复");
            NSUInteger calls = probeCalls;
            NSCAssert(Call(client, @"initialize")[@"error"] == NSNull.null && calls == probeCalls,
                @"已就绪客户端重复注册");
            AssertSession(client, NO);
            NSCAssert(Call(client, @"exchange")[@"error"] == NSNull.null, @"桩会话交换失败");
            AssertSession(client, YES);
            NSCAssert(Call(client, @"logout")[@"error"] == NSNull.null, @"退出会话失败");
            AssertSession(client, NO);
        }
        probeReady = NO; probeRows = @[];
        NSCAssert([Call([CampusTimetableClient new], @"initialize")[@"error"] containsString:@"没有返回可用阶段记录"],
            @"空报告缺少回退提示");
        probeReady = YES;
        CampusTimetableClient *first = [CampusTimetableClient new];
        NSCAssert(Call(first, @"initialize")[@"error"] == NSNull.null && Call(first, @"exchange")[@"error"] == NSNull.null, @"持久化测试登录失败");
        NSCAssert(savedSession != nil, @"登录会话没有保存");
        CampusTimetableClient *restarted = [CampusTimetableClient new];
        NSCAssert(Call(restarted, @"initialize")[@"error"] == NSNull.null, @"重启初始化失败");
        AssertSession(restarted, YES);
        NSCAssert([Call(restarted, @"pendingPayment")[@"error"] isEqual:@"SESSION_VERIFICATION_REQUIRED"], @"恢复会话未验证就使用付款入口");
        NSUInteger before = profileCalls;
        NSCAssert(Call(restarted, @"verify")[@"error"] == NSNull.null && profileCalls == before + 1, @"恢复会话没有服务端验证");
        NSCAssert(Call(restarted, @"pendingPayment")[@"error"] == NSNull.null, @"验证后不能查询待付款记录");
        sessionExpires = YES;
        NSCAssert([Call(restarted, @"verify")[@"error"] isEqual:@"SESSION_EXPIRED"] && savedSession == nil, @"失效会话没有清除持久化记录");
        AssertSession(restarted, NO);
        sessionExpires = NO; storageFails = YES;
        NSCAssert([Call(restarted, @"exchange")[@"error"] isEqual:@"SESSION_STORAGE_FAILED"], @"会话保存失败被当作成功");
        AssertSession(restarted, NO);
        storageFails = NO;
        NSCAssert(Call(restarted, @"exchange")[@"error"] == NSNull.null, @"存储恢复后不能重新登录");
        NSCAssert(Call(restarted, @"logout")[@"error"] == NSNull.null && savedSession == nil, @"退出没有删除持久化会话");
        puts("原生客户端初始化、重试、会话重启恢复、服务端验证与失效清理测试通过；未执行厂商组件或真实 Keychain。");
    }
    return 0;
}
