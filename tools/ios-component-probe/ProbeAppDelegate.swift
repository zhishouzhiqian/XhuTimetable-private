import UIKit

/// 轻量检查宿主复用课表内相同的检查代码，不编译 Kotlin/Native。
@main
final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        CampusComponentProbeRequireEnabled()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = LaundryComponentCheckViewController(showsCloseButton: false) {}
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
