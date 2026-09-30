import UIKit
import WebKit
import ComposeApp

/// 授权页使用独立临时 Cookie 容器，不读取课表或用水的网页会话。
final class LaundryAuthorizationViewController: UIViewController, WKNavigationDelegate {
    private let entryUrl: String
    private let result: (String?, String?) -> Void
    private var web: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .default)
    private let errorLabel = UILabel()
    private var completed = false
    private var watchdog: DispatchWorkItem?
    private var observation: NSKeyValueObservation?

    init(entryUrl: String, result: @escaping (String?, String?) -> Void) {
        self.entryUrl = entryUrl
        self.result = result
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("请使用洗衣登录入口创建页面") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self

        let close = UIButton(type: .system)
        close.setTitle("取消", for: .normal)
        close.addTarget(self, action: #selector(cancelLogin), for: .touchUpInside)
        let retry = UIButton(type: .system)
        retry.setTitle("重新加载", for: .normal)
        retry.addTarget(self, action: #selector(loadEntry), for: .touchUpInside)
        let title = UILabel()
        title.text = "校园洗衣登录"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        let toolbar = UIStackView(arrangedSubviews: [close, title, retry])
        toolbar.axis = .horizontal
        toolbar.distribution = .equalSpacing
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        let column = UIStackView(arrangedSubviews: [toolbar, progress, errorLabel, web])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        observation = web.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            self?.progress.progress = Float(web.estimatedProgress)
            self?.progress.isHidden = web.estimatedProgress >= 1
        }
        loadEntry()
    }

    @objc private func loadEntry() {
        guard !completed, LaundryAuthorizationPolicy.shared.navigation(value: entryUrl, mainFrame: true).allowed,
              let url = URL(string: entryUrl) else {
            finish(error: "登录地址无效，请重新打开洗衣服务。")
            return
        }
        errorLabel.isHidden = true
        web.load(URLRequest(url: url, timeoutInterval: 30))
    }

    @objc private func cancelLogin() { finish() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !completed, let url = action.request.url else { decisionHandler(.cancel); return }
        let policy = LaundryAuthorizationPolicy.shared.navigation(value: url.absoluteString,
            mainFrame: action.targetFrame?.isMainFrame == true)
        decisionHandler(policy.allowed ? .allow : .cancel)
        if let code = policy.code { finish(code: code) }
        else if let error = policy.error { showError(error) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        watchdog?.cancel()
        let check = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView, !self.completed else { return }
            // 仅检查有无交互控件，不读取输入值或网页正文。
            webView.evaluateJavaScript("Array.from(document.querySelectorAll('input:not([type=hidden]),button,a[href],[role=button]')).some(e=>e.getClientRects().length>0)") { [weak self] interactive, _ in
                if (interactive as? Bool) != true {
                    self?.showError("登录页面未完成加载，请检查网络后重新加载。")
                }
            }
        }
        watchdog = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: check)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError("登录页面加载失败，请检查网络后重试。") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { showError("登录页面加载失败，请重新加载。") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel)
            showError("登录服务暂时不可用，请稍后重试。")
        } else { decisionHandler(.allow) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showError("登录页面已停止响应，请重新加载。")
    }

    private func showError(_ message: String) {
        guard !completed else { return }
        watchdog?.cancel()
        web.stopLoading()
        progress.isHidden = true
        errorLabel.text = message
        errorLabel.isHidden = false
    }

    private func finish(code: String? = nil, error: String? = nil) {
        guard !completed else { return }
        completed = true
        watchdog?.cancel()
        web?.stopLoading()
        web?.navigationDelegate = nil
        result(code, error)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { finish() }
    }

    deinit { watchdog?.cancel(); observation?.invalidate() }
}
