import Foundation
import HerdrKit
import Observation
import UIKit
import UserNotifications
import WidgetKit

/// App-wide state: the paired gateways (shared with the widget, see
/// SharedEndpoint) and the live HerdrStore for the one on screen.
///
/// One gateway is connected at a time. The others keep sending
/// notifications; only the active one drives the widget and Live Activity.
@MainActor @Observable
final class AppModel {
    private(set) var gateways: [SavedGateway] = []
    private(set) var activeId: String?
    private(set) var endpoint: GatewayEndpoint?
    let store = HerdrStore()
    let push = PushManager()
    let liveActivity = LiveActivityManager()
    let quickPrompts = QuickPrompts()
    var pairingError: String?
    /// Pane requested via `herdr-ios://open?pane=<id>`; RootView navigates and clears it.
    var pendingPaneId: String?

    init() {
        SharedEndpoint.migrate()
        reloadGateways()
        store.registrationExtras = { [unowned self] in
            var extras: [String: JSONValue] = ["live_activity": .bool(liveActivity.enabled)]
            if let activeId { extras["gateway_id"] = .string(activeId) }
            if let t = AppGroup.defaults.string(forKey: Self.widgetTokenKey) { extras["widget_token"] = .string(t) }
            if let t = liveActivity.startToken { extras["activity_start_token"] = .string(t) }
            return extras
        }
        store.onBoard = { [unowned self] board in Task { await liveActivity.sync(board) } }
        liveActivity.onRegistrationChange = { [unowned self] in store.pushRegistrationChanged() }
        liveActivity.onActivityToken = { [unowned self] token, ended in Task { await reportActivity(token: token, ended: ended) } }
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

    /// Tells the gateway which Live Activity to update (or that this one ended). iOS
    /// may have just woken the app in the background for this, so it uses a
    /// connection of its own when the store isn't connected.
    private func reportActivity(token: String, ended: Bool) async {
        // The APNs token identifies this device to the gateway; it arrives shortly after launch.
        for _ in 0..<20 where push.deviceToken == nil { try? await Task.sleep(for: .milliseconds(250)) }
        guard let device = push.deviceToken, let endpoint else { return }
        let method = ended ? "gw.activity_ended" : "gw.activity_register"
        let params: [String: JSONValue] = ["token": .string(device), "activity_token": .string(token)]
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
    /// bypass the system "Open in Herdr?" prompt that custom-scheme links trigger;
    /// `HERDR_RESET_GATEWAYS` forgets every gateway first.
    func applyDebugLaunchEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if env["HERDR_RESET_GATEWAYS"] != nil {
            for g in gateways { SharedEndpoint.remove(g.id) }
            reloadGateways()
        }
        if let link = env["HERDR_PAIR_LINK"], let url = URL(string: link) { handle(url: url) }
        if let pane = env["HERDR_OPEN_PANE"] { pendingPaneId = pane }
    }
    #endif

    func resume() {
        guard let endpoint else { return }
        if store.phase == .idle || store.endpoint != endpoint { store.start(endpoint) }
    }

    var activeGateway: SavedGateway? { gateways.first { $0.id == activeId } }

    func gateway(_ id: String) -> SavedGateway? { gateways.first { $0.id == id } }

    private func reloadGateways() {
        gateways = SharedEndpoint.gateways()
        if SharedEndpoint.activeId.flatMap(gateway) == nil { SharedEndpoint.activeId = gateways.first?.id }
        activeId = SharedEndpoint.activeId
        endpoint = SharedEndpoint.load()
    }

    /// Connects once to check the URL and token before anything is saved.
    private func probe(_ e: GatewayEndpoint) async throws {
        let probe = GatewayClient(url: e.url, token: e.token)
        defer { Task { await probe.disconnect() } }
        _ = try await probe.connect()
    }

    /// Pairs with a gateway and switches to it. Pairing again with one already
    /// saved (same URL) just updates its token.
    func pair(_ e: GatewayEndpoint, name: String? = nil) async throws {
        try await probe(e)
        let existing = gateways.first { $0.url == e.url }
        var g = existing ?? SavedGateway(id: UUID().uuidString, name: SavedGateway.defaultName(for: e.url), url: e.url)
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { g.name = name }
        try SharedEndpoint.save(g, token: e.token)
        reloadGateways()
        pairingError = nil
        if existing != nil, g.id == activeId { store.stop() }
        switchTo(g.id, force: true)
    }

    /// Saves edits to a gateway. A new URL or token is checked first; a blank token keeps the old one.
    func update(_ id: String, name: String, url: String, token: String) async throws {
        guard var g = gateway(id), let oldToken = SharedEndpoint.token(id) else { return }
        let e = try GatewayEndpoint(urlString: url, token: token.isEmpty ? oldToken : token)
        let changed = e.url != g.url || e.token != oldToken
        if changed { try await probe(e) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        g.name = trimmed.isEmpty ? SavedGateway.defaultName(for: e.url) : trimmed
        g.url = e.url
        try SharedEndpoint.save(g, token: e.token)
        reloadGateways()
        if changed, id == activeId { switchTo(id, force: true) }
    }

    /// Shows a different gateway. The one left behind keeps notifying but
    /// stops driving the Live Activity and widget.
    func switchTo(_ id: String, force: Bool = false) {
        guard force || id != activeId, gateway(id) != nil else { return }
        if let previous = activeId, previous != id, let old = activeGateway.flatMap(SharedEndpoint.endpoint) {
            Task { await demote(old, gatewayId: previous) }
        }
        SharedEndpoint.activeId = id
        reloadGateways()
        store.stop()
        store.reset()
        AgentBoard.empty.save()
        WidgetCenter.shared.reloadAllTimelines()
        // The summary showed the old gateway's agents; the new one starts its own.
        Task { await liveActivity.endNow() }
        if let endpoint { store.start(endpoint) }
    }

    /// Forgets a gateway, telling it to stop sending to this iPhone.
    func remove(_ id: String) {
        guard let g = gateway(id) else { return }
        if let e = SharedEndpoint.endpoint(g), let device = push.deviceToken {
            Task { await Self.oneShot(e, "gw.push_unregister", ["token": .string(device)]) }
        }
        let wasActive = id == activeId
        SharedEndpoint.remove(id)
        reloadGateways()
        guard wasActive else { return }
        store.stop()
        store.reset()
        AgentBoard.empty.save()
        WidgetCenter.shared.reloadAllTimelines()
        // The summary showed the old gateway's agents; the new one starts its own.
        Task { await liveActivity.endNow() }
        if let endpoint { store.start(endpoint) }
    }

    /// Re-registers a gateway that's no longer on screen without the Live
    /// Activity and widget, and drops the activity it was updating.
    private func demote(_ e: GatewayEndpoint, gatewayId: String) async {
        #if targetEnvironment(simulator)
        return // simulators never register (see HerdrStore.sendPushRegistration)
        #endif
        guard let device = push.deviceToken else { return }
        await Self.oneShot(e, "gw.push_register", [
            "token": .string(device), "environment": .string(PushManager.environment),
            "name": .string(UIDevice.current.name), "gateway_id": .string(gatewayId), "live_activity": false,
        ])
        await Self.oneShot(e, "gw.activity_ended", ["token": .string(device)])
    }

    /// One call over a short-lived connection of its own.
    private nonisolated static func oneShot(_ e: GatewayEndpoint, _ method: String, _ params: [String: JSONValue]) async {
        let client = GatewayClient(url: e.url, token: e.token)
        if (try? await client.connect()) != nil {
            try? await client.send(method, params: .object(params))
        }
        await client.disconnect()
    }

    /// A tapped notification opens its pane; its buttons answer the agent
    /// without opening the app, over a short-lived connection of their own.
    func handleNotification(action: String, paneId: String?, gatewayId: String?, text: String?) async {
        guard let paneId else { return }
        // Older gateways don't say which they are; assume the one on screen.
        let source = gatewayId.flatMap(gateway) ?? activeGateway
        if action == UNNotificationDefaultActionIdentifier {
            if let source { switchTo(source.id) }
            pendingPaneId = paneId
            return
        }
        guard let endpoint = source.flatMap(SharedEndpoint.endpoint) else { return }
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
