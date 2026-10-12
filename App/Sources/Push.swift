import HerdrKit
import Observation
import UIKit
import UserNotifications

/// Push notifications: permission, the APNs device token (handed to the
/// gateway on every connect, see HerdrStore), and what tapping a notification
/// or one of its buttons does. The gateway on the Mac decides when to send.
@MainActor @Observable
final class PushManager {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    private(set) var registrationError: String?

    /// Matches the aps-environment entitlement the build was signed with.
    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    // Notification categories and buttons; the gateway sets the category.
    static let blockedCategory = "AGENT_BLOCKED"
    static let doneCategory = "AGENT_DONE"
    static let replyAction = "reply"
    /// Keys sent as-is to a blocked agent (numbered choices in Claude Code's prompts).
    static let keyActions = ["1", "2", "3"]

    private static let askedKey = "push.askedOnce"

    func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply",
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message the agent")
        let keys = Self.keyActions.map {
            UNNotificationAction(identifier: "key:\($0)", title: "Choose \($0)")
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.blockedCategory, actions: keys + [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.doneCategory, actions: [reply], intentIdentifiers: []),
        ])
    }

    /// Re-reads permission; when granted, (re-)registers with APNs since tokens can change.
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization == .authorized || authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Shows the system prompt (only does anything the first time).
    func requestAuthorization() async {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    /// Asks once, the first time the app is connected to a gateway.
    func requestAuthorizationIfFirstTime() async {
        guard !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        await requestAuthorization()
    }

    func didRegister(token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        registrationError = nil
    }

    func didFailToRegister(_ error: Error) {
        registrationError = error.localizedDescription
    }
}

/// UIKit entry points that SwiftUI doesn't cover: the APNs token callbacks and
/// the notification center delegate. Owns the AppModel so both sides share it.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let app: AppModel = {
        let app = AppModel()
        #if DEBUG
        app.applyDebugLaunchEnvironment()
        #endif
        return app
    }()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        app.push.registerCategories()
        app.liveActivity.observe()
        Task { await app.push.refresh() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        app.push.didRegister(token: deviceToken)
        app.store.registerPush(token: app.push.deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        app.push.didFailToRegister(error)
    }

    // The completion-handler forms, not the async ones: Swift calls an async
    // delegate's completion handler off the main thread, and UIKit aborts the
    // app when that happens for a notification response.

    // While the app is open the gateway doesn't push to it, but a test push still arrives.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async { done([.banner, .sound]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let paneId = info["pane_id"] as? String
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            await app.handleNotification(action: action, paneId: paneId, text: text)
            done()
        }
    }
}
