import Foundation

public enum GatewayError: Error, LocalizedError, Equatable, Sendable {
    /// HTTP 401/403 on upgrade: wrong token or tailnet user not allowed. Retrying won't help.
    case unauthorized(status: Int)
    case notConnected
    case disconnected(String?)
    case timeout(method: String)
    case server(code: String, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(403): "This Tailscale account isn't allowed by the gateway (403)."
        case .unauthorized: "The gateway rejected the token (401). Re-pair the app."
        case .notConnected: "Not connected."
        case .disconnected(let reason): "Disconnected\(reason.map { ": \($0)" } ?? "")."
        case .timeout(let method): "\(method) timed out."
        case .server(let code, let message): "\(message) (\(code))"
        case .badResponse(let detail): "Unexpected response: \(detail)"
        }
    }

    public var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

/// One WebSocket session with the herdr iOS gateway. Not reconnecting: when the
/// socket drops, every pending call and stream fails and `waitUntilClosed()`
/// returns. Owners create a fresh client to reconnect.
public actor GatewayClient {
    public nonisolated let url: URL
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private var closedReason: String??  // nil = open; .some = closed with optional reason
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var subscriptions: [String: AsyncThrowingStream<HerdrEvent, Error>.Continuation] = [:]
    private var watches: [String: AsyncThrowingStream<PaneFrame, Error>.Continuation] = [:]
    private var closeWaiters: [CheckedContinuation<String?, Never>] = []
    private var keepalive: Task<Void, Never>?

    static let modelDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let plainDecoder = JSONDecoder()

    public init(url: URL, token: String, session: URLSession = .shared) {
        self.url = url
        self.token = token
        self.session = session
    }

    // MARK: Lifecycle

    /// Opens the socket and verifies it end to end with `gw.info`.
    public func connect(timeout: TimeInterval = 10) async throws -> GatewayInfo {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        Task { await self.receiveLoop(task) }
        do {
            let info: GatewayInfo = try await call("gw.info", timeout: timeout)
            startKeepalive()
            return info
        } catch {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
                close(reason: "HTTP \(status)")
                throw GatewayError.unauthorized(status: status)
            }
            close(reason: error.localizedDescription)
            throw error
        }
    }

    public func disconnect() {
        close(reason: "client closed")
    }

    /// Suspends until the socket closes; returns the reason if known.
    public func waitUntilClosed() async -> String? {
        if let reason = closedReason { return reason }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }

    public var isOpen: Bool { closedReason == nil && task != nil }

    // MARK: Calls

    /// Calls a herdr (or gw.*) method and decodes `result` as `R`.
    public func call<R: Decodable & Sendable>(
        _ method: String, params: JSONValue = [:], timeout: TimeInterval = 20
    ) async throws -> R {
        let data = try await callRaw(method, params: params, timeout: timeout)
        do {
            return try Self.modelDecoder.decode(ResultEnvelope<R>.self, from: data).result
        } catch {
            throw GatewayError.badResponse("\(method): \(error)")
        }
    }

    /// Calls a method whose result we don't need beyond success.
    public func send(_ method: String, params: JSONValue = [:], timeout: TimeInterval = 20) async throws {
        _ = try await callRaw(method, params: params, timeout: timeout)
    }

    public func snapshot() async throws -> SessionSnapshot {
        let r: SessionSnapshotResult = try await call("session.snapshot")
        return r.snapshot
    }

    /// Recent output of a pane, oldest first, ending with its current screen.
    /// Shells give their scrollback with colors. Agents draw their own
    /// screen, so their history comes from herdr's agent reader, which only
    /// returns plain text, or for Claude Code (which herdr can't read back)
    /// from Claude's session file via the gateway. `truncated` means there's
    /// more than `lines`; `logical` means lines are whole paragraphs rather
    /// than screen rows (no re-wrapping needed).
    public func history(paneId: String, agent: String?, lines: Int) async throws
        -> (text: String, truncated: Bool, logical: Bool)
    {
        if agent == "claude" {
            if let t: TranscriptResult = try? await call("gw.claude_transcript", params: [
                "pane_id": .string(paneId), "lines": .number(Double(lines)),
            ], timeout: 30) {
                return (t.text, t.truncated, true)
            }
        }
        let r: PaneReadResult
        if agent != nil {
            r = try await call("agent.read", params: [
                "target": .string(paneId), "source": "recent", "lines": .number(Double(lines)), "format": "text",
            ], timeout: 30)
        } else {
            r = try await call("pane.read", params: [
                "pane_id": .string(paneId), "source": "recent", "lines": .number(Double(lines)),
                "format": "ansi", "strip_ansi": false,
            ], timeout: 30)
        }
        return (r.read.text, r.read.truncated ?? false, false)
    }

    /// Creates a workspace (without stealing focus on the Mac); returns it and its first pane.
    public func createWorkspace(label: String?, cwd: String?) async throws -> (workspaceId: String, paneId: String) {
        var params: [String: JSONValue] = ["focus": false]
        if let label { params["label"] = .string(label) }
        if let cwd { params["cwd"] = .string(cwd) }
        let r: WorkspaceCreatedResult = try await call("workspace.create", params: .object(params))
        return (r.workspace.workspaceId, r.rootPane.paneId)
    }

    /// Agent kinds installed on the Mac that herdr can start.
    public func agentKinds() async throws -> [String] {
        let r: AgentKindsResult = try await call("gw.agent_kinds")
        return r.kinds
    }

    private func callRaw(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> Data {
        guard closedReason == nil, let task else { throw GatewayError.notConnected }
        let id = "c\(nextId)"
        nextId += 1
        let message = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let data: Data = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            task.send(.string(String(decoding: message, as: UTF8.self))) { error in
                if let error { Task { await self.fail(id, with: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.fail(id, with: GatewayError.timeout(method: method))
            }
        }
        if let err = try? Self.plainDecoder.decode(ErrorEnvelope.self, from: data) {
            throw GatewayError.server(code: err.error.code, message: err.error.message)
        }
        return data
    }

    private func fail(_ id: String, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: Streams

    /// herdr `events.subscribe`. The stream ends (without error) if herdr closes it.
    public func subscribe(_ subscriptions: [JSONValue]) async throws -> (id: String, events: AsyncThrowingStream<HerdrEvent, Error>) {
        let (stream, continuation) = AsyncThrowingStream<HerdrEvent, Error>.makeStream()
        // Register before the call so events racing the response aren't dropped.
        let id = "c\(nextId)"
        self.subscriptions[id] = continuation
        do {
            _ = try await callRaw("events.subscribe", params: ["subscriptions": .array(subscriptions)], timeout: 10)
        } catch {
            self.subscriptions.removeValue(forKey: id)
            continuation.finish(throwing: error)
            throw error
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return (id, stream)
    }

    public func unsubscribe(_ id: String) async {
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        try? await send("gw.unsubscribe", params: ["subscription": .string(id)], timeout: 5)
    }

    /// Gateway-side polling of `pane.read`; yields a frame whenever the text changes.
    public func watchPane(
        _ paneId: String, source: String = "visible", format: String = "ansi", intervalMs: Int = 100
    ) async throws -> AsyncThrowingStream<PaneFrame, Error> {
        let (stream, continuation) = AsyncThrowingStream<PaneFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let r: WatchStarted = try await call(
            "gw.watch_pane",
            params: ["pane_id": .string(paneId), "source": .string(source), "format": .string(format),
                     "interval_ms": .number(Double(intervalMs))])
        watches[r.watch] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unwatch(r.watch) }
        }
        return stream
    }

    private func unwatch(_ watchId: String) async {
        guard watches.removeValue(forKey: watchId) != nil else { return }
        try? await send("gw.unwatch_pane", params: ["watch": .string(watchId)], timeout: 5)
    }

    // MARK: Receive

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let s): route(Data(s.utf8))
                case .data(let d): route(d)
                @unknown default: break
                }
            } catch {
                close(reason: error.localizedDescription)
                return
            }
        }
    }

    private func route(_ data: Data) {
        guard let header = try? Self.plainDecoder.decode(Header.self, from: data) else { return }
        if let id = header.id {
            pending.removeValue(forKey: id)?.resume(returning: data)
        } else if let sub = header.subscription {
            if header.closed == true {
                subscriptions.removeValue(forKey: sub)?.finish()
            } else if let env = try? Self.plainDecoder.decode(SubscriptionMessage.self, from: data) {
                subscriptions[sub]?.yield(env.event)
            }
        } else if let watch = header.watch {
            if header.closed == true {
                let err = header.error.map { GatewayError.server(code: $0.code, message: $0.message) }
                watches.removeValue(forKey: watch)?.finish(throwing: err)
            } else if let msg = try? Self.modelDecoder.decode(WatchMessage.self, from: data), let frame = msg.frame {
                watches[watch]?.yield(frame)
            }
        }
    }

    private func startKeepalive() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                await self.ping()
            }
        }
    }

    private func ping() {
        guard closedReason == nil, let task else { return }
        task.sendPing { error in
            if let error { Task { await self.close(reason: "ping failed: \(error.localizedDescription)") } }
        }
    }

    private func close(reason: String?) {
        guard closedReason == nil else { return }
        closedReason = .some(reason)
        keepalive?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        let err = GatewayError.disconnected(reason)
        for (_, c) in pending { c.resume(throwing: err) }
        pending.removeAll()
        for (_, c) in subscriptions { c.finish(throwing: err) }
        subscriptions.removeAll()
        for (_, c) in watches { c.finish(throwing: err) }
        watches.removeAll()
        for w in closeWaiters { w.resume(returning: reason) }
        closeWaiters.removeAll()
    }
}

