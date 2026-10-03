#import "CampusTimetableClient.h"
#include <dispatch/dispatch.h>

// 测试只替换固定 SDK/网络边界，不加载厂商组件、不发送请求。
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
    CampusOriginalPurpose purpose, NSDictionary *selection, NSString *code) { return nil; }
void CampusOriginalAccountSend(NSURLRequest *request, CampusOriginalPurpose purpose,
    void (^completion)(NSDictionary *, NSDictionary *)) { NSCAssert(NO, @"初始化测试不应发账号请求"); }
NSURL *CampusOriginalAuthorizationURL(NSString *key) { return nil; }
NSString *CampusOriginalMachineNumber(NSString *number) { return number; }
NSDictionary *CampusTimetableDevice(NSDictionary *payload, NSString *number) { return nil; }
NSDictionary *CampusTimetableOrder(NSDictionary *row, NSDictionary *detail) { return nil; }

static NSDictionary *Call(CampusTimetableClient *client, NSString *action) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *response;
    [client perform:action payload:@"{}" completion:^(NSString *result, NSString *error) {
        response = @{@"result": result ?: NSNull.null, @"error": error ?: NSNull.null};
        dispatch_semaphore_signal(done);
    }];
    NSCAssert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
        @"原生初始化回调超时");
    return response;
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
            NSCAssert([Call(client, @"hasSession")[@"result"] containsString:@"false"], @"初始化冒充已登录");
        }
        probeReady = NO; probeRows = @[];
        NSCAssert([Call([CampusTimetableClient new], @"initialize")[@"error"] containsString:@"没有返回可用阶段记录"],
            @"空报告缺少回退提示");
        puts("原生客户端初始化阶段、失败重试与就绪缓存测试通过；未执行厂商组件。");
    }
    return 0;
}
