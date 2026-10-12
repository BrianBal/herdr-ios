import HerdrKit
import SwiftUI

/// Bottom input area: the terminal toolbar and a prompt field.
/// Agent panes get `agent.prompt`; shell panes get the text plus Enter.
struct ComposerBar: View {
    @Environment(HerdrStore.self) private var store
    let pane: Pane
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 8) {
            if pane.agentStatus == .blocked {
                Label("\(pane.displayAgent ?? pane.agent ?? "Agent") is waiting for you — answer with the keys below",
                      systemImage: "exclamationmark.bubble.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AgentStatus.blocked.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TerminalToolbar(paneId: pane.paneId,
                                mode: pane.agentStatus == .blocked ? .blockedAgent : pane.hasAgent ? .agent : .shell)
                SendButton(enabled: !trimmed.isEmpty && !sending && store.isConnected, action: send)
            }
            // Return inserts a new line (vertical TextField); sending is the ↑ button or ⌘Return.
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...8)
                .focused($focused)
                .submitLabel(.return)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var placeholder: String {
        if let agent = pane.displayAgent ?? pane.agent { return "Message \(agent)…" }
        return "Run a command…"
    }

    private func send() {
        let message = trimmed
        guard !message.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            if await store.submit(message, to: pane) { text = "" }
        }
    }
}

private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var sent = 0

    var body: some View {
        Button {
            sent += 1
            action()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(.black) : AnyShapeStyle(.tertiary))
                .frame(width: 34, height: 34)
                .background(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
        }
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send")
        .sensoryFeedback(.impact(weight: .medium), trigger: sent)
        .animation(.snappy(duration: 0.15), value: enabled)
    }
}
