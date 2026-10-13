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
    @State private var completions: ShellCompletions?
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
                           sending: sending, action: send)
            }
            if pane.agentStatus != .blocked {
                QuickPromptBar(kind: pane.hasAgent ? .agent : .shell, draft: trimmed,
                               completions: currentCompletions,
                               enabled: store.isConnected && !sending) { candidate in
                    text = ShellCompletions.apply(candidate, to: text, replacing: completions?.word ?? "")
                    focused = true
                } send: { prompt in
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
        .onChange(of: text) { _, new in
            // The keyboard's smart dashes and quotes ("--" → "—") break commands and flags.
            let plain = ShellInput.plain(new)
            if plain != new { text = plain }
        }
        .task(id: pane.hasAgent ? nil : text) { await complete() }
    }

    /// Asks the gateway to complete the shell line's last word, shortly after typing pauses.
    private func complete() async {
        guard !pane.hasAgent, !text.isEmpty, !text.contains("\n") else {
            completions = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }
        let line = text
        let found = await store.completions(for: pane.paneId, line: line)
        if !Task.isCancelled { completions = found }
    }

    /// Completions that still fit what's in the field.
    private var currentCompletions: [String] {
        guard let completions, !text.isEmpty, text.hasSuffix(completions.word) else { return [] }
        return completions.candidates
    }

    private var field: some View {
        // Return inserts a new line (vertical TextField); sending is the ↑ button or ⌘Return.
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...8)
            .focused($focused)
            .accessibilityIdentifier("composer-field")
            .submitLabel(.return)
            // Prose for agents; commands for shells, where "Echo" breaks things. No
            // autocorrect for either: it rewrites flags, paths and code names.
            .textInputAutocapitalization(pane.hasAgent ? .sentences : .never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var placeholder: String {
        if let agent = pane.displayAgent ?? pane.agent { return "Message \(agent)…" }
        return "Run a command…"
    }

    /// Empties the field right away (a slow send shouldn't look like it didn't
    /// go) and puts the message back if it fails.
    private func send() {
        let message = trimmed
        let sentAttachments = attachments
        guard !message.isEmpty || !sentAttachments.isEmpty else { return }
        sending = true
        clear(sent: message)
        attachments = []
        Task {
            defer { sending = false }
            if await !store.submit(message, photos: sentAttachments.map(\.jpeg), to: pane) {
                if trimmed.isEmpty { text = message }
                if attachments.isEmpty { attachments = sentAttachments }
            }
        }
    }

    /// The keyboard can write a word it was still composing (autocorrect,
    /// inline prediction, dictation) back into the field just after it's
    /// emptied. Watch briefly and drop anything that's the tail of what was sent.
    private func clear(sent: String) {
        text = ""
        Task {
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(50))
                let back = trimmed
                if !back.isEmpty, sent.contains(back) { text = "" }
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
    /// While a send is in flight (photos take a moment): progress instead of the arrow.
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
/// (it moves into the composer) or remove it. Shell panes put tab
/// completions for the word being typed first; tapping one fills it in.
private struct QuickPromptBar: View {
    @Environment(AppModel.self) private var app
    let kind: QuickPrompts.Kind
    let draft: String
    var completions: [String] = []
    let enabled: Bool
    let complete: (String) -> Void
    let send: (String) -> Void
    let onEdit: (String) -> Void
    @State private var sent = 0

    var body: some View {
        let prompts = app.quickPrompts.list(kind)
        let canSave = !draft.isEmpty && !prompts.contains(draft) && !draft.contains("\n")
        if !prompts.isEmpty || canSave || !completions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(completions, id: \.self) { candidate in
                        Button { complete(candidate) } label: {
                            Text(candidate)
                                .font(.footnote.monospaced().weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .overlay(Capsule().strokeBorder(.tint.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Complete \(candidate)")
                    }
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
