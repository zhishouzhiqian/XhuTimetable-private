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
