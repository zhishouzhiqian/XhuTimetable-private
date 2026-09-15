import Foundation
import OSLog
import WidgetKit
import ComposeApp

/// 主应用负责写快照，扩展只读；原子替换避免扩展读到半个 JSON。
enum WidgetSync {
    private static let logger = Logger(subsystem: "vip.mystery0.xhu.timetable", category: "WidgetSync")

    static func start() {
#if PERSONAL_TEST_BUILD
        return
#else
        IosWidgetBridge.shared.start { json in
            do {
                let data = Data(json.utf8)
                _ = try WidgetSnapshot.decode(data)
                guard let directory = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup
                ) else {
                    logger.error("Widget shared container is unavailable")
                    return
                }
                let file = directory.appendingPathComponent(WidgetSnapshot.fileName)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                WidgetCenter.shared.reloadAllTimelines()
            } catch {
                logger.error("Failed to publish widget snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
#endif
    }

    // 不在进入后台时注销：IO 线程中的登出可能稍后完成，仍需失效旧快照。
    // 监听不轮询、不请求网络；应用挂起由系统处理。
}
