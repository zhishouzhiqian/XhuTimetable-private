import Foundation
import UIKit
import ComposeApp

/// 课表框架的实验宿主，保持原校园 SDK 与资源的运行环境。
@objc(XhuCampusTimetableHost)
final class XhuCampusTimetableHost: NSObject, IosCampusBackend {
    private let client = CampusTimetableClient()

    @objc static func makeViewController() -> UIViewController {
        HelperKt.callAppInit()
        LaundryNativeUi.install()
        IosCampusClientBridge.shared.install(backend: XhuCampusTimetableHost())
        return MainViewControllerKt.MainViewController()
    }

    func perform(action: String, payload: String, requestId: Int64) {
        client.perform(action, payload: payload) { result, error in
            DispatchQueue.main.async {
                IosCampusClientBridge.shared.complete(requestId: requestId, result: result, error: error)
            }
        }
    }
}

// 直接 C 引用让链接器保留真实启动路径；返回 +1 所有权，由 Objective-C 接管一次。
@_cdecl("CampusTimetableMakeViewController")
public func campusTimetableMakeViewController() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(XhuCampusTimetableHost.makeViewController()).toOpaque()
}
