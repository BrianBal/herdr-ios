import Foundation
import HerdrKit

// State the app and the widget extension share: the paired gateway (URL in
// the App Group's defaults, token in the shared Keychain group, which is the
// first keychain-access-groups entry in both targets and so where new items
// go) and the last agent board, so the widget has something to show offline.

enum AppGroup {
    static let id = "group.dev.bal.herdr"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

enum SharedEndpoint {
    private static let urlKey = "gateway.url"
    private static let tokenAccount = "gateway.token"

    static func load() -> GatewayEndpoint? {
        guard let raw = AppGroup.defaults.string(forKey: urlKey),
              let token = Keychain.read(account: tokenAccount) else { return nil }
        return try? GatewayEndpoint(urlString: raw, token: token)
    }

    static func save(_ e: GatewayEndpoint) throws {
        try Keychain.write(e.token, account: tokenAccount)
        AppGroup.defaults.set(e.url.absoluteString, forKey: urlKey)
    }

    static func clear() {
        Keychain.delete(account: tokenAccount)
        AppGroup.defaults.removeObject(forKey: urlKey)
    }

    /// Earlier builds kept the URL in the app's own defaults and the token in
    /// its private Keychain group, where the widget can't see them; move them.
    static func migrateFromAppOnlyStorage() {
        guard AppGroup.defaults.string(forKey: urlKey) == nil,
              let raw = UserDefaults.standard.string(forKey: urlKey),
              let token = Keychain.read(account: tokenAccount),
              let e = try? GatewayEndpoint(urlString: raw, token: token) else { return }
        // write() deletes the old item first, then adds it to the shared group.
        try? save(e)
        UserDefaults.standard.removeObject(forKey: urlKey)
    }
}

/// What the Agents widget shows: every agent, most urgent first.
struct AgentBoard: Codable, Sendable, Equatable {
    struct Row: Codable, Sendable, Hashable, Identifiable {
        var paneId: String
        var kind: String
        var workspace: String
        var headline: String
        var status: AgentStatus
        var id: String { paneId }
    }

    var rows: [Row]
    var updatedAt: Date

    var blocked: Int { rows.count { $0.status == .blocked } }
    var working: Int { rows.count { $0.status == .working } }
    var done: Int { rows.count { $0.status == .done } }
    /// Green on the widget: waiting on you or finished and unseen.
    var needsYou: Int { blocked + done }

    static let empty = AgentBoard(rows: [], updatedAt: .distantPast)

    init(rows: [Row], updatedAt: Date) {
        self.rows = rows
        self.updatedAt = updatedAt
    }

    init(snapshot s: SessionSnapshot, at date: Date = .now) {
        rows = s.agents
            .map { a in
                Row(paneId: a.paneId, kind: a.kindLabel, workspace: s.workspace(a.workspaceId)?.label ?? "",
                    headline: a.headline == a.kindLabel ? "" : a.headline, status: a.agentStatus)
            }
            .sorted { ($0.status.priority, $0.workspace, $0.paneId) < ($1.status.priority, $1.workspace, $1.paneId) }
        updatedAt = date
    }

    private static var cacheURL: URL? { AppGroup.container?.appendingPathComponent("agent-board.json") }

    static func cached() -> AgentBoard? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentBoard.self, from: data)
    }

    func save() {
        guard let url = Self.cacheURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
