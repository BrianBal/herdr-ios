import HerdrKit
import SwiftUI

/// Status colors and symbols, shared by the app and the widgets.
extension AgentStatus {
    var label: String {
        switch self {
        case .blocked: "Needs input"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "Unknown"
        }
    }

    /// Green: it's your turn (finished, or waiting on you). Yellow: working.
    /// Blue: everything else. Red is kept for errors.
    var tint: Color {
        switch self {
        case .blocked, .done: .green
        case .working: .yellow
        case .idle, .unknown: .blue
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle.fill"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

struct StatusIcon: View {
    let status: AgentStatus
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(status.tint)
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: status == .working)
            .accessibilityLabel(status.label)
    }
}

extension HerdrActivityAttributes.ContentState {
    /// The same summary the gateway pushes, built from a local snapshot.
    init(board: AgentBoard) {
        working = board.working
        blocked = board.blocked
        done = board.done
        agents = board.rows.prefix(4).map {
            Agent(paneId: $0.paneId, title: $0.workspace.isEmpty ? $0.kind : "\($0.kind) · \($0.workspace)",
                  headline: $0.headline, status: $0.status.rawValue)
        }
    }
}