// MARK: - Wire types

private struct Request: Encodable {
    let id: String
    let method: String
    let params: JSONValue
}

private struct ResultEnvelope<R: Decodable>: Decodable {
    let result: R
}

struct ErrorBody: Decodable, Sendable {
    let code: String
    let message: String
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody
}

private struct Header: Decodable {
    let id: String?
    let subscription: String?
    let watch: String?
    let closed: Bool?
    let error: ErrorBody?

    enum CodingKeys: String, CodingKey { case id, subscription, watch, closed, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Gateway echoes ids verbatim; ours are always strings.
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        subscription = try c.decodeIfPresent(String.self, forKey: .subscription)
        watch = try c.decodeIfPresent(String.self, forKey: .watch)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed)
        error = try? c.decodeIfPresent(ErrorBody.self, forKey: .error)
    }
}

private struct SubscriptionMessage: Decodable {
    let event: HerdrEvent
}

private struct WatchMessage: Decodable {
    let frame: PaneFrame?
}

private struct WatchStarted: Decodable, Sendable {
    let watch: String
}

private struct WorkspaceCreatedResult: Decodable, Sendable {
    struct Created: Decodable, Sendable { let workspaceId: String }
    struct RootPane: Decodable, Sendable { let paneId: String }
    let workspace: Created
    let rootPane: RootPane
}

private struct AgentKindsResult: Decodable, Sendable {
    let kinds: [String]
}

private struct TranscriptResult: Decodable, Sendable {
    let text: String
    let truncated: Bool
}

private struct PaneReadResult: Decodable, Sendable {
    struct Read: Decodable, Sendable {
        let text: String
        let truncated: Bool?
    }
    let read: Read
}
