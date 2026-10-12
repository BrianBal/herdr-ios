import Foundation
import HerdrKit
import Observation
import UIKit
import WidgetKit

/// Live mirror of one herdr session through the gateway. Owns the reconnect
/// loop; views read `snapshot` and call the action methods.
///
/// Freshness: a topology subscription and per-pane agent-status subscriptions
/// trigger a debounced `session.snapshot` refetch (it's ~1 ms on the server),
/// with a slow periodic refresh as a safety net.
@MainActor @Observable
final class HerdrStore {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case waiting(retryAt: Date, message: String)
        case unauthorized(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: SessionSnapshot?
    private(set) var info: GatewayInfo?
    private(set) var endpoint: GatewayEndpoint?
    /// Bumps on every successful connect; pane views re-establish watches on change.
    private(set) var generation = 0
    private(set) var client: GatewayClient?
    var actionError: String?

    private var loop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var agentStatusTask: Task<Void, Never>?
    private var agentStatusPanes: Set<String> = []
    private var inputChain: Task<Void, Never>?
    /// APNs token; handed to the gateway on every connect so it knows this
    /// device and that its app is on screen (no pushes while connected).
    private var pushToken: String?
    /// Widget and Live Activity tokens etc. to send along with the push token.
    var registrationExtras: () -> [String: JSONValue] = { [:] }
    /// Called with the agent board whenever it changes (widget, Live Activity).
    var onBoard: ((AgentBoard) -> Void)?
    private var lastBoard: AgentBoard?

    static let topologyEvents = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated", "workspace.renamed",
        "workspace.moved", "workspace.reordered", "workspace.closed", "workspace.focused",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.closed", "pane.updated", "pane.focused", "pane.moved", "pane.exited",
        "pane.agent_detected", "layout.updated",
    ]

    var isConnected: Bool { phase == .connected }

    // MARK: Lifecycle

    func start(_ endpoint: GatewayEndpoint) {
        stop()
        self.endpoint = endpoint
        loop = Task { await run(endpoint) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        cancelBackground()
        if let client { Task { await client.disconnect() } }
        client = nil
        phase = .idle
    }

    /// Forget everything (used when unpairing).
    func reset() {
        snapshot = nil
        info = nil
        endpoint = nil
    }

    func reconnectNow() {
        if let endpoint { start(endpoint) }
    }

    private func cancelBackground() {
        refreshTask?.cancel()
        agentStatusTask?.cancel()
        agentStatusTask = nil
        agentStatusPanes = []
    }

    private func run(_ endpoint: GatewayEndpoint) async {
        var attempt = 0
        while !Task.isCancelled {
            phase = .connecting
            let c = GatewayClient(url: endpoint.url, token: endpoint.token)
            do {
                info = try await c.connect()
                guard !Task.isCancelled else { await c.disconnect(); return }
                attempt = 0
                client = c
                try await refresh(using: c)
                generation += 1
                phase = .connected
                if let pushToken { await sendPushRegistration(pushToken, using: c) }
                let topology = Task { await followTopology(c) }
                let periodic = Task { await periodicRefresh(c) }
                // stop() disconnects the client, which also ends this wait.
                _ = await c.waitUntilClosed()
                topology.cancel()
                periodic.cancel()
                cancelBackground()
            } catch let e as GatewayError where e.isAuthFailure {
                phase = .unauthorized(e.localizedDescription)
                await c.disconnect()
                return
            } catch {
                await c.disconnect()
                if Task.isCancelled { return }
                phase = .waiting(retryAt: .now, message: error.localizedDescription)
            }
            if client === c { client = nil }
            if Task.isCancelled { return }
            attempt += 1
            let delay = Double(min(30, 1 << min(attempt - 1, 5)))
            let message: String = if case .waiting(_, let m) = phase { m } else { "Connection lost." }
            phase = .waiting(retryAt: .now.addingTimeInterval(delay), message: message)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    // MARK: Freshness

    func refresh() async {
        guard let client else { return }
        try? await refresh(using: client)
    }

    private func refresh(using c: GatewayClient) async throws {
        let s = try await c.snapshot()
        snapshot = s
        publishBoard(s)
        updateAgentStatusSubscription(c, panes: Set(s.panes.map(\.paneId)))
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let client else { return }
            try? await refresh(using: client)
        }
    }

    private func periodicRefresh(_ c: GatewayClient) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            try? await refresh(using: c)
        }
    }

