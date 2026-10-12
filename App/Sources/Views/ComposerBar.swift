import HerdrKit
import SwiftUI

/// Bottom input area: the terminal toolbar and a prompt field.
/// Agent panes get `agent.prompt`; shell panes get the text plus Enter.
/// Agents can also be sent photos (see HerdrStore.submit(_:photos:to:)).
struct ComposerBar: View {
    @Environment(HerdrStore.self) private var store
    @Environment(AppModel.self) private var app
    let pane: Pane
    @State private var text = ""
    @State private var sending = false
    @State private var attachments: [PhotoAttachment] = []
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
                SendButton(enabled: (!trimmed.isEmpty || !attachments.isEmpty) && !sending && store.isConnected,
                           sending: sending && !attachments.isEmpty, action: send)
            }
            if pane.agentStatus != .blocked {
                QuickPromptBar(kind: pane.hasAgent ? .agent : .shell, draft: trimmed,
                               enabled: store.isConnected && !sending) { prompt in
                    sendNow(prompt)
                } onEdit: { prompt in
                    text = prompt
                    focused = true
                }
            }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if pane.hasAgent {
                    AttachPhotoButton(attachments: $attachments)
                        .disabled(sending)
                }
                field
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var field: some View {
        // Return inserts a new line (vertical TextField); sending is the ↑ button or ⌘Return.
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...8)
            .focused($focused)
            .submitLabel(.return)
            // Prose for agents; commands for shells, where "Echo" or an autocorrected flag breaks things.
            .textInputAutocapitalization(pane.hasAgent ? .sentences : .never)
            .autocorrectionDisabled(!pane.hasAgent)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholder: String {
        if let agent = pane.displayAgent ?? pane.agent { return "Message \(agent)…" }
        return "Run a command…"
    }

    private func send() {
        let message = trimmed
        let photos = attachments.map(\.jpeg)
        guard !message.isEmpty || !photos.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            if await store.submit(message, photos: photos, to: pane) {
                text = ""
                attachments = []
            }
        }
    }

    /// A quick prompt goes straight out; whatever's being typed stays put.
    private func sendNow(_ prompt: String) {
        sending = true
        Task {
            defer { sending = false }
            await store.submit(prompt, to: pane)
        }
    }
}

private struct SendButton: View {
    let enabled: Bool
    /// Uploading photos takes a moment; show progress instead of the arrow.
    var sending = false
    let action: () -> Void
    @State private var sent = 0

    var body: some View {
        Button {
            sent += 1
            action()
        } label: {
            Group {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(enabled ? AnyShapeStyle(.black) : AnyShapeStyle(.tertiary))
                }
            }
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

/// Chips for the saved quick prompts; tap to send. With text in the
/// composer, a "+" chip saves it as a new one. Long-press a chip to edit it
/// (it moves into the composer) or remove it.
private struct QuickPromptBar: View {
    @Environment(AppModel.self) private var app
    let kind: QuickPrompts.Kind
    let draft: String
    let enabled: Bool
    let send: (String) -> Void
    let onEdit: (String) -> Void
    @State private var sent = 0

    var body: some View {
        let prompts = app.quickPrompts.list(kind)
        let canSave = !draft.isEmpty && !prompts.contains(draft) && !draft.contains("\n")
        if !prompts.isEmpty || canSave {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(prompts, id: \.self) { prompt in
                        Button {
                            sent += 1
                            send(prompt)
                        } label: {
                            Text(prompt)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("Send \(prompt)")
                        .contextMenu {
                            Button { onEdit(prompt); app.quickPrompts.remove(prompt, from: kind) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) { app.quickPrompts.remove(prompt, from: kind) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    if canSave {
                        Button { app.quickPrompts.add(draft, to: kind) } label: {
                            Label("Save", systemImage: "plus")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Save as quick prompt")
                    }
                }
                .padding(.horizontal, 1)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
        }
    }
}
