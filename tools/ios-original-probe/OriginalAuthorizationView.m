#ifndef CAMPUS_ORIGINAL_PROBE_TEST
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "OriginalNetworkProbe.h"

@interface CampusOriginalAuthorizationController : UIViewController <WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, copy) NSString *appKey;
@property(nonatomic, copy) void (^completion)(NSString *, NSString *);
@property(nonatomic) BOOL finished;
@end

@implementation CampusOriginalAuthorizationController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.web.navigationDelegate = self; self.web.UIDelegate = self;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"取消本人登录" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    self.status = [[UILabel alloc] init]; self.status.numberOfLines = 0;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.status.text = @"请在官方页面手动完成本人验证码登录。诊断不读取输入值；取得一次性授权结果后，只交换校园会话并查询本人资料、运行/历史订单及详情、关联楼栋及设备状态和程序。";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[close, self.status, self.web]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12]]];
    NSURL *url = CampusOriginalAuthorizationURL(self.appKey);
    if (url) [self.web loadRequest:[NSURLRequest requestWithURL:url]];
    else [self finish:nil error:@"授权入口未通过；未加载网页"];
    self.appKey = nil;
}
- (void)cancel { [self finish:nil error:@"用户取消；未交换校园会话"]; }
- (void)finish:(NSString *)code error:(NSString *)error {
    if (self.finished) return;
    self.finished = YES; [self.web stopLoading]; self.web.navigationDelegate = nil; self.web.UIDelegate = nil;
    void (^callback)(NSString *, NSString *) = self.completion; self.completion = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (callback) callback(code, error); }];
}
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    if (self.finished) { decisionHandler(WKNavigationActionPolicyCancel); return; }
    NSString *code = CampusOriginalAuthorizationCode(url, action.targetFrame.isMainFrame);
    NSURLComponents *c = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES] : nil;
    BOOL callback = [c.host.lowercaseString isEqual:@"www.alipay.com"] && [c.percentEncodedPath isEqual:@"/webviewbridge"];
    if (code) { decisionHandler(WKNavigationActionPolicyCancel); [self finish:code error:nil]; return; }
    if (callback) { decisionHandler(WKNavigationActionPolicyCancel); self.status.text = @"授权回调缺失、重复或不是主页面；未交换会话。请彻底关闭应用后重新开始。"; return; }
    BOOL allowed = CampusOriginalAuthorizationNavigation(url);
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    if (!allowed && action.targetFrame.isMainFrame) self.status.text = @"外部跳转已阻止，请在官方网页使用本人手机号验证码登录。";
}
- (WKWebView *)webView:(WKWebView *)web createWebViewWithConfiguration:(WKWebViewConfiguration *)config
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame && CampusOriginalAuthorizationNavigation(action.request.URL)) [web loadRequest:action.request];
    return nil;
}
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) self.status.text = @"授权页面加载失败。请取消后检查网络；报告不展示网页地址或错误正文。";
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web { self.status.text = @"网页进程已结束，请彻底关闭应用后重新开始。"; }
- (void)webView:(WKWebView *)web didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) self.status.text = @"授权页面加载失败，请取消后检查网络。错误正文不展示。";
}
- (void)webView:(WKWebView *)web decidePolicyForNavigationResponse:(WKNavigationResponse *)response
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if (response.isForMainFrame && [response.response isKindOfClass:NSHTTPURLResponse.class] &&
        ((NSHTTPURLResponse *)response.response).statusCode >= 400) {
        self.status.text = @"授权服务返回错误，请取消后检查网络；未交换校园会话。";
        decisionHandler(WKNavigationResponsePolicyCancel);
    } else decisionHandler(WKNavigationResponsePolicyAllow);
}
@end

void CampusOriginalPresentAuthorization(UIViewController *parent, NSString *appKey, void (^completion)(NSString *, NSString *)) {
    CampusOriginalAuthorizationController *controller = [[CampusOriginalAuthorizationController alloc] init];
    controller.appKey = appKey; controller.completion = completion; controller.modalPresentationStyle = UIModalPresentationFullScreen;
    [parent presentViewController:controller animated:YES completion:nil];
}
#endif
