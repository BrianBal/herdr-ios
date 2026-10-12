import Foundation
import HerdrKit
import Observation
import UserNotifications
import WidgetKit

/// App-wide state: the paired gateway (shared with the widget, see
/// SharedEndpoint) and the live HerdrStore for it.
@MainActor @Observable
final class AppModel {
    private(set) var endpoint: GatewayEndpoint?
    let store = HerdrStore()
    let push = PushManager()
    let liveActivity = LiveActivityManager()
    let quickPrompts = QuickPrompts()
    var pairingError: String?
    /// Pane requested via `herdr-ios://open?pane=<id>`; RootView navigates and clears it.
    var pendingPaneId: String?

    init() {
        SharedEndpoint.migrateFromAppOnlyStorage()
        endpoint = SharedEndpoint.load()
        store.registrationExtras = { [unowned self] in
            var extras: [String: JSONValue] = ["live_activity": .bool(liveActivity.enabled)]
            if let t = AppGroup.defaults.string(forKey: Self.widgetTokenKey) { extras["widget_token"] = .string(t) }
            if let t = liveActivity.startToken { extras["activity_start_token"] = .string(t) }
            return extras
        }
        store.onBoard = { [unowned self] board in Task { await liveActivity.sync(board) } }
        liveActivity.onRegistrationChange = { [unowned self] in store.pushRegistrationChanged() }
        liveActivity.onActivityToken = { [unowned self] token in Task { await reportActivity(token: token) } }
    }

    /// Written by the widget's push handler (AgentsPushHandler.tokenKey).
    private static let widgetTokenKey = "widget.pushToken"

    /// Picks up the widget's push token; the app is the one that talks to the gateway.
    func refreshWidgetToken() async {
        guard #available(iOS 26.0, *), let token = await Self.widgetPushToken(),
              token != AppGroup.defaults.string(forKey: Self.widgetTokenKey) else { return }
        AppGroup.defaults.set(token, forKey: Self.widgetTokenKey)
        store.pushRegistrationChanged()
    }

    @available(iOS 26.0, *)
    private nonisolated static func widgetPushToken() async -> String? {
        await WidgetCenter.shared.currentPushInfo?.token.hex
    }

    /// Tells the gateway which Live Activity to update (or that it ended). iOS
    /// may have just woken the app in the background for this, so it uses a
    /// connection of its own when the store isn't connected.
    private func reportActivity(token: String?) async {
        // The APNs token identifies this device to the gateway; it arrives shortly after launch.
        for _ in 0..<20 where push.deviceToken == nil { try? await Task.sleep(for: .milliseconds(250)) }
        guard let device = push.deviceToken, let endpoint else { return }
        let method = token == nil ? "gw.activity_ended" : "gw.activity_register"
        var params: [String: JSONValue] = ["token": .string(device)]
        if let token { params["activity_token"] = .string(token) }
        if let client = store.client, store.isConnected {
            try? await client.send(method, params: .object(params))
            return
        }
        let client = GatewayClient(url: endpoint.url, token: endpoint.token)
        if (try? await client.connect()) != nil {
            try? await client.send(method, params: .object(params))
        }
        await client.disconnect()
    }

    #if DEBUG
    /// Simulator automation: `SIMCTL_CHILD_HERDR_PAIR_LINK` / `SIMCTL_CHILD_HERDR_OPEN_PANE`
    /// bypass the system "Open in Herdr?" prompt that custom-scheme links trigger.
    func applyDebugLaunchEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let link = env["HERDR_PAIR_LINK"], let url = URL(string: link) { handle(url: url) }
        if let pane = env["HERDR_OPEN_PANE"] { pendingPaneId = pane }
    }
    #endif

    func resume() {
        guard let endpoint else { return }
        if store.phase == .idle || store.endpoint != endpoint { store.start(endpoint) }
    }

    /// Verifies the endpoint by connecting before saving it.
    func pair(_ e: GatewayEndpoint) async throws {
        let probe = GatewayClient(url: e.url, token: e.token)
        _ = try await probe.connect()
        await probe.disconnect()
        try SharedEndpoint.save(e)
        endpoint = e
        pairingError = nil
        store.start(e)
    }

    func unpair() {
        store.stop()
        store.reset()
        SharedEndpoint.clear()
        endpoint = nil
    }

    /// A tapped notification opens its pane; its buttons answer the agent
    /// without opening the app, over a short-lived connection of their own.
    func handleNotification(action: String, paneId: String?, text: String?) async {
        guard let paneId else { return }
        if action == UNNotificationDefaultActionIdentifier {
            pendingPaneId = paneId
            return
        }
        guard let endpoint else { return }
        let method: String
        let params: JSONValue
        if action == PushManager.replyAction, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            method = "agent.prompt"
            params = ["target": .string(paneId), "text": .string(text)]
        } else if action.hasPrefix("key:") {
            method = "pane.send_keys"
            params = ["pane_id": .string(paneId), "keys": [.string(String(action.dropFirst(4)))]]
        } else {
            return
        }
        let client = GatewayClient(url: endpoint.url, token: endpoint.token)
        do {
            _ = try await client.connect()
            try await client.send(method, params: params)
        } catch {
            // The app may be in the background; there's no one to show an alert to.
            print("notification action \(action) failed: \(error)")
        }
        await client.disconnect()
    }

    func handle(url: URL) {
        guard url.scheme == GatewayEndpoint.scheme else { return }
        if url.host == "open" {
            pendingPaneId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pane" })?.value
            return
        }
        do {
            let e = try GatewayEndpoint(pairingLink: url.absoluteString)
            Task {
                do { try await pair(e) } catch { pairingError = error.localizedDescription }
            }
        } catch {
            pairingError = error.localizedDescription
        }
    }
}
