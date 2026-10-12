import Foundation

// Decoded with .convertFromSnakeCase. Only the fields the app uses are modeled;
// herdr's full schema is `herdr api schema --json`.

public enum AgentStatus: String, Sendable, Codable, CaseIterable {
    case blocked, working, done, idle, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }

    /// Attention order: blocked first, then done (unseen), working, idle, unknown.
    public var priority: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }
}

public struct Workspace: Sendable, Codable, Identifiable, Hashable {
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var tabCount: Int
    public var activeTabId: String
    public var agentStatus: AgentStatus
    public var id: String { workspaceId }
}

public struct Tab: Sendable, Codable, Identifiable, Hashable {
    public var tabId: String
    public var workspaceId: String
    public var number: Int
    public var label: String
    public var focused: Bool
    public var paneCount: Int
    public var agentStatus: AgentStatus
    public var id: String { tabId }
}

public struct PaneScroll: Sendable, Codable, Hashable {
    public var offsetFromBottom: Int
    public var maxOffsetFromBottom: Int
    public var viewportRows: Int
}

public struct Pane: Sendable, Codable, Identifiable, Hashable {
    public var paneId: String
    public var terminalId: String
    public var workspaceId: String
    public var tabId: String
    public var focused: Bool
    public var agentStatus: AgentStatus
    public var agent: String?
    public var displayAgent: String?
    public var cwd: String?
    public var foregroundCwd: String?
    public var label: String?
    public var title: String?
    public var terminalTitleStripped: String?
    public var scroll: PaneScroll?
    public var id: String { paneId }

    public var hasAgent: Bool { agent != nil }

    /// Best human label: explicit label, terminal title, agent, then cwd basename.
    public var displayTitle: String {
        for candidate in [label, title, terminalTitleStripped] {
            if let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        }
        if let a = displayAgent ?? agent { return a }
        if let dir = foregroundCwd ?? cwd { return (dir as NSString).lastPathComponent }
        return paneId
    }
}

public struct Agent: Sendable, Codable, Identifiable, Hashable {
    public var paneId: String
    public var workspaceId: String
    public var tabId: String
    public var agentStatus: AgentStatus
    public var focused: Bool
    public var agent: String?
    public var displayAgent: String?
    public var name: String?
    public var cwd: String?
    public var title: String?
    public var terminalTitleStripped: String?
    public var id: String { paneId }

    public var kindLabel: String { displayAgent ?? agent ?? "agent" }
    public var headline: String {
        // The agent's own title (its current task) beats the name it was started
        // under, which the app sets to the workspace's name.
        for candidate in [title, terminalTitleStripped, name] {
            if let c = candidate?.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        }
        return kindLabel
    }
}

public struct LayoutRect: Sendable, Codable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

public struct LayoutPane: Sendable, Codable, Hashable {
    public var paneId: String
    public var focused: Bool
    public var rect: LayoutRect
}

public struct PaneLayout: Sendable, Codable, Hashable {
    public var workspaceId: String
    public var tabId: String
    public var zoomed: Bool
    public var area: LayoutRect
    public var focusedPaneId: String
    public var panes: [LayoutPane]
}

public struct SessionSnapshot: Sendable, Codable, Hashable {
    public var version: String
    public var `protocol`: Int
    public var workspaces: [Workspace]
    public var tabs: [Tab]
    public var panes: [Pane]
    public var layouts: [PaneLayout]
    public var agents: [Agent]
    public var focusedWorkspaceId: String?
    public var focusedTabId: String?
    public var focusedPaneId: String?

    public init(
        version: String, protocol: Int, workspaces: [Workspace], tabs: [Tab], panes: [Pane],
        layouts: [PaneLayout], agents: [Agent], focusedWorkspaceId: String? = nil,
        focusedTabId: String? = nil, focusedPaneId: String? = nil
    ) {
        self.version = version
        self.protocol = `protocol`
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.layouts = layouts
        self.agents = agents
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
    }

    public var sortedWorkspaces: [Workspace] { workspaces.sorted { $0.number < $1.number } }

    public func tabs(in workspaceId: String) -> [Tab] {
        tabs.filter { $0.workspaceId == workspaceId }.sorted { $0.number < $1.number }
    }

    /// Panes of a tab in reading order (top-to-bottom, then left-to-right) per herdr's layout.
    public func panes(in tabId: String) -> [Pane] {
        let inTab = panes.filter { $0.tabId == tabId }
        guard let layout = layouts.first(where: { $0.tabId == tabId }) else { return inTab }
        let order = Dictionary(
            uniqueKeysWithValues: layout.panes.map { ($0.paneId, ($0.rect.y, $0.rect.x)) })
        return inTab.sorted { a, b in
            let ka = order[a.paneId] ?? (Int.max, Int.max)
            let kb = order[b.paneId] ?? (Int.max, Int.max)
            return ka < kb
        }
    }

    public func agents(in workspaceId: String) -> [Agent] {
        agents.filter { $0.workspaceId == workspaceId }
    }

    public func pane(_ id: String) -> Pane? { panes.first { $0.paneId == id } }
    public func workspace(_ id: String) -> Workspace? { workspaces.first { $0.workspaceId == id } }
}

// MARK: - Gateway messages

public struct HerdrPong: Sendable, Codable, Hashable {
    public var version: String
    public var `protocol`: Int
}

public struct GatewayInfo: Sendable, Codable, Hashable {
    public var gatewayVersion: String
    public var user: String?
    public var herdr: HerdrPong?
}

public struct PaneFrame: Sendable, Codable, Hashable {
    public var seq: Int
    public var paneId: String
    public var text: String
    public var format: String
    public var source: String
}

/// One herdr event line: {"event": "pane.focused", "data": {...}}.
public struct HerdrEvent: Sendable, Codable, Hashable {
    public var event: String
    public var data: JSONValue

    public var paneId: String? { data["pane_id"]?.stringValue }
    public var agentStatus: AgentStatus? {
        data["agent_status"]?.stringValue.flatMap(AgentStatus.init(rawValue:))
    }
}

public struct SessionSnapshotResult: Sendable, Codable {
    public var snapshot: SessionSnapshot
}
