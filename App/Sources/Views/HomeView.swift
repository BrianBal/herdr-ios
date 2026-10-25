import HerdrKit
import SwiftUI

/// Counterpart of herdr's sidebar: what needs attention, then workspaces.
/// On iPhone it's the root of the navigation stack. In regular width it's the
/// split view's sidebar, and herdr's agents panel becomes a section of it
/// rather than a sheet.
struct HomeView: View {
    @Environment(HerdrStore.self) private var store
    @Environment(AppModel.self) private var app
    @Binding var showAgents: Bool
    var sidebarSelection: Binding<Route?>? = nil
    /// Opens a workspace (used after creating one).
    var open: (Route) -> Void = { _ in }
    @State private var showSettings = false
    @State private var showNewWorkspace = false
    @State private var renaming: Workspace?
    @State private var renameText = ""
    @State private var closing: Workspace?
    @State private var closingGroup: Workspace?

    var body: some View {
        Group {
            if let snapshot = store.snapshot {
                list(snapshot)
            } else {
                ContentUnavailableView {
                    Label("Connecting to herdr", systemImage: "terminal")
                } description: {
                    Text(store.endpoint?.displayHost ?? "")
                }
            }
        }
        .navigationTitle(isGrid ? app.activeGateway?.name ?? "herdr" : app.gateways.count > 1 ? app.activeGateway?.name ?? "herdr" : "herdr")
        // On iPhone the title is the gateway pill; in the sidebar, with more than
        // one gateway, an inline title menu (a large title hides that it's a menu).
        .navigationBarTitleDisplayMode(isGrid || app.gateways.count > 1 ? .inline : .automatic)
        // Even an empty title menu shows its chevron, so it's only there with something to pick.
        .modifier(TitleMenu(enabled: isGrid || app.gateways.count > 1) {
            gatewayMenuItems
            if isGrid {
                Divider()
                Button { showSettings = true } label: { Label("Manage Gateways…", systemImage: "gearshape") }
            }
        })
        .modifier(LatencySubtitle(enabled: isGrid))
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewWorkspace = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New workspace")
                    .disabled(!store.isConnected)
            }
            if sidebarSelection == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    AgentsButton(showAgents: $showAgents)
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNewWorkspace) {
            NewWorkspaceSheet { label, cwd, agent, prompt in
                guard let created = await store.createWorkspace(label: label, cwd: cwd) else { return false }
                open(.workspace(created.workspaceId, pane: created.paneId))
                if let agent {
                    // Runs on after the sheet closes; progress shows in the workspace itself.
                    let hint = label ?? cwd.map { ($0 as NSString).lastPathComponent } ?? agent
                    Task { await store.startAgent(agent, in: created.paneId, nameHint: hint, prompt: prompt) }
                }
                return true
            }
        }
        .alert("Rename Workspace", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let ws = renaming, !name.isEmpty, name != ws.label {
                    Task { await store.renameWorkspace(ws.workspaceId, to: name) }
                }
            }
        }
        .confirmationDialog(closing.map { "Close “\($0.label)”?" } ?? "",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { ws in
            Button("Close Workspace", role: .destructive) { close(ws, group: false) }
        } message: { ws in
            Text(closeMessage(ws))
        }
        .confirmationDialog(closingGroup.map { "“\($0.label)” has worktree workspaces" } ?? "",
                            isPresented: Binding(get: { closingGroup != nil }, set: { if !$0 { closingGroup = nil } }),
                            titleVisibility: .visible, presenting: closingGroup) { ws in
            Button("Close All", role: .destructive) { close(ws, group: true) }
        } message: { _ in
            Text("herdr closes a worktree's primary workspace together with its linked worktree workspaces.")
        }
    }

    /// iPhone: cards and a grid of workspace tiles. The split view's sidebar keeps the list.
    private var isGrid: Bool { sidebarSelection == nil }

    @ViewBuilder
    private var gatewayMenuItems: some View {
        ForEach(app.gateways) { g in
            Button { app.switchTo(g.id) } label: {
                if g.id == app.activeId { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
            }
        }
    }

    private func startRename(_ ws: Workspace) {
        renameText = ws.label
        renaming = ws
    }

    private func close(_ ws: Workspace, group: Bool) {
        Task {
            if await store.closeWorkspace(ws.workspaceId, group: group) == .needsGroup { closingGroup = ws }
        }
    }

    private func closeMessage(_ ws: Workspace) -> String {
        let panes = ws.paneCount == 1 ? "its pane" : "all \(ws.paneCount) panes"
        let agents = store.snapshot?.agents(in: ws.workspaceId).count ?? 0
        let agentNote = agents == 0 ? "" : agents == 1 ? ", including a running agent" : ", including \(agents) running agents"
        return "This ends \(panes) on your Mac\(agentNote)."
    }

    @ViewBuilder
    private func list(_ s: SessionSnapshot) -> some View {
        if let sidebarSelection {
            List(selection: sidebarSelection) { sections(s) }
                .listStyle(.sidebar)
                .refreshable { await store.refresh() }
        } else {
            ScrollView { grid(s) }
                .background(Color(.systemBackground))
                .refreshable { await store.refresh() }
        }
    }

    private func grid(_ s: SessionSnapshot) -> some View {
        let attention = s.agents
            .filter { $0.agentStatus == .blocked || $0.agentStatus == .done }
            .sorted { ($0.agentStatus.priority, $0.workspaceId) < ($1.agentStatus.priority, $1.workspaceId) }
        let working = s.agents.filter { $0.agentStatus == .working }.count
        return VStack(alignment: .leading, spacing: 14) {
            if !attention.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(attention[0].agentStatus.tint).frame(width: 8, height: 8)
                    Text("Needs you")
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                ForEach(attention) { agent in
                    NavigationLink(value: Route.workspace(agent.workspaceId, pane: agent.paneId)) {
                        AttentionCard(agent: agent, workspaceLabel: s.workspace(agent.workspaceId)?.label)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Workspaces")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if working > 0 {
                    Text("\(working) working")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AgentStatus.working.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(AgentStatus.working.tint.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, attention.isEmpty ? 0 : 12)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(s.sortedWorkspaces) { ws in
                    NavigationLink(value: Route.workspace(ws.workspaceId, pane: nil)) {
                        WorkspaceTile(workspace: ws, agents: s.agents(in: ws.workspaceId))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { startRename(ws) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { closing = ws } label: { Label("Close Workspace", systemImage: "xmark") }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .animation(.default, value: attention.map(\.id))
    }

    @ViewBuilder
    private func sections(_ s: SessionSnapshot) -> some View {
        let attention = s.agents
            .filter { $0.agentStatus == .blocked || $0.agentStatus == .done }
            .sorted { ($0.agentStatus.priority, $0.workspaceId) < ($1.agentStatus.priority, $1.workspaceId) }
        Group {
            if !attention.isEmpty {
                Section("Needs you") {
                    ForEach(attention) { agent in
                        NavigationLink(value: Route.workspace(agent.workspaceId, pane: agent.paneId)) {
                            AgentRow(agent: agent, workspaceLabel: s.workspace(agent.workspaceId)?.label)
                        }
                    }
                }
            }
            Section("Workspaces") {
                ForEach(s.sortedWorkspaces) { ws in
                    NavigationLink(value: Route.workspace(ws.workspaceId, pane: nil)) {
                        WorkspaceRow(workspace: ws, agents: s.agents(in: ws.workspaceId))
                    }
                    .swipeActions(edge: .trailing) {
                        Button { closing = ws } label: { Label("Close", systemImage: "xmark") }
                            .tint(.red)
                        Button { startRename(ws) } label: { Label("Rename", systemImage: "pencil") }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button { startRename(ws) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { closing = ws } label: { Label("Close Workspace", systemImage: "xmark") }
                    }
                }
            }
            // The agents panel, minus the ones already listed under "Needs you".
            let others = s.agents
                .filter { $0.agentStatus != .blocked && $0.agentStatus != .done }
                .sorted { ($0.agentStatus.priority, $0.workspaceId) < ($1.agentStatus.priority, $1.workspaceId) }
            if sidebarSelection != nil, !others.isEmpty {
                Section("Agents") {
                    ForEach(others) { agent in
                        NavigationLink(value: Route.workspace(agent.workspaceId, pane: agent.paneId)) {
                            AgentRow(agent: agent, workspaceLabel: s.workspace(agent.workspaceId)?.label)
                        }
                    }
                }
            }
        }
        .animation(.default, value: attention.map(\.id))
    }
}

struct AgentsButton: View {
    @Environment(HerdrStore.self) private var store
    @Binding var showAgents: Bool
    /// Tap target for the button, when it isn't in a navigation bar.
    var hit: CGSize? = nil

    var body: some View {
        let waiting = store.snapshot?.agents.filter { $0.agentStatus == .blocked }.count ?? 0
        Button { showAgents = true } label: {
            Image(systemName: "person.2.wave.2")
                .frame(width: hit?.width, height: hit?.height)
                .contentShape(.rect)
                .overlay(alignment: .topTrailing) {
                    if waiting > 0 {
                        Text("\(waiting)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(AgentStatus.blocked.tint, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
        }
        .accessibilityLabel(waiting > 0 ? "Agents, \(waiting) need input" : "Agents")
    }
}

struct WorkspaceRow: View {
    let workspace: Workspace
    let agents: [Agent]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(workspace.number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(workspace.label).font(.body.weight(.semibold))
                    if workspace.focused {
                        Text("focused on Mac").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(counts).font(.caption).foregroundStyle(.secondary)
                ForEach(agents.sorted { $0.agentStatus.priority < $1.agentStatus.priority }) { agent in
                    HStack(spacing: 6) {
                        StatusIcon(status: agent.agentStatus, size: 11)
                        Text(agent.kindLabel).font(.caption.weight(.medium))
                        Text(agent.headline == agent.kindLabel ? agent.agentStatus.label : agent.headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            StatusIcon(status: workspace.agentStatus)
        }
        .padding(.vertical, 2)
    }

    private var counts: String {
        let tabs = workspace.tabCount == 1 ? "1 tab" : "\(workspace.tabCount) tabs"
        let panes = workspace.paneCount == 1 ? "1 pane" : "\(workspace.paneCount) panes"
        return "\(tabs) · \(panes)"
    }
}

struct AgentRow: View {
    let agent: Agent
    let workspaceLabel: String?

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(status: agent.agentStatus, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.headline).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(agent.kindLabel)
                    if let workspaceLabel { Text("· \(workspaceLabel)") }
                    Text("· \(agent.agentStatus.label)").foregroundStyle(agent.agentStatus.tint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

/// Round trip to herdr under the title (iOS 26): green when snappy, yellow when slow.
private struct LatencySubtitle: ViewModifier {
    @Environment(HerdrStore.self) private var store
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), enabled, store.isConnected, let latency = store.latency {
            let ms = Int((latency / .milliseconds(1)).rounded())
            content.navigationSubtitle(Text("\(ms)ms").foregroundStyle(ms < 150 ? Color.green : ms < 500 ? Color.yellow : Color.red))
        } else {
            content
        }
    }
}

private struct TitleMenu<Items: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        if enabled { content.toolbarTitleMenu { items() } } else { content }
    }
}

/// A glass panel, tinted and glowing in a status color (none for quiet ones).
private struct GlassPanel: ViewModifier {
    let tint: Color?
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(tint.map { .regular.tint($0.opacity(0.28)) } ?? .regular, in: shape)
                .shadow(color: (tint ?? .clear).opacity(0.3), radius: 16)
        } else {
            content
                .background((tint ?? .gray).opacity(tint == nil ? 0.18 : 0.3), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
                .shadow(color: (tint ?? .clear).opacity(0.35), radius: 16)
        }
    }
}

/// "Needs you": an agent that's done or waiting on you.
struct AttentionCard: View {
    let agent: Agent
    let workspaceLabel: String?

    var body: some View {
        HStack(spacing: 14) {
            StatusIcon(status: agent.agentStatus, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.headline).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(agent.kindLabel)
                    if let workspaceLabel { Text("· \(workspaceLabel)") }
                    Text("· \(agent.agentStatus.label)").foregroundStyle(agent.agentStatus.tint)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .modifier(GlassPanel(tint: nil, cornerRadius: 24))
    }
}

/// A workspace on the home grid, tinted by its busiest agent: yellow while
/// one works, green when one is done or waiting on you. Quiet ones stay plain
/// so the ones that matter stand out.
struct WorkspaceTile: View {
    let workspace: Workspace
    let agents: [Agent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(workspace.number)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(workspace.label)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            Text(counts).font(.caption).foregroundStyle(.secondary)
            if workspace.focused {
                Text("focused on Mac")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 8)
            if agents.isEmpty {
                Label("shell", systemImage: "terminal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedAgents.prefix(3)) { agent in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusIcon(status: agent.agentStatus, size: 12)
                        Text(agent.kindLabel).font(.caption.weight(.semibold))
                    }
                    if agent.headline != agent.kindLabel, agent.headline != workspace.label {
                        Text(agent.headline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .contentShape(Rectangle())
        .modifier(GlassPanel(tint: tint))
    }

    private var sortedAgents: [Agent] { agents.sorted { $0.agentStatus.priority < $1.agentStatus.priority } }

    private var tint: Color? {
        switch workspace.agentStatus {
        case .working, .blocked, .done: workspace.agentStatus.tint
        case .idle, .unknown: nil
        }
    }

    private var counts: String {
        let tabs = workspace.tabCount == 1 ? "1 tab" : "\(workspace.tabCount) tabs"
        let panes = workspace.paneCount == 1 ? "1 pane" : "\(workspace.paneCount) panes"
        return "\(tabs) · \(panes)"
    }
}
