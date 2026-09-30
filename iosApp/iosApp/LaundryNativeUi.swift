import UIKit
import ComposeApp

/// 只展示原生页面。会话转换与付款判定由共享业务层和校园客户端完成。
final class LaundryNativeUi: NSObject, IosLaundryNativeUi {
    private var requestId: Int64?
    private weak var page: UIViewController?
    private var observers: [NSObjectProtocol] = []
    private var returnTimeout: DispatchWorkItem?
    private var wechatAccepted = false
    private var wechatBackgrounded = false
    private var wechatReturned = false

    static func install() {
#if CAMPUS_COMPONENT_PROBE
        IosLaundryNativeBridge.shared.install(ui: LaundryNativeUi(), componentDiagnosticsEnabled: true)
#else
        IosLaundryNativeBridge.shared.install(ui: LaundryNativeUi(), componentDiagnosticsEnabled: false)
#endif
    }

    func componentCheck(requestId: Int64) {
        guard begin(requestId) else { return }
        let controller = LaundryComponentCheckViewController { [weak self] in self?.finish(requestId) }
        present(controller, requestId)
    }

    func authorize(url: String, requestId: Int64) {
        guard begin(requestId) else { return }
        let controller = LaundryAuthorizationViewController(entryUrl: url) { [weak self] code, error in
            self?.finish(requestId, contents: code, error: error)
        }
        present(controller, requestId)
    }

    func scan(requestId: Int64) {
        guard begin(requestId) else { return }
        let controller = LaundryQrScannerViewController { [weak self] contents, error in
            self?.finish(requestId, contents: contents, error: error)
        }
        present(controller, requestId)
    }

    func openWechat(uri: String, requestId: Int64) {
        guard begin(requestId) else { return }
        guard LaundryAuthorizationPolicy.shared.acceptsWechat(value: uri), let url = URL(string: uri) else {
            finish(requestId, error: "付款链接无效，订单已保留。")
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard self?.requestId == requestId else { return }
            self?.wechatBackgrounded = true
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self, self.requestId == requestId, self.wechatBackgrounded else { return }
            self.wechatReturned = true
            if self.wechatAccepted { self.finish(requestId) }
        })
        UIApplication.shared.open(url, options: [:]) { [weak self] accepted in
            DispatchQueue.main.async {
                guard let self, self.requestId == requestId else { return }
                guard accepted else {
                    self.finish(requestId, error: "无法打开微信，请确认已安装微信。订单已保留。")
                    return
                }
                self.wechatAccepted = true
                if self.wechatReturned { self.finish(requestId); return }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.requestId == requestId, !self.wechatBackgrounded,
                          UIApplication.shared.applicationState == .active else { return }
                    self.finish(requestId, error: "微信没有完成跳转，请核验订单或继续付款。")
                }
                self.returnTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            }
        }
    }

    func cancel(requestId: Int64) {
        guard self.requestId == requestId else { return }
        let controller = page
        clear()
        controller?.dismiss(animated: true)
    }

    private func begin(_ id: Int64) -> Bool {
        guard requestId == nil else {
            IosLaundryNativeBridge.shared.complete(requestId: id, contents: nil, error: "请先关闭当前页面。")
            return false
        }
        requestId = id
        return true
    }

    private func present(_ controller: UIViewController, _ id: Int64) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            finish(id, error: "暂时无法打开页面，请重试。")
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        guard !top.isBeingDismissed, !top.isBeingPresented else {
            finish(id, error: "页面正在切换，请重试。")
            return
        }
        page = controller
        top.present(controller, animated: true)
    }

    private func finish(_ id: Int64, contents: String? = nil, error: String? = nil) {
        guard requestId == id else { return }
        let controller = page
        clear()
        let complete = { IosLaundryNativeBridge.shared.complete(requestId: id, contents: contents, error: error) }
        if controller?.presentingViewController != nil {
            controller?.dismiss(animated: true, completion: complete)
        } else { complete() }
    }

    private func clear() {
        requestId = nil
        page = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        returnTimeout?.cancel()
        returnTimeout = nil
        wechatAccepted = false
        wechatBackgrounded = false
        wechatReturned = false
    }
}
