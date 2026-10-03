#import "OriginalNetworkProbe.h"
#import "../../iosApp/iosApp/CampusMtopProbeInput.h"
#include <math.h>

NSString *const CampusOriginalConfigAPI = @"mtop.tmall.campus.guide.advertising.config.list";
static const NSUInteger ProbeResponseLimit = 1024 * 1024;

static BOOL ProbeText(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static NSString *ProbeEncode(NSString *value, NSString *(^encode)(NSString *), NSString *__autoreleasing *reason) {
    id encoded = encode(value);
    if (!ProbeText(encoded, 65536)) {
        if (reason) *reason = @"编码入口返回空值、类型不符或超限";
        return nil;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%"];
    if ([encoded rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        if (reason) *reason = @"编码结果包含未转义的保留字符";
        return nil;
    }
    if (![[encoded stringByRemovingPercentEncoding] isEqualToString:value]) {
        if (reason) *reason = @"编码回读与原值不同（含非法转义或重复编码）";
        return nil;
    }
    return encoded;
}

NSURLRequest *CampusOriginalConfigRequest(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSDictionary *factors, NSString *(^encode)(NSString *)) {
    return CampusOriginalConfigRequestChecked(appKey, utdid, ttid, time, factors, encode, NULL);
}

static NSURLRequest *ProbeReject(NSString *__autoreleasing *reason, NSString *message) {
    if (reason) *reason = message;
    return nil;
}

NSURLRequest *CampusOriginalConfigRequestChecked(NSString *appKey, NSString *utdid, NSString *ttid,
    NSString *time, NSDictionary *factors, NSString *(^encode)(NSString *), NSString *__autoreleasing *reason) {
    if (reason) *reason = nil;
    if (!encode) return ProbeReject(reason, @"ENCODER_MISSING：编码入口缺失");
    if (!ProbeText(appKey, 128)) return ProbeReject(reason, @"APPKEY_FORMAT：AppKey 类型、长度或控制字符不符");
    if (!ProbeText(utdid, 24) || utdid.length != 24 ||
        [[NSData alloc] initWithBase64EncodedString:utdid options:0].length != 18)
        return ProbeReject(reason, @"UTDID_FORMAT：设备标识不符合 24 字符及 18 字节 Base64 契约");
    if (!ProbeText(ttid, 256)) return ProbeReject(reason, @"TTID_FORMAT：应用标识类型、长度或控制字符不符");
    if (!ProbeText(time, 10) || time.length != 10 ||
        [time rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound)
        return ProbeReject(reason, @"TIME_FORMAT：时间不是十位秒值");
    if (!CampusMtopProbeFactorsComplete(factors, nil)) return ProbeReject(reason, @"FACTORS_INCOMPLETE：安全字段不完整");
    // 核对转义及解码语义，不要求合法的 %7E 和 ~ 等表示与合成编码器逐字相同。
    // 保留字符必须转义，回读必须完全一致；仍拒绝漏编码和重复编码。
    NSString *encodingReason = nil;
    if (!ProbeEncode(@"a+b/= %~*", encode, &encodingReason))
        return ProbeReject(reason, [@"ENCODER_VECTOR：" stringByAppendingString:encodingReason]);
    NSMutableDictionary *raw = [@{@"x-appkey": appKey, @"x-utdid": utdid,
        @"x-ttid": ttid, @"x-t": time, @"x-pv": @"6.3"} mutableCopy];
    for (NSString *key in @[@"x-sign", @"x-mini-wua", @"x-umt", @"x-sgext"]) {
        if (!ProbeText(factors[key], 16384)) return ProbeReject(reason,
            [NSString stringWithFormat:@"FACTOR_FORMAT（%@）：类型、长度或控制字符不符", key]);
        raw[key] = factors[key];
    }
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *key in raw) {
        NSString *value = ProbeEncode(raw[key], encode, &encodingReason);
        if (!value) return ProbeReject(reason, [NSString stringWithFormat:@"HEADER_ENCODING（%@）：%@", key, encodingReason]);
        headers[key] = value;
    }
    NSString *body = ProbeEncode(@"{}", encode, &encodingReason);
    if (!body) return ProbeReject(reason, [@"BODY_ENCODING：" stringByAppendingString:encodingReason]);
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"acs.m.taobao.com";
    components.percentEncodedPath = [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalConfigAPI];
    components.percentEncodedQuery = [@"data=" stringByAppendingString:body];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    request.allHTTPHeaderFields = headers;
    if (!CampusOriginalConfigRequestInScope(request)) return ProbeReject(reason, @"WIRE_SCOPE：线路路径、空正文或头集合不符合范围");
    return [request copy];
}

NSDictionary *CampusOriginalConfigOutcome(NSInteger status, NSData *body, NSInteger networkError,
    BOOL redirected, BOOL oversized) {
    NSString *summary = nil;
    BOOL success = NO;
    if (redirected) summary = @"收到跳转；已拒绝跟随；本次未通过";
    else if (oversized || body.length > ProbeResponseLimit) summary = @"响应超过 1 MiB；已停止读取；本次未通过";
    else if (networkError) summary = [NSString stringWithFormat:@"网络失败（错误码 %ld）；无应用层自动重试", (long)networkError];
    else {
        id json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
        id ret = [json isKindOfClass:NSDictionary.class] ? json[@"ret"] : nil;
        NSSet *known = [NSSet setWithArray:@[@"SUCCESS", @"FAIL_SYS_ILEGEL_SIGN", @"FAIL_SYS_PROTOVER_MISSED",
            @"FAIL_SYS_SESSION_EXPIRED", @"FAIL_SYS_TOKEN_EMPTY", @"FAIL_SYS_TOKEN_EXOIRED", @"FAIL_SYS_ILLEGAL_ACCESS",
            @"FAIL_SYS_USER_VALIDATE", @"FAIL_SYS_TRAFFIC_LIMIT", @"FAIL_SYS_API_NOT_FOUND"]];
        NSMutableArray *codes = [NSMutableArray array];
        BOOL allSuccess = [ret isKindOfClass:NSArray.class] && [ret count] > 0 && [ret count] <= 16;
        if ([ret isKindOfClass:NSArray.class] && [ret count] <= 16) {
            for (id item in ret) {
                NSString *code = ProbeText(item, 4096) ? [[item componentsSeparatedByString:@"::"] firstObject] : nil;
                NSString *safe = code && [known containsObject:code] ? code : @"UNKNOWN_CODE";
                [codes addObject:safe];
                allSuccess = allSuccess && [safe isEqualToString:@"SUCCESS"];
            }
        }
        success = status == 200 && allSuccess;
        summary = [NSString stringWithFormat:@"HTTP %ld；业务码 %@（响应正文与数据不展示）", (long)status,
            codes.count ? [codes componentsJoinedByString:@", "] : @"无法解析"];
    }
    return @{@"success": @(success), @"summary": summary};
}

@interface CampusOriginalConfigTransport : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic) NSInteger status;
@property(nonatomic) BOOL redirected;
@property(nonatomic) BOOL oversized;
@property(nonatomic, copy) void (^completion)(NSDictionary *);
@end

@implementation CampusOriginalConfigTransport
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    self.redirected = YES;
    self.status = response.statusCode;
    completionHandler(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // TLS 保持系统证书校验；任何账号/客户端证书挑战均不提供凭据。
    completionHandler([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] ?
        NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    self.oversized = response.expectedContentLength > (long long)ProbeResponseLimit;
    completionHandler(self.oversized ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.body.length + data.length > ProbeResponseLimit) {
        self.oversized = YES;
        [task cancel];
        return;
    }
    [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSDictionary *result = CampusOriginalConfigOutcome(self.status, self.body, error.code, self.redirected, self.oversized);
    [self.body setLength:0];
    void (^completion)(NSDictionary *) = self.completion;
    self.completion = nil;
    [session finishTasksAndInvalidate];
    if (completion) completion(result);
}
@end

BOOL CampusOriginalConfigRequestInScope(NSURLRequest *request) {
    // 固定目的地与方法；拒绝外部请求、Cookie 或正文。构造与发送均受此白名单约束。
    NSSet *expected = [NSSet setWithArray:@[@"x-appkey", @"x-utdid", @"x-ttid", @"x-t", @"x-pv",
        @"x-sign", @"x-mini-wua", @"x-umt", @"x-sgext"]];
    NSMutableSet *actual = [NSMutableSet set];
    for (NSString *key in request.allHTTPHeaderFields) [actual addObject:key.lowercaseString];
    NSString *path = [NSString stringWithFormat:@"/gw/%@/1.0/", CampusOriginalConfigAPI];
    NSURLComponents *components = request.URL ? [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:YES] : nil;
    // NSURL.path 会去掉末尾斜杠并解码，不能用于检查实际发送的路径。
    // 同时检查编码后的路径和查询，保持末尾斜杠并阻断多编码、额外参数。
    return [components.scheme isEqualToString:@"https"] && [components.host isEqualToString:@"acs.m.taobao.com"] &&
        !components.port && !components.user && !components.password && !components.fragment &&
        [components.percentEncodedPath isEqualToString:path] && [components.percentEncodedQuery isEqualToString:@"data=%7B%7D"] &&
        [request.HTTPMethod isEqualToString:@"GET"] && !request.HTTPBody && !request.HTTPBodyStream &&
        !request.HTTPShouldHandleCookies && [actual isEqualToSet:expected];
}

void CampusOriginalConfigSend(NSURLRequest *request, void (^completion)(NSDictionary *)) {
    if (!CampusOriginalConfigRequestInScope(request)) {
        completion(@{@"success": @NO, @"summary": @"发送前范围核对失败；未发送"}); return;
    }
    NSString *time = [request valueForHTTPHeaderField:@"x-t"];
    if (time.length != 10 ||
        [time rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound ||
        fabs(NSDate.date.timeIntervalSince1970 - time.doubleValue) > 120) {
        completion(@{@"success": @NO, @"summary": @"请求时间过期或无效；未发送"}); return;
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPShouldSetCookies = NO;
    config.HTTPCookieStorage = nil;
    config.URLCredentialStorage = nil;
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 20;
    config.waitsForConnectivity = NO;
    // 禁用进程中第三方注册的自定义协议处理器，保持专用 HTTPS 请求。
    config.protocolClasses = @[];
    CampusOriginalConfigTransport *delegate = [[CampusOriginalConfigTransport alloc] init];
    delegate.body = [NSMutableData data];
    delegate.completion = completion;
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:queue];
    [[session dataTaskWithRequest:request] resume];
}
