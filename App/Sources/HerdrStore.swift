import Foundation
import HerdrKit
import Observation
import UIKit
import WidgetKit

/// Live mirror of one machine's herdr session through its gateway. Owns the
/// reconnect loop; views read `snapshot` and call the action methods. The app
/// keeps one per paired gateway, all connected at once.
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

    /// The SavedGateway this mirrors.
    let gatewayId: String
    private(set) var phase: Phase = .idle
    /// When the snapshot last came in; what an offline machine's "last seen" says.
    private(set) var lastSeen: Date?
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

    /// Can't reach the machine right now (retrying, or the token was refused).
    var isOffline: Bool {
        switch phase {
        case .waiting, .unauthorized: true
        case .idle, .connecting, .connected: false
        }
    }

    /// Updates the widget and Live Activity (see AppModel).
    var isPrimary = false {
        didSet { if isPrimary != oldValue { lastBoard = nil } }
    }

    init(gatewayId: String) {
        self.gatewayId = gatewayId
    }

    /// Each pane's terminal (screen, history, transcript), most recently
    /// opened last; kept across swipes, folds and reconnects.
    @ObservationIgnored private var terminals: [String: TerminalModel] = [:]
    @ObservationIgnored private var terminalOrder: [String] = []
    static let keptTerminals = 8

    func terminal(for paneId: String) -> TerminalModel {
        terminalOrder.removeAll { $0 == paneId }
        terminalOrder.append(paneId)
        if let model = terminals[paneId] { return model }
        let model = TerminalModel()
        terminals[paneId] = model
        while terminalOrder.count > Self.keptTerminals { terminals[terminalOrder.removeFirst()] = nil }
        return model
    }

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

    /// Forget the last gateway's state (switching or removing gateways).
    func reset() {
        // Pane ids repeat across machines (both have a w1:p1).
        terminals = [:]
        terminalOrder = []
        snapshot = nil
        lastSeen = nil
        previews = [:]
        lastPanes = [:]
        latency = nil
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
                agentKinds = (try? await c.agentKinds()) ?? agentKinds
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
        let started = ContinuousClock.now
        let s = try await c.snapshot()
        latency = ContinuousClock.now - started
        snapshot = s
        lastSeen = .now
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

    // MARK: Previews

    /// Each pane's screen (ANSI) as last read for the tabs overview, kept when
    /// the machine goes offline.
    private(set) var previews: [String: String] = [:]
    /// The pane last on screen in each workspace, which its card shows.
    @ObservationIgnored private var lastPanes: [String: String] = [:]

    func noteVisible(paneId: String, in workspaceId: String) {
        lastPanes[workspaceId] = paneId
    }

    /// Leaving a pane: its card shows the screen as you last saw it until the
    /// overview's next read.
    func keepPreview(of paneId: String) {
        if let text = terminals[paneId]?.screenText, !text.isEmpty { previews[paneId] = text }
    }

    /// The pane a workspace's card shows: the one you last looked at, else
    /// the one herdr has focused in its active tab.
    func previewPane(of workspaceId: String) -> String? {
        guard let s = snapshot else { return nil }
        if let id = lastPanes[workspaceId], s.pane(id)?.workspaceId == workspaceId { return id }
        guard let ws = s.workspace(workspaceId) else { return nil }
        let panes = s.panes(in: ws.activeTabId)
        let focused = s.layouts.first { $0.tabId == ws.activeTabId }?.focusedPaneId
        return (panes.first { $0.paneId == focused } ?? panes.first ?? s.panes.first { $0.workspaceId == workspaceId })?.paneId
    }

    /// Reads every card's pane once.
    func refreshPreviews() async {
        guard let client, isConnected, let s = snapshot else { return }
        let panes = s.sortedWorkspaces.compactMap { previewPane(of: $0.workspaceId) }
        guard let screens = try? await client.screens(panes, rows: Self.previewRows) else { return }
        for (id, text) in screens where previews[id] != text { previews[id] = text }
    }

    /// Enough rows for a card at its smallest legible size.
    static let previewRows = 36

    // MARK: Actions

    /// Agents get `agent.prompt` (bracketed-paste safe, then Enter); shells get text + Enter.
    @discardableResult
    func submit(_ text: String, to pane: Pane) async -> Bool {
        let typed: JSONValue = ["pane_id": .string(pane.paneId), "text": .string(text), "keys": ["enter"]]
        guard pane.hasAgent else { return await perform("pane.send_input", typed) }
        guard let client else {
            actionError = "Not connected to herdr."
            return false
        }
        do {
            try await client.send("agent.prompt", params: ["target": .string(pane.paneId), "text": .string(text)])
            return true
        } catch GatewayError.server(code: "agent_blocked", _) {
            // herdr won't prompt an agent it thinks is waiting for an answer,
            // and its hooks can leave that stale (OpenCode stays "blocked" after
            // a subagent's question). You can see the screen: type it in.
            return await perform("pane.send_input", typed)
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    /// A message with photos: each is saved on the gateway's machine and its
    /// path added to the prompt, since agents open images by path.
    @discardableResult
    func submit(_ text: String, photos: [Data], to pane: Pane) async -> Bool {
        guard !photos.isEmpty else { return await submit(text, to: pane) }
        guard let client else {
            actionError = "Not connected to herdr."
            return false
        }
        var paths: [String] = []
        do {
            for photo in photos {
                let r: Uploaded = try await client.call(
                    "gw.upload", params: ["data": .string(photo.base64EncodedString()), "ext": "jpg"], timeout: 60)
                paths.append(r.path)
            }
        } catch {
            actionError = "Couldn't send the photo: \(error.localizedDescription)"
            return false
        }
        return await submit(Self.prompt(text, attaching: paths), to: pane)
    }

    /// Tab completions for a shell pane's command line; nil when there are none
    /// or the gateway can't say (an older gateway, a dropped connection).
    func completions(for paneId: String, line: String) async -> ShellCompletions? {
        guard let client, isConnected else { return nil }
        guard let c = try? await client.complete(paneId: paneId, line: line), !c.candidates.isEmpty else { return nil }
        return c
    }

    static func prompt(_ text: String, attaching paths: [String]) -> String {
        let lines = paths.map { "Attached image: \($0)" }.joined(separator: "\n")
        return text.isEmpty ? lines : "\(text)\n\n\(lines)"
    }

    private struct Uploaded: Decodable, Sendable {
        let path: String
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

    /// Saves the board for the widget and tells it and the Live Activity, when
    /// it changed. Only the primary machine's: the widget shows one.
    private func publishBoard(_ s: SessionSnapshot) {
        guard isPrimary else { return }
        let board = AgentBoard(snapshot: s)
        guard board.rows != lastBoard?.rows else { return }
        lastBoard = board
        board.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "Agents")
        onBoard?(board)
    }

    /// Publishes the current board again (this store just became the primary).
    func republishBoard() {
        lastBoard = nil
        if let snapshot { publishBoard(snapshot) }
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

    // MARK: Tabs and panes

    enum SplitDirection: String { case right, down }

    /// Opens a tab in the workspace; returns its pane once the snapshot has it.
    func newTab(in workspaceId: String, cwd: String?) async -> String? {
        var params: [String: JSONValue] = ["workspace_id": .string(workspaceId)]
        if let cwd { params["cwd"] = .string(cwd) }
        return await createPane("tab.create", params, paneKey: "root_pane")
    }

    /// Splits a pane; returns the new pane once the snapshot has it.
    func split(_ paneId: String, _ direction: SplitDirection, cwd: String?) async -> String? {
        var params: [String: JSONValue] = ["target_pane_id": .string(paneId), "direction": .string(direction.rawValue)]
        if let cwd { params["cwd"] = .string(cwd) }
        return await createPane("pane.split", params, paneKey: "pane")
    }

    /// Closes a pane (and its tab, if it was the last one; and the workspace,
    /// if that was its last tab).
    @discardableResult
    func closePane(_ paneId: String) async -> Bool {
        let ok = await perform("pane.close", ["pane_id": .string(paneId)])
        if ok, let client { try? await refresh(using: client) }
        return ok
    }

    private struct CreatedPane: Decodable, Sendable {
        struct P: Decodable, Sendable { let paneId: String }
        let pane: P?
        let rootPane: P?
    }

    private func createPane(_ method: String, _ params: [String: JSONValue], paneKey: String) async -> String? {
        guard let client else {
            actionError = "Not connected to herdr."
            return nil
        }
        do {
            let r: CreatedPane = try await client.call(method, params: .object(params))
            try? await refresh(using: client)
            return (paneKey == "pane" ? r.pane : r.rootPane)?.paneId
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    // MARK: Agents

    /// Agents installed on the Mac that herdr can start (claude, codex, …).
    private(set) var agentKinds: [String] = []
    /// How long the last snapshot took to come back: phone → gateway → herdr and back.
    private(set) var latency: Duration?

    /// Starts an agent in a pane that's at its shell prompt. herdr wants a
    /// unique name: the workspace's name, then "-2", "-3"… if taken. A first
    /// prompt waits until the agent is ready, including while it waits on you
    /// (e.g. "trust this folder?"), for up to two minutes.
    func startAgent(_ kind: String, in paneId: String, nameHint: String, prompt: String?) async {
        guard let client else {
            actionError = "Not connected to herdr."
            return
        }
        let base = Self.agentName(nameHint, kind: kind)
        var started = false
        var suffix = 1
        // A brand-new pane's shell is still starting (profile scripts) for a moment.
        let shellDeadline = Date.now.addingTimeInterval(20)
        while !started, suffix <= 9 {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            do {
                try await client.send("agent.start", params: [
                    "name": .string(name), "kind": .string(kind), "pane_id": .string(paneId),
                ])
                started = true
            } catch GatewayError.server(code: "agent_name_taken", _) {
                suffix += 1
            } catch GatewayError.server(code: "agent_pane_busy", _) where Date.now < shellDeadline {
                try? await Task.sleep(for: .seconds(1))
            } catch {
                actionError = "Couldn't start \(AgentKind.displayName(kind)): \(error.localizedDescription)"
                return
            }
        }
        guard started else {
            actionError = "Couldn't find a free agent name for \(base)."
            return
        }
        scheduleRefresh()
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return }
        let deadline = Date.now.addingTimeInterval(120)
        while Date.now < deadline {
            try? await Task.sleep(for: .seconds(1))
            guard let c = self.client, let s = try? await c.snapshot() else { continue }
            let status = s.agents.first { $0.paneId == paneId }?.agentStatus
            if status == .idle || status == .done {
                await perform("agent.prompt", ["target": .string(paneId), "text": .string(prompt)])
                return
            }
        }
        actionError = "\(AgentKind.displayName(kind)) didn't become ready, so your first prompt wasn't sent."
    }

    /// "html-gen" → "html-gen"; herdr names are simple identifiers.
    private static func agentName(_ hint: String, kind: String) -> String {
        let cleaned = hint.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? kind : String(cleaned.prefix(40))
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

    /// Returns the new workspace and its first pane.
    func createWorkspace(label: String?, cwd: String?) async -> (workspaceId: String, paneId: String)? {
        guard let client else {
            actionError = "Not connected to herdr."
            return nil
        }
        do {
            let created = try await client.createWorkspace(label: label, cwd: cwd)
            try? await refresh(using: client)
            return created
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
