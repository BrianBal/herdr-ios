import Foundation
import HerdrKit
import Observation
import UIKit
import UserNotifications
import WidgetKit

/// A pane to open once its machine's snapshot has it (a notification, a
/// widget link). No gateway: the primary one (links from the widget).
struct PaneRequest: Equatable {
    var gatewayId: String?
    var paneId: String
}

/// App-wide state: the paired gateways (shared with the widget, see
/// SharedEndpoint) and a live HerdrStore for each, all connected at once.
///
/// Only one gateway can drive the widget and the Live Activity, which it
/// updates with pushes: the primary one (the first paired, unless changed in
/// Settings). The others just send notifications.
@MainActor @Observable
final class AppModel {
    private(set) var gateways: [SavedGateway] = []
    private(set) var primaryId: String?
    private(set) var stores: [String: HerdrStore] = [:]
    let push = PushManager()
    let liveActivity = LiveActivityManager()
    let quickPrompts = QuickPrompts()
    var pairingError: String?
    /// Pane requested via a notification or `herdr-ios://open?pane=<id>`; RootView opens it and clears it.
    var pendingOpen: PaneRequest?

    init() {
        SharedEndpoint.migrate()
        reloadGateways()
        liveActivity.onRegistrationChange = { [unowned self] in primaryStore?.pushRegistrationChanged() }
        liveActivity.onActivityToken = { [unowned self] token, ended in Task { await reportActivity(token: token, ended: ended) } }
    }

    /// Stores in the order the gateways were paired.
    var orderedStores: [HerdrStore] { gateways.compactMap { stores[$0.id] } }

    var primaryStore: HerdrStore? { primaryId.flatMap { stores[$0] } }

    func store(_ gatewayId: String) -> HerdrStore? { stores[gatewayId] }

    /// The new store's registration says whether it's the one updating the
    /// widget and Live Activity, so moving that role is just re-registering both.
    private func makeStore(_ id: String) -> HerdrStore {
        let store = HerdrStore(gatewayId: id)
        store.registrationExtras = { [unowned self] in
            var extras: [String: JSONValue] = ["gateway_id": .string(id)]
            guard id == primaryId else {
                extras["live_activity"] = false
                return extras
            }
            extras["live_activity"] = .bool(liveActivity.enabled)
            if let t = AppGroup.defaults.string(forKey: Self.widgetTokenKey) { extras["widget_token"] = .string(t) }
            if let t = liveActivity.startToken { extras["activity_start_token"] = .string(t) }
            return extras
        }
        store.onBoard = { [unowned self] board in
            if id == primaryId { Task { await liveActivity.sync(board) } }
        }
        store.isPrimary = id == primaryId
        store.registerPush(token: push.deviceToken)
        return store
    }

    /// One store per saved gateway: new ones made (connected by `resume`),
    /// removed ones stopped.
    private func syncStores() {
        for (id, store) in stores where gateway(id) == nil {
            store.stop()
            stores[id] = nil
        }
        for g in gateways where stores[g.id] == nil { stores[g.id] = makeStore(g.id) }
        for (id, store) in stores { store.isPrimary = id == primaryId }
    }

    func registerPush(token: String?) {
        for store in stores.values { store.registerPush(token: token) }
    }

    /// Written by the widget's push handler (AgentsPushHandler.tokenKey).
    private static let widgetTokenKey = "widget.pushToken"

