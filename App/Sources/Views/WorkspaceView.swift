import HerdrKit
import SwiftUI

/// One workspace. On phones (the unfolded Duo included): every split in every
/// tab is a page in one continuous pager; tab chips and the split map jump
/// around it. iPad: the current tab's splits side by side ([PaneGrid]). Either
/// way the composer/toolbar act on the selected split.
struct WorkspaceView: View {
    @Environment(HerdrStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    let workspaceId: String
    /// Owned by RootView so it survives fold/unfold layout switches.
    @Binding var selectedPaneId: String?
    @Binding var showAgents: Bool
    @AppStorage("terminal.fontSize") private var fontSize = 11.0
    @AppStorage("terminal.wrap") private var wrap = true
    @AppStorage("terminal.fit") private var fitScreen = true
    @Environment(\.toggleSidebar) private var toggleSidebar
    /// Width of the column the unfolded Duo keeps beside the screen in
    /// landscape for the clock and status icons; 0 elsewhere.
    @State private var sideColumn: CGFloat = 0

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// The unfolded Duo, and any phone in landscape: no navigation bar, the
    /// height goes to the terminal. Its buttons move to the side column in
    /// landscape, or into the split header in portrait.
    private var chromeless: Bool { isPhone && (sizeClass == .regular || verticalSizeClass == .compact) }
    private var usesSideRail: Bool { chromeless && sideColumn >= 44 }

    var body: some View {
        if let s = store.snapshot, let ws = s.workspace(workspaceId) {
            content(s, ws)
        } else if store.snapshot == nil {
            ProgressView()
        } else {
            ContentUnavailableView("Workspace closed", systemImage: "rectangle.slash",
                                   description: Text("It no longer exists in herdr."))
        }
    }

    private func content(_ s: SessionSnapshot, _ ws: Workspace) -> some View {
        let tabs = s.tabs(in: ws.workspaceId)
        let pages = tabs.flatMap { s.panes(in: $0.tabId) }
        let current = pages.first { $0.paneId == selectedPaneId }
            ?? Self.entryPane(of: ws.activeTabId, in: s) ?? pages.first
        let tabPanes = current.map { s.panes(in: $0.tabId) } ?? []
        let layout = current.flatMap { c in s.layouts.first { $0.tabId == c.tabId } }

        return VStack(spacing: 0) {
            ConnectionBanner()
            if tabs.count > 1, let current {
                TabChips(tabs: tabs, selection: current.tabId) { tabId in
                    withAnimation { selectedPaneId = Self.entryPane(of: tabId, in: s)?.paneId }
                }
            }
            if sizeClass == .regular && !isPhone {
                PaneGrid(panes: tabPanes, layout: layout, selection: current?.paneId) { paneId in
                    selectedPaneId = paneId
                }
            } else {
                if let current {
                    PaneHeader(pane: current,
                               index: tabPanes.firstIndex(of: current) ?? 0,
                               count: tabPanes.count,
                               layout: layout,
                               // Status bar hidden (Duo portrait): iOS still keeps the top
                               // ~21pt for itself and taps there don't arrive, so start lower.
                               topInset: chromeless && !usesSideRail && verticalSizeClass != .compact ? 10 : 0) { paneId in
                        withAnimation { selectedPaneId = paneId }
                    } actions: {
                        if chromeless && !usesSideRail { workspaceButtons(current, ws, hit: CGSize(width: 44, height: 36)) }
                    }
                }
                TabView(selection: $selectedPaneId) {
                    ForEach(pages) { pane in
                        PaneTerminalView(paneId: pane.paneId)
                            .tag(Optional(pane.paneId))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Under the Duo's side column too, so the rail sits on the terminal's color.
                .background(TerminalRenderer.background.ignoresSafeArea(.container, edges: .horizontal))
            }
        }
        .background {
            PaneShortcuts(panes: tabPanes, tabs: tabs, currentTab: current?.tabId) { paneId in
                selectedPaneId = paneId
            } selectTab: { tabId in
                selectedPaneId = Self.entryPane(of: tabId, in: s)?.paneId
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let current { ComposerBar(pane: current) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: { sideColumn = $0 }
        .overlay {
            if usesSideRail {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SideRail {
                        if let current { workspaceButtons(current, ws, hit: CGSize(width: 50, height: 44)) }
                    }
                    .frame(width: sideColumn)
                }
                .ignoresSafeArea(.container, edges: .trailing)
            }
        }
        .navigationTitle(ws.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(chromeless ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if let current {
                ToolbarItem(placement: .topBarTrailing) {
                    PaneMenu(pane: current, workspaceLabel: ws.label, selectedPaneId: $selectedPaneId)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { textMenu() }
            if sizeClass != .regular {
                ToolbarItem(placement: .topBarTrailing) { AgentsButton(showAgents: $showAgents) }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedPaneId)
        .onAppear {
            // Keep a selection made elsewhere (an agent row, the other layout) if it's in this workspace.
            if let id = selectedPaneId, pages.contains(where: { $0.paneId == id }) { return }
            selectedPaneId = current?.paneId
        }
        .onChange(of: selectedPaneId) { _, id in
            if id == nil { selectedPaneId = current?.paneId }
        }
        .onChange(of: pages.map(\.paneId)) { _, ids in
            // The visible split closed or moved away: fall back to the first page.
            if let sel = selectedPaneId, !ids.contains(sel) { selectedPaneId = ids.first }
        }
    }

    /// The navigation bar's buttons, for when the workspace goes without one:
    /// the sidebar toggle (split view) or Back (navigation stack) first. Each
    /// gets a full-size tap target (`hit`), not just its glyph: in the rail the
    /// whole capsule looks tappable.
    @ViewBuilder
    private func workspaceButtons(_ current: Pane, _ ws: Workspace, hit: CGSize) -> some View {
        if let toggleSidebar {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .frame(width: hit.width, height: hit.height)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Workspaces")
        } else {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: hit.width, height: hit.height)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Back")
        }
        PaneMenu(pane: current, workspaceLabel: ws.label, selectedPaneId: $selectedPaneId, hit: hit)
        textMenu(hit: hit)
        if sizeClass != .regular { AgentsButton(showAgents: $showAgents, hit: hit) }
    }

    private func textMenu(hit: CGSize? = nil) -> some View {
        Menu {
            Button { fontSize = min(20, fontSize + 1) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
            Button { fontSize = max(7, fontSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
            Toggle(isOn: $wrap) { Label("Wrap long lines", systemImage: "text.word.spacing") }
            Toggle(isOn: $fitScreen) { Label("Fit panes to this screen", systemImage: "arrow.down.right.and.arrow.up.left") }
                .disabled(!wrap)
        } label: {
            Image(systemName: "textformat.size")
                .frame(width: hit?.width, height: hit?.height)
                .contentShape(.rect)
        }
        .accessibilityLabel("Text options")
    }

    /// The split to show when entering a tab: herdr's focused one, else the first.
    private static func entryPane(of tabId: String, in s: SessionSnapshot) -> Pane? {
        let panes = s.panes(in: tabId)
        let focusedId = s.layouts.first { $0.tabId == tabId }?.focusedPaneId
        return panes.first { $0.paneId == focusedId } ?? panes.first
    }
}

/// The workspace's buttons stacked in the unfolded Duo's side column, in
/// place of a navigation bar.
private struct SideRail<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 4) { content }
            .font(.title3)
            .padding(.vertical, 8)
            .frame(width: 50)
            .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct TabChips: View {
    let tabs: [HerdrKit.Tab]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        let selected = tab.tabId == selection
                        Button { onSelect(tab.tabId) } label: {
                            HStack(spacing: 5) {
                                if tab.agentStatus != .idle && tab.agentStatus != .unknown {
                                    StatusIcon(status: tab.agentStatus, size: 10)
                                }
                                Text(tab.label.isEmpty ? "Tab \(tab.number)" : tab.label)
                                if tab.paneCount > 1 {
                                    Text("\(tab.paneCount)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                        }
                        .tint(selected ? .accentColor : .primary)
                        .id(tab.tabId)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: selection) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .background(.bar)
    }
}

private struct PaneHeader<Actions: View>: View {
    let pane: Pane
    let index: Int
    let count: Int
    let layout: PaneLayout?
    var topInset: CGFloat = 0
    let onSelect: (String) -> Void
    /// Buttons at the trailing end, when there's no navigation bar for them.
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            if let layout, layout.panes.count > 1 {
                SplitMap(layout: layout, current: pane.paneId, onSelect: onSelect)
                    .frame(width: 46, height: 30)
            }
            if pane.hasAgent { StatusIcon(status: pane.agentStatus, size: 13) }
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.displayTitle).font(.footnote.weight(.semibold)).lineLimit(1)
                if let dir = pane.foregroundCwd ?? pane.cwd {
                    Text(abbreviate(dir)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if count > 1 {
                Text("\(index + 1)/\(count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Split \(index + 1) of \(count)")
            }
            HStack(spacing: 0) { actions }
                .font(.body)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.top, topInset)
        .background(.bar)
    }

}

private func abbreviate(_ path: String) -> String {
    if let r = path.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
        return "~" + path[r.upperBound...]
    }
    return path
}

/// Regular width (iPad, iPhone Duo unfolded): the current tab's splits side by
/// side, arranged the way herdr arranges them on the Mac. When that would leave
/// a split too small to read, shows two at a time in a pager instead, which also
/// keeps a split from straddling the Duo's fold. In portrait the pager shows one
/// at a time. Tap a split to select it.
private struct PaneGrid: View {
    let panes: [Pane]
    let layout: PaneLayout?
    let selection: String?
    let onSelect: (String) -> Void
    @State private var page = 0

    static let minTile = CGSize(width: 300, height: 200)
    static let gap: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            // The unfolded Duo keeps the status bar and toolbar in a column at the
            // trailing edge. Splits that reach it run underneath, text kept clear.
            let trailing = geo.safeAreaInsets.trailing
            // Portrait: one split at a time, full width.
            let portrait = geo.size.height > geo.size.width
            Group {
                if !portrait, let frames = frames(in: geo.size) {
                    ZStack(alignment: .topLeading) {
                        ForEach(panes) { pane in
                            if let f = frames[pane.paneId] {
                                let under = f.maxX >= geo.size.width - 0.5 ? trailing : 0
                                tile(pane, highlight: panes.count > 1, position: nil, trailingInset: under)
                                    .frame(width: f.width + under, height: f.height)
                                    .offset(x: f.minX, y: f.minY)
                            }
                        }
                    }
                } else {
                    pager(perPage: !portrait && geo.size.width >= 2 * Self.minTile.width ? 2 : 1, trailingInset: trailing)
                }
            }
            .ignoresSafeArea(.container, edges: .trailing)
        }
        .background(Color(white: 0.3))
    }

    /// herdr's layout scaled to `size`, or nil when it doesn't fit legibly.
    private func frames(in size: CGSize) -> [String: CGRect]? {
        guard let layout, size.width > 0 else { return nil }
        let area = layout.area
        let sx = size.width / CGFloat(max(1, area.width))
        let sy = size.height / CGFloat(max(1, area.height))
        var frames: [String: CGRect] = [:]
        for p in layout.panes {
            let r = CGRect(x: CGFloat(p.rect.x - area.x) * sx, y: CGFloat(p.rect.y - area.y) * sy,
                           width: CGFloat(p.rect.width) * sx, height: CGFloat(p.rect.height) * sy)
            // Hairline gaps between neighbours, none at the outer edges.
            let inset = CGRect(x: r.minX + (r.minX > 0.5 ? Self.gap : 0), y: r.minY + (r.minY > 0.5 ? Self.gap : 0),
                               width: r.width - (r.minX > 0.5 ? Self.gap : 0),
                               height: r.height - (r.minY > 0.5 ? Self.gap : 0))
            if layout.panes.count > 1, inset.width < Self.minTile.width || inset.height < Self.minTile.height {
                return nil
            }
            frames[p.paneId] = inset
        }
        return panes.allSatisfy { frames[$0.paneId] != nil } ? frames : nil
    }

    private func pager(perPage: Int, trailingInset: CGFloat) -> some View {
        let pages = stride(from: 0, to: panes.count, by: perPage).map { Array(panes[$0..<min($0 + perPage, panes.count)]) }
        let pageOfSelection = panes.firstIndex { $0.paneId == selection }.map { $0 / perPage } ?? 0
        return TabView(selection: $page) {
            ForEach(pages.indices, id: \.self) { i in
                HStack(spacing: Self.gap) {
                    ForEach(pages[i]) { pane in
                        tile(pane, highlight: perPage > 1,
                             position: pages.count > 1 ? "\(panes.firstIndex(of: pane).map { $0 + 1 } ?? 0)/\(panes.count)" : nil,
                             trailingInset: pane == pages[i].last ? trailingInset : 0)
                    }
                }
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onAppear { page = pageOfSelection }
        .onChange(of: pageOfSelection) { _, p in withAnimation { page = p } }
        .onChange(of: page) { _, p in
            // Swiping to another page selects its first split.
            if p != pageOfSelection, pages.indices.contains(p), let first = pages[p].first { onSelect(first.paneId) }
        }
    }

    /// `highlight`: more than one split is on screen, so mark the selected one.
    /// `position`: "2/5" when the pager hides some splits.
    /// `trailingInset`: width of the tile under the trailing column, kept free of text.
    private func tile(_ pane: Pane, highlight: Bool, position: String?, trailingInset: CGFloat) -> some View {
        let selected = pane.paneId == selection && highlight
        return VStack(spacing: 0) {
            TileHeader(pane: pane, selected: selected, position: position)
            PaneTerminalView(paneId: pane.paneId)
        }
        .safeAreaPadding(.trailing, trailingInset)
        .overlay {
            Rectangle().strokeBorder(Color.accentColor.opacity(selected ? 0.8 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onSelect(pane.paneId) })
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TileHeader: View {
    let pane: Pane
    let selected: Bool
    let position: String?

    var body: some View {
        HStack(spacing: 6) {
            if pane.hasAgent { StatusIcon(status: pane.agentStatus, size: 11) }
            Text(pane.displayTitle).font(.caption.weight(.semibold)).lineLimit(1)
            if let dir = pane.foregroundCwd ?? pane.cwd {
                Text(abbreviate(dir)).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if let position {
                Text(position).font(.caption2.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.left.chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.bar))
    }
}

/// Hardware-keyboard shortcuts (iPad, or a keyboard on the Duo): ⌘1–9 select a
/// split in the current tab, ⇧⌘[ / ⇧⌘] switch tabs. Hold ⌘ to list them.
private struct PaneShortcuts: View {
    let panes: [Pane]
    let tabs: [HerdrKit.Tab]
    let currentTab: String?
    let select: (String) -> Void
    let selectTab: (String) -> Void

    var body: some View {
        ZStack {
            ForEach(Array(panes.prefix(9).enumerated()), id: \.element.id) { i, pane in
                Button("Split \(i + 1): \(pane.displayTitle)") { select(pane.paneId) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            if tabs.count > 1 {
                Button("Previous Tab") { step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Tab") { step(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.tabId == currentTab }) else { return }
        selectTab(tabs[(i + delta + tabs.count) % tabs.count].tabId)
    }
}

/// Miniature of herdr's split layout for the current tab; the visible split is
/// filled. Tap a split to jump to it.
private struct SplitMap: View {
    let layout: PaneLayout
    let current: String
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let area = layout.area
            let sx = geo.size.width / CGFloat(max(1, area.width))
            let sy = geo.size.height / CGFloat(max(1, area.height))
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.paneId) { p in
                    let r = CGRect(x: CGFloat(p.rect.x - area.x) * sx, y: CGFloat(p.rect.y - area.y) * sy,
                                   width: CGFloat(p.rect.width) * sx, height: CGFloat(p.rect.height) * sy)
                        .insetBy(dx: 1, dy: 1)
                    let isCurrent = p.paneId == current
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                        .frame(width: max(2, r.width), height: max(2, r.height))
                        .offset(x: r.minX, y: r.minY)
                        .onTapGesture { onSelect(p.paneId) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Split layout")
    }
}

/// Live, reflowing render of a pane's visible screen. Agent messages and code
/// blocks get copy buttons in a narrow gutter; code blocks get a panel.
struct PaneTerminalView: View {
    @Environment(HerdrStore.self) private var store
    let paneId: String
    @AppStorage("terminal.fontSize") private var fontSize = 11.0
    @AppStorage("terminal.wrap") private var wrap = true
    @AppStorage("terminal.fit") private var fitScreen = true
    @GestureState private var pinch: CGFloat = 1
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var scroll = ScrollPosition(edge: .bottom)
    @State private var spot = ScrollSpot()
    /// Height of the header, earlier output and Live divider above the live screen.
    @State private var historyHeight: CGFloat = 0
    /// While earlier output loads: where the viewport's top sits relative to
    /// the start of the live screen, so rows arriving above don't move you.
    @State private var heldTop: CGFloat?
    /// Within a screen of the top, where earlier output loads by itself.
    @State private var nearTop = NearTop()
    @State private var scrolledByHand = false

    /// Kept by the store, so history survives swiping away and back.
    private var model: TerminalModel { store.terminal(for: paneId) }
    private var agent: String? { store.snapshot?.pane(paneId)?.agent }

    static let gutterWidth: CGFloat = 28

    /// SF Mono advance is ~0.6 em; minus padding, the copy gutter and a safety margin.
    private var wrapColumns: Int? {
        guard wrap, width > 0 else { return nil }
        return max(10, Int((width - 16 - Self.gutterWidth) / (fontSize * 0.602)) - 2)
    }

    /// The size to hold the pane at so its program draws for this screen
    /// instead of the Mac's split. Only while wrapping: scrolling sideways is
    /// for reading the Mac's layout as is.
    private var fitSize: PaneSize? {
        guard fitScreen, let cols = wrapColumns, height > 0 else { return nil }
        let line = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).lineHeight
        return PaneSize(cols: cols, rows: max(5, Int((height - 12) / line)))
    }

    private var agentPane: Bool { store.snapshot?.pane(paneId)?.hasAgent ?? false }

    /// Width of this pane in cells: the fitted width, else its split on the Mac.
    private var paneColumns: Int? {
        if let fitSize { return fitSize.cols }
        guard let s = store.snapshot, let pane = s.pane(paneId) else { return nil }
        return s.layouts.first { $0.tabId == pane.tabId }?.panes.first { $0.paneId == paneId }?.rect.width
    }

    var body: some View {
        ZStack {
            TerminalRenderer.background.ignoresSafeArea()
            if model.status == .loading && model.isEmpty {
                ProgressView().tint(TerminalRenderer.foreground)
            } else {
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            if model.showsHistoryHeader {
                                HistoryHeader(state: model.historyState) { Task { await loadEarlier() } }
                            }
                            ForEach(model.history) { row in
                                switch row {
                                case .segment(let segment):
                                    SegmentView(segment: segment, wrap: wrap)
                                case .gap(let gap):
                                    GapMarker(row: gap) { Task { await fill(gap.gap) } }
                                }
                            }
                            if !model.history.isEmpty { LiveDivider(joined: model.historyJoined) }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            historyHeight = height
                            holdPlace()
                        }
                        ForEach(model.segments) { segment in
                            SegmentView(segment: segment, wrap: wrap)
                        }
                    }
                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.trailing, wrap ? 4 : 8)
                    .padding(.vertical, 6)
                    .scaleEffect(pinch, anchor: .bottomLeading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: ScrollSpot.self) { geo in
                    ScrollSpot(top: geo.contentOffset.y + geo.contentInsets.top, inset: geo.contentInsets.top)
                } action: { _, spot in
                    self.spot = spot
                    holdPlace()
                }
                // Earlier output loads as you near the top, no button needed. Also
                // when the pane's screen is shorter than this one (a short split on
                // the Mac): the rest fills with earlier output instead of blank space.
                .onScrollGeometryChange(for: NearTop.self) { geo in
                    NearTop(near: geo.contentOffset.y + geo.contentInsets.top < geo.containerSize.height,
                            short: geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom < geo.containerSize.height)
                } action: { _, value in
                    nearTop = value
                    loadNearTop()
                }
                // Scrolling yourself while earlier output loads takes over from the hold.
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        heldTop = nil
                        scrolledByHand = true
                    }
                }
                .scrollIndicators(.visible)
                // Reading the output puts the keyboard away: drag down into it (as in
                // Messages) or tap the output. Links and buttons keep their taps, and
                // the draft stays in the field.
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { dismissKeyboard() }
                .accessibilityIdentifier("pane-output")
                // Pull down at the top for earlier output.
                .refreshable { await loadEarlier() }
            }
        }
        .overlay(alignment: .top) {
            if case .ended(let reason) = model.status, store.isConnected {
                Label(reason ?? "Pane output stopped", systemImage: "pause.circle")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in fontSize = min(20, max(7, (fontSize * value.magnification).rounded())) }
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            width = $0.width
            height = $0.height
        }
        .task(id: WatchKey(generation: store.generation, paneId: paneId, agent: agent)) {
            guard let client = store.client else { return }
            let model = model
            await model.setFit(fitSize)
            await model.setLayout(fontSize: fontSize, wrapColumns: wrapColumns, paneColumns: paneColumns, agentPane: agentPane)
            await model.watch(paneId, agent: agent, client: client)
        }
        // Settle first: the keyboard and a pinch pass through sizes on the way.
        .task(id: fitSize) {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { await model.setFit(fitSize) }
        }
        .onChange(of: LayoutKey(fontSize: fontSize, columns: wrapColumns, paneColumns: paneColumns, agentPane: agentPane)) { _, key in
            Task {
                await model.setLayout(fontSize: key.fontSize, wrapColumns: key.columns,
                                      paneColumns: key.paneColumns, agentPane: key.agentPane)
            }
        }
    }

    /// Fetches earlier output without moving what you're reading: the new
    /// rows land above, ready to scroll up through.
    private func loadEarlier() async {
        guard let client = store.client, heldTop == nil else { return }
        heldTop = max(spot.top, 0) - historyHeight
        await model.loadEarlier(paneId, agent: agent, client: client)
        // Keep holding while the new rows lay out; each height change re-pins.
        try? await Task.sleep(for: .milliseconds(300))
        heldTop = nil
        // Still at the top (it was a short page): keep going.
        loadNearTop()
    }

    /// Fills a gap in a Claude session's history, keeping what's below it
    /// (what you scrolled up from) where it is while the lines pop in above.
    private func fill(_ gap: TranscriptTimeline.Gap) async {
        guard heldTop == nil else { return }
        heldTop = max(spot.top, 0) - historyHeight
        await model.fillGap(gap)
        try? await Task.sleep(for: .milliseconds(300))
        heldTop = nil
    }

    /// Loads more once you're near the top. The first load of a shell's history
    /// waits for you to scroll there yourself (or a short screen), rather than
    /// the moment the pane opens.
    private func loadNearTop() {
        guard nearTop.near, heldTop == nil, model.canLoadMore, model.status == .live else { return }
        if model.historyState == .none, !scrolledByHand, !nearTop.short { return }
        Task { await loadEarlier() }
    }

    /// While a load is in flight, keeps the view's top at the same distance
    /// from the start of the live screen as history grows or shrinks above it.
    private func holdPlace() {
        guard let held = heldTop else { return }
        let target = held + historyHeight
        if abs(target - spot.top) > 0.5 { scroll.scrollTo(y: target - spot.inset) }
    }

    private struct ScrollSpot: Equatable {
        /// Top edge of the viewport in content coordinates.
        var top: CGFloat = 0
        var inset: CGFloat = 0
    }

    private struct LayoutKey: Equatable {
        let fontSize: Double
        let columns: Int?
        let paneColumns: Int?
        let agentPane: Bool
    }

    private struct WatchKey: Hashable {
        let generation: Int
        let paneId: String
        /// Claude starting or quitting in the pane changes what the watch follows.
        let agent: String?
    }

    private struct NearTop: Equatable {
        var near = false
        var short = false
    }
}

/// What you can do with the selected pane: new tab, splits, start an agent
/// in a shell, close it.
private struct PaneMenu: View {
    @Environment(HerdrStore.self) private var store
    let pane: Pane
    let workspaceLabel: String
    @Binding var selectedPaneId: String?
    /// Tap target for the button, when it isn't in a navigation bar.
    var hit: CGSize? = nil
    @State private var confirmClose = false

    private var cwd: String? { pane.foregroundCwd ?? pane.cwd }

    var body: some View {
        Menu {
            Section {
                Button { open { await store.newTab(in: pane.workspaceId, cwd: cwd) } } label: {
                    Label("New tab", systemImage: "plus.square.on.square")
                }
                Button { open { await store.split(pane.paneId, .right, cwd: cwd) } } label: {
                    Label("Split right", systemImage: "rectangle.split.2x1")
                }
                Button { open { await store.split(pane.paneId, .down, cwd: cwd) } } label: {
                    Label("Split down", systemImage: "rectangle.split.1x2")
                }
            }
            if !pane.hasAgent, !store.agentKinds.isEmpty {
                Section("Start in this pane") {
                    ForEach(store.agentKinds, id: \.self) { kind in
                        Button {
                            Task { await store.startAgent(kind, in: pane.paneId, nameHint: workspaceLabel, prompt: nil) }
                        } label: {
                            Label(AgentKind.displayName(kind), systemImage: "sparkles")
                        }
                    }
                }
            }
            Section {
                Button(role: .destructive) { confirmClose = true } label: {
                    Label("Close pane", systemImage: "xmark.square")
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .frame(width: hit?.width, height: hit?.height)
                .contentShape(.rect)
        }
        .accessibilityLabel("Pane actions")
        .disabled(!store.isConnected)
        .confirmationDialog("Close this pane?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Pane", role: .destructive) { Task { await store.closePane(pane.paneId) } }
        } message: {
            Text(pane.hasAgent
                 ? "This ends \(pane.displayAgent ?? pane.agent ?? "the agent") running in it on your Mac."
                 : "This ends the shell running in it on your Mac.")
        }
    }

    /// Runs a create action and jumps to the pane it made.
    private func open(_ create: @escaping () async -> String?) {
        Task {
            if let id = await create() { withAnimation { selectedPaneId = id } }
        }
    }
}

/// Top of a pane's output: load (more) earlier output, or say why there's none.
private struct HistoryHeader: View {
    let state: TerminalModel.HistoryState
    let load: () -> Void

    var body: some View {
        HStack {
            Spacer()
            switch state {
            case .none:
                button("Load earlier output")
            case .loaded(more: true):
                button("Load more")
            case .loading:
                ProgressView().tint(TerminalRenderer.foreground).padding(.vertical, 6)
            case .loaded(more: false):
                note("Start of available output")
            case .empty:
                note("No earlier output")
            case .failed(let message):
                VStack(spacing: 4) {
                    note(message)
                    button("Try again")
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func button(_ title: String) -> some View {
        Button(action: load) {
            Label(title, systemImage: "arrow.up.to.line")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TerminalRenderer.foreground.opacity(0.85))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(TerminalRenderer.foreground.opacity(0.5))
    }
}

/// A stretch of a Claude session not loaded yet. It loads as soon as it
/// scrolls into view; what's left of it after each load stays a gap.
private struct GapMarker: View {
    let row: GapRow
    let load: () -> Void
    @State private var visible = false

    var body: some View {
        HStack(spacing: 8) {
            line
            Group {
                if row.loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(TerminalRenderer.foreground)
                        Text("Loading earlier messages")
                    }
                } else if row.error != nil {
                    Button(action: load) { Label("Couldn't load · Try again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.plain)
                } else {
                    Button(action: load) { Label("Earlier messages", systemImage: "arrow.up") }
                        .buttonStyle(.plain)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(TerminalRenderer.foreground.opacity(0.6))
            .fixedSize()
            line
        }
        .padding(.vertical, 12)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            self.visible = visible
            if visible, !row.loading, row.error == nil { load() }
        }
        .onChange(of: row) { _, row in
            // A smaller gap left after a load, still on screen: keep going.
            if visible, !row.loading, row.error == nil { load() }
        }
    }

    private var line: some View {
        Rectangle().fill(TerminalRenderer.foreground.opacity(0.2)).frame(height: 1)
    }
}

/// Where loaded history ends and the live screen begins. A faint rule when
/// they meet exactly; labeled when stitched on by text and possibly off.
private struct LiveDivider: View {
    let joined: Bool

    var body: some View {
        if joined {
            Rectangle().fill(Color.accentColor.opacity(0.25)).frame(height: 1).padding(.vertical, 4)
        } else {
            labeled
        }
    }

    private var labeled: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
            Label("Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 10)
    }
}

private struct SegmentView: View {
    let segment: RenderedSegment
    let wrap: Bool

    var body: some View {
        content
            .textSelection(.enabled)
            .fixedSize(horizontal: !wrap, vertical: false)
            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, segment.kind == .code ? 6 : 0)
            .padding(.vertical, segment.kind == .code ? 4 : 0)
            .background {
                if segment.kind == .code {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 2)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(.vertical, segment.kind == .code ? 3 : 0)
            // The copy gutter: right edge when wrapping, left edge when scrolling sideways.
            .padding(wrap ? .trailing : .leading, PaneTerminalView.gutterWidth)
            .overlay(alignment: buttonAlignment) {
                if let text = segment.copyText {
                    CopyButton(text: text, label: segment.kind == .code ? "Copy code" : "Copy message")
                        .padding(.vertical, segment.kind == .code ? 5 : 0)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if wrap, let paragraphs = segment.paragraphs {
            // Each line with its marker beside it, so wrapped text hangs under the marker.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(paragraphs) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if let hang = p.hang { Text(hang).fixedSize() }
                        Text(p.body).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            Text(segment.text)
        }
    }

    /// Code: beside the top of the block. Messages: beside their last line.
    private var buttonAlignment: Alignment {
        switch (segment.kind == .code, wrap) {
        case (true, true): .topTrailing
        case (true, false): .topLeading
        case (false, true): .bottomTrailing
        case (false, false): .bottomLeading
        }
    }
}

private struct CopyButton: View {
    let text: String
    let label: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Color.green : TerminalRenderer.foreground.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(copied ? 0.14 : 0.08), in: Circle())
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : label)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }
}

/// Ends editing in whatever field has the keyboard.
@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
