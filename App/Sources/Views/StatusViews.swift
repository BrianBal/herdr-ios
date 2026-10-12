import HerdrKit
import SwiftUI

struct StatusPill: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            StatusIcon(status: status, size: 11)
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.14), in: Capsule())
    }
}

/// Thin banner shown under the nav bar whenever the socket isn't live.
struct ConnectionBanner: View {
    @Environment(HerdrStore.self) private var store
    @Environment(AppModel.self) private var app

    var body: some View {
        switch store.phase {
        case .connected, .idle:
            EmptyView()
        case .connecting:
            banner(icon: nil, text: "Connecting…", tint: .secondary)
        case .waiting(let retryAt, let message):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secs = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                banner(icon: "wifi.exclamationmark",
                       text: secs > 0 ? "\(message) Retrying in \(secs)s" : message,
                       tint: .red, action: ("Retry", { store.reconnectNow() }))
            }
        case .unauthorized(let message):
            banner(icon: "lock.trianglebadge.exclamationmark", text: message, tint: .red,
                   action: ("Re-pair", { app.unpair() }))
        }
    }

    private func banner(icon: String?, text: String, tint: Color, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) } else { ProgressView().controlSize(.small) }
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
