import HerdrKit
import SwiftUI

/// A workspace on one of the paired machines, optionally opened at a pane.
struct Route: Hashable {
    var gatewayId: String
    var workspaceId: String
    var paneId: String?

    var tab: TabKey { TabKey(gatewayId: gatewayId, workspaceId: workspaceId) }
}

/// One layout on every device, like Safari: the tabs overview (every
/// workspace on every machine), and the open workspace full screen over it.
/// Only the workspace's tabs button goes back: no drag gesture competes with
/// the terminal's (scrolling, putting the keyboard away, swiping panes).
/// Folding or unfolding the Duo (a live resize of the same scene) keeps the
/// open workspace and focused split.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var route: Route?
    /// The last workspace opened, which the overview's Done goes back to.
    @State private var lastRoute: Route?
    @State private var selectedPaneId: String?
    @State private var landscape = false

    var body: some View {
        Group {
            if app.gateways.isEmpty {
                PairView()
            } else {
                stack
            }
        }
        .onAppear { app.resume() }
        .task(id: app.orderedStores.contains(where: \.isConnected)) {
            // Ask for notifications the first time a gateway is actually reachable.
            if app.orderedStores.contains(where: \.isConnected) { await app.push.requestAuthorizationIfFirstTime() }
        }
        .onChange(of: route) { _, route in
            selectedPaneId = route?.paneId
            if let route { lastRoute = route }
        }
        .onChange(of: openWorkspaceIds) { _, ids in
            // The open workspace was closed (here or on the Mac), or its machine removed: back to the tabs.
            guard let route else { return }
            if app.store(route.gatewayId) == nil || ids.map({ !$0.contains(route.workspaceId) }) == true {
                self.route = nil
                lastRoute = nil
            }
        }
        .onChange(of: PendingKey(request: app.pendingOpen, ready: pendingStore?.snapshot != nil)) { _, pending in
            guard pending.ready, let request = pending.request, let store = pendingStore else { return }
            app.pendingOpen = nil
            if let pane = store.snapshot?.pane(request.paneId) {
                route = Route(gatewayId: store.gatewayId, workspaceId: pane.workspaceId, paneId: pane.paneId)
            }
        }
        .alert("Action failed", isPresented: Binding(
            get: { failing != nil }, set: { if !$0 { failing?.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failing?.actionError ?? "")
        }
    }

    private var stack: some View {
        ZStack {
            // Not kept under the open workspace, where VoiceOver and keyboard
            // focus would still reach its cards.
            if route == nil {
                NavigationStack {
                    TabsView(current: lastRoute) { open in
                        withAnimation(Self.motion) { route = open }
                    }
                }
                .transition(.opacity)
            }
            if let route, let store = app.store(route.gatewayId) {
                NavigationStack {
                    WorkspaceView(workspaceId: route.workspaceId, selectedPaneId: $selectedPaneId)
                        .environment(store)
                        .environment(\.showTabs) { withAnimation(Self.motion) { self.route = nil } }
                }
                .id(route.tab)
                .background(TerminalRenderer.background.ignoresSafeArea())
                .transition(.scale(scale: 0.86).combined(with: .opacity))
                .zIndex(1)
            }
        }
        // The whole screen, not the space above the keyboard: with it up, a
        // portrait screen's leftover is wider than tall.
        .background {
            Color.clear.ignoresSafeArea()
                .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 }
        }
        // A phone in portrait: the status bar is a band across the top, lines
        // lost over a terminal. In landscape it sits in the side column.
        .statusBarHidden(UIDevice.current.userInterfaceIdiom == .phone && route != nil && !landscape)
    }

    /// Opening a tab and going back to the tabs.
    private static let motion = Animation.snappy(duration: 0.3)

    /// The open workspace's machine's workspaces (nil while it has no snapshot).
    private var openWorkspaceIds: [String]? {
        route.flatMap { app.store($0.gatewayId)?.snapshot?.workspaces.map(\.workspaceId) }
    }

    /// The machine a pending pane request is for: its own, else the primary (widget links).
    private var pendingStore: HerdrStore? {
        guard let request = app.pendingOpen else { return nil }
        return (request.gatewayId ?? app.primaryId).flatMap(app.store)
    }

    /// A store whose last action failed, to say so.
    private var failing: HerdrStore? { app.orderedStores.first { $0.actionError != nil } }
}

extension EnvironmentValues {
    /// Goes back to the tabs overview from the open workspace.
    @Entry var showTabs: (() -> Void)? = nil
}

private struct PendingKey: Equatable {
    let request: PaneRequest?
    let ready: Bool
}
