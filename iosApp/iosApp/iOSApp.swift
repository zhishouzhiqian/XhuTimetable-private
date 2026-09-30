import SwiftUI
import ComposeApp

@main
struct iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HelperKt.callAppInit()
        LaundryNativeUi.install()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { WidgetSync.start() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        WidgetSync.start()
                    }
                }
        }
    }
}
