import HerdrKit
import SwiftUI

/// A key or chord sent with herdr's logical key syntax (`ctrl+c`, `shift+tab`, …).
struct TermKey: Identifiable {
    let id: String
    let label: String
    let keys: [String]
    var symbol: String? = nil
    var spoken: String? = nil
    /// Auto-repeats while held (arrows, backspace).
    var repeats = false

    static func ctrl(_ letter: Character, _ spoken: String) -> TermKey {
        TermKey(id: "ctrl+\(letter)", label: "⌃\(letter.uppercased())", keys: ["ctrl+\(letter)"],
                spoken: "Control \(letter.uppercased()), \(spoken)")
    }
}

private struct KeyGroup: Identifiable {
    let id: String
    let keys: [TermKey]
    var emphasized = false
}

/// Horizontally scrolling bar of common terminal keys and control combos,
/// ordered for what's in the pane so the likeliest keys are on screen.
struct TerminalToolbar: View {
    enum Mode {
        case shell, agent, blockedAgent
    }

    @Environment(HerdrStore.self) private var store
    let paneId: String
    let mode: Mode
    @State private var showCtrlGrid = false
    @State private var overflow = Overflow()

    private struct Overflow: Equatable {
        var leading = false
        var trailing = false
    }

    private static let fadeWidth: CGFloat = 28

    private static let core = KeyGroup(id: "core", keys: [
        TermKey(id: "esc", label: "esc", keys: ["esc"], spoken: "Escape"),
        .ctrl("c", "interrupt"),
    ])
    private static let job = KeyGroup(id: "job", keys: [
        .ctrl("d", "end of input"), .ctrl("z", "suspend"), .ctrl("l", "clear screen"), .ctrl("r", "search history"),
    ])
    private static let nav = KeyGroup(id: "nav", keys: [
        TermKey(id: "left", label: "left", keys: ["left"], symbol: "arrow.left", spoken: "Left", repeats: true),
        TermKey(id: "down", label: "down", keys: ["down"], symbol: "arrow.down", spoken: "Down", repeats: true),
        TermKey(id: "up", label: "up", keys: ["up"], symbol: "arrow.up", spoken: "Up", repeats: true),
        TermKey(id: "right", label: "right", keys: ["right"], symbol: "arrow.right", spoken: "Right", repeats: true),
        TermKey(id: "enter", label: "enter", keys: ["enter"], symbol: "return", spoken: "Return"),
    ])
    private static let tabs = KeyGroup(id: "tabs", keys: [
        TermKey(id: "shift+tab", label: "⇧tab", keys: ["shift+tab"], symbol: "arrow.left.to.line", spoken: "Shift Tab"),
        TermKey(id: "tab", label: "tab", keys: ["tab"], symbol: "arrow.right.to.line", spoken: "Tab"),
    ])
    private static let line = KeyGroup(id: "line", keys: [
        .ctrl("a", "line start"), .ctrl("e", "line end"), .ctrl("u", "delete to start"),
        .ctrl("k", "delete to end"), .ctrl("w", "delete word"),
        TermKey(id: "backspace", label: "⌫", keys: ["backspace"], symbol: "delete.left", spoken: "Backspace", repeats: true),
    ])
    private static func answers(emphasized: Bool) -> KeyGroup {
        KeyGroup(id: "answers", keys: ["1", "2", "3", "y", "n"].map {
            TermKey(id: "answer-\($0)", label: $0, keys: [$0], spoken: $0)
        }, emphasized: emphasized)
    }

    private var groups: [KeyGroup] {
        switch mode {
        case .shell: [Self.core, Self.job, Self.nav, Self.tabs, Self.line, Self.answers(emphasized: false)]
        case .agent: [Self.core, Self.tabs, Self.nav, Self.answers(emphasized: false), Self.job, Self.line]
        case .blockedAgent: [Self.answers(emphasized: true), Self.core, Self.nav, Self.tabs, Self.job, Self.line]
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Rectangle().fill(.separator).frame(width: 1, height: 22).padding(.horizontal, 2)
                    }
                    ForEach(group.keys) { key in
                        KeyCap(key: key, emphasized: group.emphasized) { store.press(key.keys, paneId: paneId) }
                    }
                }
                Rectangle().fill(.separator).frame(width: 1, height: 22).padding(.horizontal, 2)
                Button { showCtrlGrid = true } label: {
                    Text("⌃…").font(.footnote.monospaced().weight(.semibold))
                }
                .buttonStyle(KeyCapStyle(emphasized: false))
                .accessibilityLabel("More control keys")
                .popover(isPresented: $showCtrlGrid) {
                    CtrlGrid { letter in
                        showCtrlGrid = false
                        store.press(["ctrl+\(letter)"], paneId: paneId)
                    }
                    .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.horizontal, 1)
        }
        .onScrollGeometryChange(for: Overflow.self) { geo in
            Overflow(leading: geo.visibleRect.minX > 1, trailing: geo.visibleRect.maxX < geo.contentSize.width - 1)
        } action: { _, new in
            withAnimation(.easeOut(duration: 0.15)) { overflow = new }
        }
        // Fade an edge only while keys continue past it, so the last key on
        // screen doesn't look disabled when there's nothing more to scroll to.
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: overflow.leading ? Self.fadeWidth : 0)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: overflow.trailing ? Self.fadeWidth : 0)
            }
        }
        .disabled(!store.isConnected)
        .animation(.snappy, value: mode)
    }
}

private struct KeyCap: View {
    let key: TermKey
    let emphasized: Bool
    let send: () -> Void
    @State private var repeatTask: Task<Void, Never>?
    @State private var taps = 0

    var body: some View {
        let button = Button {
            taps += 1
            send()
        } label: {
            if let symbol = key.symbol {
                Image(systemName: symbol).font(.footnote.weight(.semibold))
            } else {
                Text(key.label).font(.footnote.monospaced().weight(.semibold))
            }
        }
        .buttonStyle(KeyCapStyle(emphasized: emphasized))
        .accessibilityLabel(key.spoken ?? key.label)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: taps)

        if key.repeats {
            button.onLongPressGesture(minimumDuration: 0.35, maximumDistance: 24) {
                repeatTask?.cancel()
                repeatTask = Task {
                    while !Task.isCancelled {
                        send()
                        try? await Task.sleep(for: .milliseconds(75))
                    }
                }
            } onPressingChanged: { pressing in
                if !pressing {
                    repeatTask?.cancel()
                    repeatTask = nil
                }
            }
            .onDisappear { repeatTask?.cancel() }
        } else {
            button
        }
    }
}

struct KeyCapStyle: ButtonStyle {
    let emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(emphasized ? AnyShapeStyle(AgentStatus.blocked.tint) : AnyShapeStyle(.primary))
            .frame(minWidth: 36, minHeight: 34)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(emphasized ? AnyShapeStyle(AgentStatus.blocked.tint.opacity(0.22)) : AnyShapeStyle(.quaternary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.35 : 0), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Every Ctrl+letter chord, for the ones not on the bar.
private struct CtrlGrid: View {
    let onPick: (Character) -> Void
    private let letters = Array("abcdefghijklmnopqrstuvwxyz")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Control +").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 7), spacing: 6) {
                ForEach(letters, id: \.self) { letter in
                    Button { onPick(letter) } label: {
                        Text("⌃\(letter.uppercased())").font(.footnote.monospaced().weight(.semibold))
                    }
                    .buttonStyle(KeyCapStyle(emphasized: false))
                    .accessibilityLabel("Control \(letter.uppercased())")
                }
            }
        }
        .padding(14)
    }
}
