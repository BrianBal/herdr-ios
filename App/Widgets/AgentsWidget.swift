import HerdrKit
import SwiftUI
import WidgetKit

/// herdr's agents at a glance: how many need you, how many are working, and
/// the most urgent ones. Tapping an agent opens its pane in the app.
///
/// Freshness: the gateway sends a widget push when the board changes (see
/// Gateway/src/push.ts), WidgetKit then asks for a new timeline, and the
/// provider fetches a snapshot itself. The app also saves the board while
/// it's open, which is what shows when the gateway can't be reached.
struct AgentsWidget: Widget {
    static let kind = "Agents"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: AgentsProvider()) { entry in
            AgentsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("Which agents need you and which are working.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .pushHandler(AgentsPushHandler.self)
    }
}

/// Keeps the widget's push token where the app can hand it to the gateway.
struct AgentsPushHandler: WidgetPushHandler {
    static let tokenKey = "widget.pushToken"

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        AppGroup.defaults.set(pushInfo.token.map { String(format: "%02x", $0) }.joined(), forKey: Self.tokenKey)
    }
}

struct AgentsEntry: TimelineEntry {
    var date: Date
    var board: AgentBoard
    var paired = true
    /// From the gateway just now, rather than the last saved board.
    var live = true
}

struct AgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentsEntry {
        AgentsEntry(date: .now, board: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        if context.isPreview {
            completion(AgentsEntry(date: .now, board: .sample))
        } else {
            completion(AgentsEntry(date: .now, board: AgentBoard.cached() ?? .empty, live: false))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            let entry = await Self.load()
            // Pushes drive updates; this is just a safety net.
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    static func load() async -> AgentsEntry {
        guard let endpoint = SharedEndpoint.load() else {
            return AgentsEntry(date: .now, board: .empty, paired: false, live: false)
        }
        if let board = await fetch(endpoint) {
            board.save()
            return AgentsEntry(date: .now, board: board)
        }
        return AgentsEntry(date: .now, board: AgentBoard.cached() ?? .empty, live: false)
    }

    /// One snapshot over a short-lived connection; gives up after a few seconds
    /// (no Tailscale, Mac asleep) so the widget falls back to the saved board.
    private static func fetch(_ endpoint: GatewayEndpoint) async -> AgentBoard? {
        let client = GatewayClient(url: endpoint.url, token: endpoint.token)
        let board = await withTaskGroup(of: AgentBoard?.self) { group in
            group.addTask {
                guard (try? await client.connect()) != nil, let s = try? await client.snapshot() else { return nil }
                return AgentBoard(snapshot: s)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await client.disconnect()
        return board
    }
}

extension AgentBoard {
    static let sample = AgentBoard(rows: [
        Row(paneId: "w1:p1", kind: "claude", workspace: "html-gen", headline: "Allow edits to charts.py?", status: .blocked),
        Row(paneId: "w2:p1", kind: "codex", workspace: "web-trace", headline: "Investigate TraceID", status: .working),
        Row(paneId: "w3:p1", kind: "claude", workspace: "TraceBot", headline: "Companion app", status: .idle),
    ], updatedAt: .now)
}

// MARK: Views

private func openURL(_ paneId: String?) -> URL {
    if let paneId, let encoded = paneId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        return URL(string: "herdr-ios://open?pane=\(encoded)")!
    }
    return URL(string: "herdr-ios://open")!
}

struct AgentsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AgentsEntry

    private var board: AgentBoard { entry.board }
    /// What a tap on a small widget should open: the most urgent agent.
    private var urgent: AgentBoard.Row? { board.rows.first { $0.status == .blocked || $0.status == .done } }

    var body: some View {
        if !entry.paired {
            unpaired
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: Text(summary)
            case .systemSmall: small
            case .systemLarge: list(limit: 7)
            default: list(limit: 3)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if board.needsYou > 0 { parts.append("\(board.needsYou) need\(board.needsYou == 1 ? "s" : "") you") }
        if board.working > 0 { parts.append("\(board.working) working") }
        if parts.isEmpty { parts.append(board.rows.isEmpty ? "No agents" : "All quiet") }
        return parts.joined(separator: " · ")
    }

    private var unpaired: some View {
        VStack(spacing: 4) {
            Image(systemName: "terminal")
            Text("Open Herdr to pair").font(.caption)
        }
        .widgetURL(openURL(nil))
    }

    // MARK: Lock screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: board.needsYou > 0 ? "checkmark.bubble.fill" : "ellipsis")
                    .font(.caption)
                Text("\(board.needsYou > 0 ? board.needsYou : board.working)")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        }
        .widgetURL(openURL(urgent?.paneId))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("herdr").font(.headline)
            Text(summary).font(.caption)
            if let top = urgent ?? board.rows.first {
                Text("\(top.kind) · \(top.workspace)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(openURL(urgent?.paneId))
    }

    // MARK: Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            countLine(board.needsYou, "need you", .green, symbol: AgentStatus.done.symbol)
            countLine(board.working, "working", .yellow, symbol: AgentStatus.working.symbol)
            countLine(board.rows.count - board.needsYou - board.working, "idle", .blue, symbol: AgentStatus.idle.symbol)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(openURL(urgent?.paneId))
    }

    private func countLine(_ n: Int, _ label: String, _ tint: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).font(.caption)
            Text("\(n)").font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .opacity(n == 0 ? 0.45 : 1)
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            if board.rows.isEmpty {
                Spacer()
                Text("No agents running").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(board.rows.prefix(limit)) { row in
                    Link(destination: openURL(row.paneId)) { AgentRowView(row: row) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal.fill").font(.caption).foregroundStyle(.tint)
            Text("herdr").font(.caption.weight(.semibold))
            if !entry.live, board.updatedAt > .distantPast {
                Text(board.updatedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AgentRowView: View {
    let row: AgentBoard.Row

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: row.status, size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(row.kind) · \(row.workspace)").font(.caption.weight(.semibold)).lineLimit(1)
                if !row.headline.isEmpty {
                    Text(row.headline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
