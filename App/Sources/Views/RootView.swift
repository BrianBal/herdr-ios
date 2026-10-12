import HerdrKit
import SwiftUI

enum Route: Hashable {
    /// A workspace, optionally opened at a specific pane.
    case workspace(String, pane: String?)

    var workspaceId: String {
        switch self { case .workspace(let id, _): id }
    }

    var paneId: String? {
        switch self { case .workspace(_, let pane): pane }
    }
}

/// Compact width (iPhone, iPhone Duo folded): a navigation stack with the
/// agents panel as a sheet. Regular width (iPad, iPhone Duo unfolded): a
/// sidebar with workspaces and agents beside the open workspace.
///
/// Both layouts share the open workspace and focused split, so folding or
/// unfolding (a live resize of the same scene) keeps your place.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(HerdrStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var route: Route?
    @State private var selectedPaneId: String?
    @State private var showAgents = false

    var body: some View {
        Group {
            if app.endpoint == nil {
                PairView()
            } else if sizeClass == .regular {
                regular
            } else {
                compact
            }
        }
        .onAppear { app.resume() }
        .task(id: store.isConnected) {
            // Ask for notifications the first time a gateway is actually reachable.
            if store.isConnected { await app.push.requestAuthorizationIfFirstTime() }
        }
        .onChange(of: route) { _, route in selectedPaneId = route?.paneId }
        // Workspace ids repeat across machines (both have a w1), so start over.
        .onChange(of: app.activeId) { route = nil }
        .onChange(of: store.snapshot?.workspaces.map(\.workspaceId)) { _, ids in
            // The open workspace was closed (here or on the Mac): back to the list.
            if let ids, let route, !ids.contains(route.workspaceId) { self.route = nil }
        }
        .onChange(of: PendingOpen(paneId: app.pendingPaneId, ready: store.snapshot != nil)) { _, pending in
            guard pending.ready, let id = pending.paneId else { return }
            app.pendingPaneId = nil
            showAgents = false
            if let pane = store.snapshot?.pane(id) {
                route = .workspace(pane.workspaceId, pane: pane.paneId)
            }
        }
        .alert("Action failed", isPresented: Binding(
            get: { store.actionError != nil }, set: { if !$0 { store.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.actionError ?? "")
        }
    }

    private var compact: some View {
        NavigationStack(path: Binding(get: { route.map { [$0] } ?? [] }, set: { route = $0.last })) {
            HomeView(showAgents: $showAgents, open: { route = $0 })
                .navigationDestination(for: Route.self) { route in
                    WorkspaceView(workspaceId: route.workspaceId, selectedPaneId: $selectedPaneId, showAgents: $showAgents)
                }
        }
        .sheet(isPresented: $showAgents) {
            AgentsSheet { agent in
                showAgents = false
                route = .workspace(agent.workspaceId, pane: agent.paneId)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    private var regular: some View {
        NavigationSplitView {
            HomeView(showAgents: $showAgents, sidebarSelection: $route, open: { route = $0 })
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                if let route {
                    WorkspaceView(workspaceId: route.workspaceId, selectedPaneId: $selectedPaneId, showAgents: $showAgents)
                        .id(route.workspaceId)
                } else {
                    ContentUnavailableView("Pick a workspace", systemImage: "sidebar.left",
                                           description: Text("Or an agent that needs you."))
                }
            }
        }
        // Terminals need the width: in portrait the sidebar slides over instead of squeezing them.
        .navigationSplitViewStyle(.prominentDetail)
    }
}

private struct PendingOpen: Equatable {
    let paneId: String?
    let ready: Bool
}
