import HerdrKit
import SwiftUI

@main
struct HerdrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var app: AppModel { delegate.app }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.store)
                .onOpenURL { app.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            // No background networking yet: drop the socket when backgrounded and
            // reconnect (with a fresh snapshot) when the app comes back.
            switch phase {
            case .active:
                app.resume()
                Task {
                    await app.push.refresh()
                    await app.refreshWidgetToken()
                }
            case .background: app.store.stop()
            default: break
            }
        }
    }
}
