import Foundation
import HerdrKit

// State the app and the widget extension share: the paired gateways (URLs in
// the App Group's defaults, tokens in the shared Keychain group, which is the
// first keychain-access-groups entry in both targets and so where new items
// go) and the last agent board, so the widget has something to show offline.

enum AppGroup {
    static let id = "group.dev.bal.herdr"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// A paired gateway. The URL and name live in the App Group's defaults, the
/// token in the shared Keychain under an account of its own.
struct SavedGateway: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var url: URL

    /// "macmini" for wss://macmini.tailnet.ts.net/ws.
    static func defaultName(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return host }
        return String(host.split(separator: ".").first ?? Substring(host))
    }
}

/// Every paired gateway, and which one the app (and so the widget) shows.
enum SharedEndpoint {
    private static let listKey = "gateways"
    private static let activeKey = "gateways.active"
    // Single-gateway builds stored these; see migrate().
    private static let urlKey = "gateway.url"
    private static let tokenAccount = "gateway.token"

    private static func tokenAccount(_ id: String) -> String { "gateway.token.\(id)" }

    static func gateways() -> [SavedGateway] {
        guard let data = AppGroup.defaults.data(forKey: listKey) else { return [] }
        return (try? JSONDecoder().decode([SavedGateway].self, from: data)) ?? []
    }

    static func saveList(_ list: [SavedGateway]) {
        AppGroup.defaults.set(try? JSONEncoder().encode(list), forKey: listKey)
    }

    static var activeId: String? {
        get { AppGroup.defaults.string(forKey: activeKey) }
        set { AppGroup.defaults.set(newValue, forKey: activeKey) }
    }

    static func token(_ id: String) -> String? { Keychain.read(account: tokenAccount(id)) }

    static func endpoint(_ g: SavedGateway) -> GatewayEndpoint? {
        token(g.id).map { GatewayEndpoint(url: g.url, token: $0) }
    }

    /// Adds or replaces a gateway (token included).
    static func save(_ g: SavedGateway, token: String) throws {
        try Keychain.write(token, account: tokenAccount(g.id))
        var list = gateways()
        if let i = list.firstIndex(where: { $0.id == g.id }) { list[i] = g } else { list.append(g) }
        saveList(list)
    }

    static func remove(_ id: String) {
        Keychain.delete(account: tokenAccount(id))
        saveList(gateways().filter { $0.id != id })
        if activeId == id { activeId = gateways().first?.id }
    }

    /// The gateway the app shows; the widget reads it too.
    static func load() -> GatewayEndpoint? {
        let list = gateways()
        guard let g = list.first(where: { $0.id == activeId }) ?? list.first else { return nil }
        return endpoint(g)
    }

    /// Earlier builds kept one gateway: first in the app's own defaults and
    /// private Keychain group (where the widget can't see it), then under
    /// fixed keys in the App Group. Moves either into the list.
    static func migrate() {
        guard AppGroup.defaults.data(forKey: listKey) == nil else { return }
        let raw = AppGroup.defaults.string(forKey: urlKey) ?? UserDefaults.standard.string(forKey: urlKey)
        guard let raw, let token = Keychain.read(account: tokenAccount),
              let e = try? GatewayEndpoint(urlString: raw, token: token) else { return }
        let g = SavedGateway(id: UUID().uuidString, name: SavedGateway.defaultName(for: e.url), url: e.url)
        guard (try? save(g, token: e.token)) != nil else { return }
        activeId = g.id
        Keychain.delete(account: tokenAccount)
        AppGroup.defaults.removeObject(forKey: urlKey)
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