    private func followTopology(_ c: GatewayClient) async {
        // herdr may end a subscription stream; resubscribe while the socket lives.
        while !Task.isCancelled, await c.isOpen {
            do {
                let (_, events) = try await c.subscribe(Self.topologyEvents.map { ["type": .string($0)] })
                for try await _ in events { scheduleRefresh() }
            } catch {}
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func updateAgentStatusSubscription(_ c: GatewayClient, panes: Set<String>) {
        guard panes != agentStatusPanes || agentStatusTask == nil else { return }
        agentStatusTask?.cancel()
        agentStatusPanes = panes
        guard !panes.isEmpty else { return }
        let subs: [JSONValue] = panes.sorted().map { ["type": "pane.agent_status_changed", "pane_id": .string($0)] }
        agentStatusTask = Task {
            while !Task.isCancelled, await c.isOpen {
                do {
                    let (_, events) = try await c.subscribe(subs)
                    for try await event in events {
                        applyAgentStatus(event)
                        scheduleRefresh()
                    }
                } catch {}
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Patch the status immediately so badges flip before the refetch lands.
    private func applyAgentStatus(_ event: HerdrEvent) {
        guard var s = snapshot, let paneId = event.paneId, let status = event.agentStatus else { return }
        if let i = s.panes.firstIndex(where: { $0.paneId == paneId }) { s.panes[i].agentStatus = status }
        if let i = s.agents.firstIndex(where: { $0.paneId == paneId }) { s.agents[i].agentStatus = status }
        snapshot = s
    }

    // MARK: Actions

    /// Agents get `agent.prompt` (bracketed-paste safe, then Enter); shells get text + Enter.
    @discardableResult
    func submit(_ text: String, to pane: Pane) async -> Bool {
        if pane.hasAgent {
            await perform("agent.prompt", ["target": .string(pane.paneId), "text": .string(text)])
        } else {
            await perform("pane.send_input", ["pane_id": .string(pane.paneId), "text": .string(text), "keys": ["enter"]])
        }
    }

    /// Fire-and-forget key presses from the toolbar, delivered strictly in tap
    /// order (each waits for the previous one; the gateway keeps per-pane order too).
    func press(_ keys: [String], paneId: String) {
        let previous = inputChain
        inputChain = Task {
            await previous?.value
            await sendKeys(keys, to: paneId)
        }
    }

    @discardableResult
    func sendKeys(_ keys: [String], to paneId: String) async -> Bool {
        await perform("pane.send_keys", ["pane_id": .string(paneId), "keys": .array(keys.map { .string($0) })])
    }

    @discardableResult
    func sendText(_ text: String, to paneId: String) async -> Bool {
        await perform("pane.send_text", ["pane_id": .string(paneId), "text": .string(text)])
    }

    // MARK: Push

    func registerPush(token: String?) {
        guard token != pushToken else { return }
        pushToken = token
        pushRegistrationChanged()
    }

    /// Re-sends the registration (e.g. a widget or Live Activity token arrived).
    func pushRegistrationChanged() {
        if let pushToken, let client, isConnected {
            Task { await sendPushRegistration(pushToken, using: client) }
        }
    }

    private func sendPushRegistration(_ token: String, using c: GatewayClient) async {
        #if targetEnvironment(simulator)
        // Simulators get real APNs tokens, and their notifications play on the Mac.
        return
        #endif
        var params: [String: JSONValue] = [
            "token": .string(token), "environment": .string(PushManager.environment),
            "name": .string(UIDevice.current.name),
        ]
        params.merge(registrationExtras()) { _, extra in extra }
        let r: PushRegistration? = try? await c.call("gw.push_register", params: .object(params))
        pushProblem = r?.problem
    }

    /// Saves the board for the widget and tells it and the Live Activity, when it changed.
    private func publishBoard(_ s: SessionSnapshot) {
        let board = AgentBoard(snapshot: s)
        guard board.rows != lastBoard?.rows else { return }
        lastBoard = board
        board.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "Agents")
        onBoard?(board)
    }

    /// Why the gateway can't send pushes yet (e.g. no APNs key installed), if it said.
    private(set) var pushProblem: String?

    /// Sends a test notification to this device. Returns an error message on failure.
    func sendTestPush() async -> String? {
        guard let client, let pushToken else { return "Not connected, or notifications aren't on." }
        do {
            try await client.send("gw.push_test", params: ["token": .string(pushToken)])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private struct PushRegistration: Decodable, Sendable {
        let ready: Bool
        let problem: String?
    }

    // MARK: Workspaces

    @discardableResult
    func renameWorkspace(_ id: String, to label: String) async -> Bool {
        let ok = await perform("workspace.rename", ["workspace_id": .string(id), "label": .string(label)])
        if ok { scheduleRefresh() }
        return ok
    }

    enum CloseOutcome {
        case closed
        /// It's the primary of a worktree group; closing needs `group: true`, which closes the linked ones too.
        case needsGroup
        case failed
    }

    func closeWorkspace(_ id: String, group: Bool = false) async -> CloseOutcome {
        guard let client else {
            actionError = "Not connected to herdr."
            return .failed
        }
        do {
            try await client.send("workspace.close", params: ["workspace_id": .string(id), "close_group": .bool(group)])
            scheduleRefresh()
            return .closed
        } catch GatewayError.server(code: "workspace_group_close_required", _) {
            return .needsGroup
        } catch {
            actionError = error.localizedDescription
            return .failed
        }
    }

    /// Returns the new workspace's id.
    func createWorkspace(label: String?, cwd: String?) async -> String? {
        guard let client else {
            actionError = "Not connected to herdr."
            return nil
        }
        do {
            let id = try await client.createWorkspace(label: label, cwd: cwd)
            try? await refresh(using: client)
            return id
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    private func perform(_ method: String, _ params: JSONValue) async -> Bool {
        guard let client else {
            actionError = "Not connected to herdr."
            return false
        }
        do {
            try await client.send(method, params: params)
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}
