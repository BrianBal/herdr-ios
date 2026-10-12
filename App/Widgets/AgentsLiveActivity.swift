import ActivityKit
import HerdrKit
import SwiftUI
import WidgetKit

/// The summary Live Activity on the Lock Screen and in the Dynamic Island.
/// The gateway pushes every change to it; see HerdrActivityAttributes.
struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HerdrActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, stale: context.isStale)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.url(for: context.state))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("herdr", systemImage: "terminal.fill").font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.summary).font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.agents.prefix(3), id: \.paneId) { ActivityAgentRow(agent: $0) }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                CompactCount(state: state)
            } compactTrailing: {
                if state.blocked > 0 && state.working > 0 {
                    Text("\(state.working)").foregroundStyle(.yellow).monospacedDigit()
                } else {
                    Image(systemName: "terminal.fill").foregroundStyle(.secondary)
                }
            } minimal: {
                CompactCount(state: state)
            }
            .widgetURL(Self.url(for: state))
        }
    }

    /// Opens the agent that most needs you.
    static func url(for state: HerdrActivityAttributes.ContentState) -> URL? {
        guard let top = state.agents.first,
              let pane = top.paneId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return URL(string: "herdr-ios://open")
        }
        return URL(string: "herdr-ios://open?pane=\(pane)")
    }
}

/// Green count when something needs you, otherwise the yellow working count.
private struct CompactCount: View {
    let state: HerdrActivityAttributes.ContentState

    var body: some View {
        let needsYou = state.blocked > 0
        HStack(spacing: 3) {
            Image(systemName: needsYou ? AgentStatus.blocked.symbol : AgentStatus.working.symbol)
            Text("\(needsYou ? state.blocked : state.working)").monospacedDigit()
        }
        .foregroundStyle(needsYou ? AgentStatus.blocked.tint : AgentStatus.working.tint)
    }
}

private struct LockScreenActivityView: View {
    let state: HerdrActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("herdr", systemImage: "terminal.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Text(stale ? "Not updating" : state.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(state.agents.prefix(3), id: \.paneId) { ActivityAgentRow(agent: $0) }
        }
        .foregroundStyle(.white)
    }
}

private struct ActivityAgentRow: View {
    let agent: HerdrActivityAttributes.ContentState.Agent

    var body: some View {
        let status = AgentStatus(rawValue: agent.status) ?? .unknown
        HStack(spacing: 8) {
            StatusIcon(status: status, size: 14)
            Text(agent.title).font(.caption.weight(.semibold)).lineLimit(1)
            if !agent.headline.isEmpty {
                Text(agent.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(status.label).font(.caption2).foregroundStyle(status.tint)
        }
    }
}