    /// Picks up the widget's push token; the app is the one that talks to the gateway.
    func refreshWidgetToken() async {
        guard #available(iOS 26.0, *), let token = await Self.widgetPushToken(),
              token != AppGroup.defaults.string(forKey: Self.widgetTokenKey) else { return }
        AppGroup.defaults.set(token, forKey: Self.widgetTokenKey)
        primaryStore?.pushRegistrationChanged()
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
        guard let device = push.deviceToken, let primary = primaryGateway, let endpoint = SharedEndpoint.endpoint(primary) else { return }
        let method = ended ? "gw.activity_ended" : "gw.activity_register"
        let params: [String: JSONValue] = ["token": .string(device), "activity_token": .string(token)]
        if let store = primaryStore, let client = store.client, store.isConnected {
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
        if let pane = env["HERDR_OPEN_PANE"] { pendingOpen = PaneRequest(gatewayId: nil, paneId: pane) }
    }
    #endif

    /// Connects every gateway that isn't connected (or trying to).
    func resume() {
        for g in gateways {
            guard let store = stores[g.id], let endpoint = SharedEndpoint.endpoint(g) else { continue }
            if store.phase == .idle || store.endpoint != endpoint { store.start(endpoint) }
        }
    }

    /// Drops every connection (the app went to the background).
    func suspend() {
        for store in stores.values { store.stop() }
    }

    var primaryGateway: SavedGateway? { gateways.first { $0.id == primaryId } }

    func gateway(_ id: String) -> SavedGateway? { gateways.first { $0.id == id } }

    func name(of gatewayId: String) -> String { gateway(gatewayId)?.name ?? "herdr" }

    private func reloadGateways() {
        gateways = SharedEndpoint.gateways()
        if SharedEndpoint.activeId.flatMap(gateway) == nil { SharedEndpoint.activeId = gateways.first?.id }
        primaryId = SharedEndpoint.activeId
        syncStores()
    }

    /// Connects once to check the URL and token before anything is saved.
    private func probe(_ e: GatewayEndpoint) async throws {
        let probe = GatewayClient(url: e.url, token: e.token)
        defer { Task { await probe.disconnect() } }
        _ = try await probe.connect()
    }

    /// Pairs with a gateway and connects to it. Pairing again with one already
    /// saved (same URL) just updates its token.
    func pair(_ e: GatewayEndpoint, name: String? = nil) async throws {
        try await probe(e)
        let existing = gateways.first { $0.url == e.url }
        var g = existing ?? SavedGateway(id: UUID().uuidString, name: SavedGateway.defaultName(for: e.url), url: e.url)
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { g.name = name }
        try SharedEndpoint.save(g, token: e.token)
        reloadGateways()
        pairingError = nil
        stores[g.id]?.start(e)
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
        if changed, let store = stores[id] {
            store.stop()
            store.reset()
            store.start(e)
        }
    }

    /// Moves the widget and Live Activity to another gateway. Both re-register,
    /// so the old one stops updating them; the summary starts over from the new one.
    func makePrimary(_ id: String) {
        guard id != primaryId, gateway(id) != nil else { return }
        let previous = primaryStore
        SharedEndpoint.activeId = id
        reloadGateways()
        if let previous, let client = previous.client, previous.isConnected, let device = push.deviceToken {
            Task { try? await client.send("gw.activity_ended", params: ["token": .string(device)]) }
        }
        previous?.pushRegistrationChanged()
        primaryStore?.pushRegistrationChanged()
        primaryStore?.republishBoard()
        AgentBoard.empty.save()
        WidgetCenter.shared.reloadAllTimelines()
        Task { await liveActivity.endNow() }
    }

    /// Forgets a gateway, telling it to stop sending to this iPhone.
    func remove(_ id: String) {
        guard let g = gateway(id) else { return }
        if let e = SharedEndpoint.endpoint(g), let device = push.deviceToken {
            Task { await Self.oneShot(e, "gw.push_unregister", ["token": .string(device)]) }
        }
        let wasPrimary = id == primaryId
        SharedEndpoint.remove(id)
        reloadGateways()
        guard wasPrimary else { return }
        AgentBoard.empty.save()
        WidgetCenter.shared.reloadAllTimelines()
        // The summary showed the old gateway's agents; the new primary starts its own.
        Task { await liveActivity.endNow() }
        primaryStore?.pushRegistrationChanged()
        primaryStore?.republishBoard()
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
        // Older gateways don't say which they are; assume the primary one.
        let source = gatewayId.flatMap(gateway) ?? primaryGateway
        if action == UNNotificationDefaultActionIdentifier {
            pendingOpen = PaneRequest(gatewayId: source?.id, paneId: paneId)
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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let pane = items.first(where: { $0.name == "pane" })?.value {
                pendingOpen = PaneRequest(gatewayId: items.first { $0.name == "gateway" }?.value, paneId: pane)
            }
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
