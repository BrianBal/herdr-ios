import HerdrKit
import SwiftUI

/// Every workspace on every paired machine as a card, like Safari's tab
/// overview: grouped by machine, each card a small live picture of its pane.
/// Tap one to open it; the open workspace's tabs button comes back here.
struct TabsView: View {
    @Environment(AppModel.self) private var app
    /// The workspace that was open, which Done goes back to.
    let current: Route?
    let open: (Route) -> Void
    @State private var showSettings = false
    @State private var addingMachine = false
    @State private var newWorkspaceOn: String?
    @State private var renaming: WorkspaceRef?
    @State private var renameText = ""
    @State private var closing: WorkspaceRef?
    @State private var closingGroup: WorkspaceRef?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(app.gateways) { g in
                    if let store = app.store(g.id) {
                        MachineSection(gateway: g, store: store, current: current, open: open,
                                       rename: { startRename($0) }, close: { closing = $0 })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await withTaskGroup(of: Void.self) { group in
                for store in app.orderedStores {
                    group.addTask { await store.refresh(); await store.refreshPreviews() }
                }
            }
        }
        // Previews stay current while the overview is on screen, and stop when a tab opens.
        .task {
            while !Task.isCancelled {
                await withTaskGroup(of: Void.self) { group in
                    for store in app.orderedStores { group.addTask { await store.refreshPreviews() } }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .navigationTitle("Tabs")
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { newWorkspaceButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Done") { if let back = doneRoute { open(back) } }
                    .fontWeight(.semibold)
                    .disabled(doneRoute == nil)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $addingMachine) { PairView(onPaired: { addingMachine = false }) }
        .sheet(item: Binding(get: { newWorkspaceOn.map(SheetID.init) }, set: { newWorkspaceOn = $0?.id })) { item in
            if let store = app.store(item.id) {
                NewWorkspaceSheet { label, cwd, agent, prompt in
                    guard let created = await store.createWorkspace(label: label, cwd: cwd) else { return false }
                    open(Route(gatewayId: store.gatewayId, workspaceId: created.workspaceId, paneId: created.paneId))
                    if let agent {
                        // Runs on after the sheet closes; progress shows in the workspace itself.
                        let hint = label ?? cwd.map { ($0 as NSString).lastPathComponent } ?? agent
                        Task { await store.startAgent(agent, in: created.paneId, nameHint: hint, prompt: prompt) }
                    }
                    return true
                }
                .environment(store)
            }
        }
        .alert("Rename Workspace", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let ref = renaming, !name.isEmpty, name != ref.workspace.label {
                    Task { await app.store(ref.gatewayId)?.renameWorkspace(ref.workspace.workspaceId, to: name) }
                }
            }
        }
        .confirmationDialog(closing.map { "Close “\($0.workspace.label)”?" } ?? "",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { ref in
            Button("Close Workspace", role: .destructive) { close(ref, group: false) }
        } message: { ref in
            Text(closeMessage(ref))
        }
        .confirmationDialog(closingGroup.map { "“\($0.workspace.label)” has worktree workspaces" } ?? "",
                            isPresented: Binding(get: { closingGroup != nil }, set: { if !$0 { closingGroup = nil } }),
                            titleVisibility: .visible, presenting: closingGroup) { ref in
            Button("Close All", role: .destructive) { close(ref, group: true) }
        } message: { _ in
            Text("herdr closes a worktree's primary workspace together with its linked worktree workspaces.")
        }
    }

    /// Where Done goes: the workspace that was open, if it's still there.
    private var doneRoute: Route? {
        guard let current, let store = app.store(current.gatewayId),
              store.snapshot?.workspace(current.workspaceId) != nil else { return nil }
        return Route(gatewayId: current.gatewayId, workspaceId: current.workspaceId,
                     paneId: store.previewPane(of: current.workspaceId))
    }

    /// One machine: new workspace there. Several: pick which.
    @ViewBuilder
    private var newWorkspaceButton: some View {
        let online = app.orderedStores.filter(\.isConnected)
        if app.gateways.count > 1 {
            Menu {
                Section("New workspace on") {
                    ForEach(app.gateways) { g in
                        Button(g.name) { newWorkspaceOn = g.id }
                            .disabled(app.store(g.id)?.isConnected != true)
                    }
                }
                Button { addingMachine = true } label: { Label("Add Machine…", systemImage: "desktopcomputer") }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New workspace")
        } else {
            Button { newWorkspaceOn = online.first?.gatewayId } label: { Image(systemName: "plus") }
                .accessibilityLabel("New workspace")
                .disabled(online.isEmpty)
        }
    }

    private func startRename(_ ref: WorkspaceRef) {
        renameText = ref.workspace.label
        renaming = ref
    }

    private func close(_ ref: WorkspaceRef, group: Bool) {
        Task {
            if await app.store(ref.gatewayId)?.closeWorkspace(ref.workspace.workspaceId, group: group) == .needsGroup {
                closingGroup = ref
            }
        }
    }

    private func closeMessage(_ ref: WorkspaceRef) -> String {
        let ws = ref.workspace
        let panes = ws.paneCount == 1 ? "its pane" : "all \(ws.paneCount) panes"
        let agents = app.store(ref.gatewayId)?.snapshot?.agents(in: ws.workspaceId).count ?? 0
        let agentNote = agents == 0 ? "" : agents == 1 ? ", including a running agent" : ", including \(agents) running agents"
        return "This ends \(panes) on \(app.name(of: ref.gatewayId))\(agentNote)."
    }

    private struct SheetID: Identifiable {
        let id: String
    }
}

/// A workspace on a particular machine (ids repeat across machines).
struct WorkspaceRef: Equatable {
    let gatewayId: String
    let workspace: Workspace
}

/// Identifies a tab across machines.
struct TabKey: Hashable {
    let gatewayId: String
    let workspaceId: String
}

/// One machine's header and its cards. Offline, the cards it last had stay,
/// dimmed, with when it was last seen.
private struct MachineSection: View {
    let gateway: SavedGateway
    let store: HerdrStore
    let current: Route?
    let open: (Route) -> Void
    let rename: (WorkspaceRef) -> Void
    let close: (WorkspaceRef) -> Void
    @State private var repairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let s = store.snapshot {
                if s.workspaces.isEmpty {
                    Text("No workspaces").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(s.sortedWorkspaces) { ws in card(ws, in: s) }
                }
            }
        }
        .sheet(isPresented: $repairing) { PairView(onPaired: { repairing = false }) }
    }

    private func card(_ ws: Workspace, in s: SessionSnapshot) -> some View {
        let paneId = store.previewPane(of: ws.workspaceId)
        let key = TabKey(gatewayId: gateway.id, workspaceId: ws.workspaceId)
        let ref = WorkspaceRef(gatewayId: gateway.id, workspace: ws)
        return Button {
            open(Route(gatewayId: gateway.id, workspaceId: ws.workspaceId, paneId: paneId))
        } label: {
            TabCard(workspace: ws, agents: s.agents(in: ws.workspaceId), pane: paneId.flatMap(s.pane),
                    screen: paneId.flatMap { store.previews[$0] }, offline: store.isOffline,
                    isCurrent: current.map { TabKey(gatewayId: $0.gatewayId, workspaceId: $0.workspaceId) } == key)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { rename(ref) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { close(ref) } label: { Label("Close Workspace", systemImage: "xmark") }
        }
        .disabled(!store.isConnected && store.snapshot == nil)
        .accessibilityIdentifier("tab-\(gateway.id)-\(ws.workspaceId)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(gateway.name).font(.title3.weight(.semibold))
            status
            Spacer(minLength: 0)
            let working = store.snapshot?.agents.filter { $0.agentStatus == .working }.count ?? 0
            if working > 0, store.isConnected {
                Text("\(working) working")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AgentStatus.working.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AgentStatus.working.tint.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch store.phase {
        case .connected:
            if let latency = store.latency {
                let ms = Int((latency / .milliseconds(1)).rounded())
                Text("\(ms)ms").font(.caption.monospacedDigit())
                    .foregroundStyle(ms < 150 ? Color.green : ms < 500 ? Color.yellow : Color.red)
            }
        case .connecting, .idle:
            if store.snapshot == nil {
                ProgressView().controlSize(.mini)
            }
        case .waiting:
            offlineLabel
        case .unauthorized:
            Button("Token refused · Re-pair") { repairing = true }
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }

    private var offlineLabel: some View {
        Group {
            if let seen = store.lastSeen {
                Text("Offline · last seen \(seen, format: .relative(presentation: .named))")
            } else {
                Text("Offline")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A workspace as a card: its pane's screen in miniature, with its name, the
/// agent and its status over the bottom. A badge counts agents that are done
/// or waiting on you.
struct TabCard: View {
    let workspace: Workspace
    let agents: [Agent]
    let pane: Pane?
    let screen: String?
    let offline: Bool
    let isCurrent: Bool

    static let radius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        ZStack(alignment: .bottom) {
            TerminalRenderer.background
            MiniScreen(text: screen ?? "")
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 52)
            caption
        }
        .aspectRatio(0.74, contentMode: .fit)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.08)),
                               lineWidth: isCurrent ? 3 : 1)
        }
        .overlay(alignment: .topTrailing) { badge.padding(8) }
        .saturation(offline ? 0 : 1)
        .opacity(offline ? 0.6 : 1)
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var lead: Agent? { agents.min { $0.agentStatus.priority < $1.agentStatus.priority } }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let lead { StatusIcon(status: lead.agentStatus, size: 11) }
                Text(workspace.label).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let lead {
            parts.append(lead.headline == lead.kindLabel || lead.headline == workspace.label
                         ? "\(lead.kindLabel) · \(lead.agentStatus.label)" : lead.headline)
        } else if let pane {
            parts.append(pane.displayTitle)
        }
        if workspace.paneCount > 1 { parts.append("\(workspace.paneCount) panes") }
        return parts.joined(separator: " · ")
    }

    /// Agents that need you: blocked first, then done.
    private var waiting: [Agent] { agents.filter { $0.agentStatus == .blocked || $0.agentStatus == .done } }

    @ViewBuilder
    private var badge: some View {
        let waiting = waiting
        if let top = waiting.min(by: { $0.agentStatus.priority < $1.agentStatus.priority }) {
            HStack(spacing: 3) {
                StatusIcon(status: top.agentStatus, size: 11)
                if waiting.count > 1 { Text("\(waiting.count)").font(.caption2.bold().monospacedDigit()) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(top.agentStatus.tint.opacity(0.85), in: Capsule())
            .shadow(color: top.agentStatus.tint.opacity(0.6), radius: 6)
        }
    }

    private var accessibilityText: String {
        var text = "\(workspace.label), \(subtitle)"
        if !waiting.isEmpty { text += ", \(waiting.count) need you" }
        if offline { text += ", offline" }
        return text
    }
}

/// A pane's screen shrunk to fit: the latest rows at the bottom, as wide as
/// its longest line (within reason) so a card reads like a thumbnail.
private struct MiniScreen: View {
    let text: String

    private static let fontSize: CGFloat = 10

    var body: some View {
        let lines = Self.lines(text)
        let cols = min(100, max(36, lines.map(\.plainText.count).max() ?? 0))
        let rendered = TerminalRenderer.render(lines.map { $0.clipped(to: cols) }, fontSize: Self.fontSize)
        GeometryReader { geo in
            let scale = geo.size.width / (CGFloat(cols) * Self.fontSize * 0.602)
            Text(rendered)
                .lineLimit(nil)
                .fixedSize()
                .scaleEffect(scale, anchor: .bottomLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// The screen without the blank rows below its output.
    private static func lines(_ text: String) -> [StyledLine] {
        var lines = ANSIParser.parse(text)
        while let last = lines.last, last.plainText.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines
    }
}

/// Opens the tabs overview, like Safari's: the number of workspaces across
/// every machine, and a dot in the status color when an agent in another one
/// is done or waiting on you.
struct TabsButton: View {
    @Environment(AppModel.self) private var app
    let gatewayId: String
    let workspaceId: String
    var hit: CGSize? = nil
    let action: () -> Void

    var body: some View {
        let count = app.orderedStores.reduce(0) { $0 + ($1.snapshot?.workspaces.count ?? 0) }
        let elsewhere = app.orderedStores.flatMap { store in
            (store.snapshot?.agents ?? []).filter {
                ($0.agentStatus == .blocked || $0.agentStatus == .done)
                    && !(store.gatewayId == gatewayId && $0.workspaceId == workspaceId)
            }
        }
        let top = elsewhere.min { $0.agentStatus.priority < $1.agentStatus.priority }
        Button(action: action) {
            Image(systemName: (1...50).contains(count) ? "\(count).square" : "square.on.square")
                .frame(width: hit?.width, height: hit?.height)
                .contentShape(.rect)
                .overlay(alignment: .topTrailing) {
                    if let top {
                        Circle().fill(top.agentStatus.tint)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                            .offset(x: hit == nil ? 4 : -6, y: hit == nil ? -4 : 4)
                    }
                }
        }
        .keyboardShortcut("\\", modifiers: [.command, .shift])
        .accessibilityLabel(top == nil ? "Tabs" : "Tabs, \(elsewhere.count) need you")
        .accessibilityIdentifier("tabs-button")
    }
}
