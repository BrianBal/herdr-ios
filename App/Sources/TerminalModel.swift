import HerdrKit
import Observation
import SwiftUI

enum TerminalRenderer {
    static let palette = TerminalPalette.gruvboxDark
    static var background: Color { color(palette.background) }
    static var foreground: Color { color(palette.foreground) }

    static func color(_ c: RGB) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    private static func blend(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) * (1 - t) + Double(y) * t).rounded()) }
        return RGB(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
    }

    /// Builds one AttributedString for the lines, with tappable links. Pure, so
    /// it runs off the main actor. `paneColumns` helps follow URLs the program wrapped.
    static func render(_ lines: [StyledLine], fontSize: CGFloat, paneColumns: Int? = nil) -> AttributedString {
        var out = AttributedString()
        let regular = Font.system(size: fontSize, design: .monospaced)
        let bold = Font.system(size: fontSize, weight: .bold, design: .monospaced)
        var lineStarts: [Int] = []
        var length = 0
        for (index, line) in lines.enumerated() {
            if index > 0 {
                out.append(AttributedString("\n"))
                length += 1
            }
            lineStarts.append(length)
            length += line.runs.reduce(0) { $0 + $1.text.count }
            for run in line.runs {
                var piece = AttributedString(run.text)
                let s = run.style
                var fg = palette.resolve(s.fg) ?? palette.foreground
                var bg = palette.resolve(s.bg)
                if s.inverse {
                    let oldFg = fg
                    fg = bg ?? palette.background
                    bg = oldFg
                }
                if s.dim { fg = blend(fg, bg ?? palette.background, 0.45) }
                var font = s.bold ? bold : regular
                if s.italic { font = font.italic() }
                piece.font = font
                piece.foregroundColor = color(fg)
                if let bg { piece.backgroundColor = color(bg) }
                if s.underline { piece.underlineStyle = .single }
                if s.strikethrough { piece.strikethroughStyle = .single }
                out.append(piece)
            }
        }
        for link in LinkDetector.links(in: lines.map(\.plainText), columns: paneColumns) {
            for piece in link.pieces {
                let start = out.characters.index(out.startIndex, offsetBy: lineStarts[piece.line] + piece.range.lowerBound)
                let end = out.characters.index(start, offsetBy: piece.range.count)
                out[start..<end].link = link.url
                out[start..<end].underlineStyle = .single
            }
        }
        return out
    }
}

/// One rendered piece of the pane: plain output, part of an agent message, or a code block.
struct RenderedSegment: Identifiable, Sendable {
    let id: Int
    let kind: TerminalSegment.Kind
    let text: AttributedString
    let copyText: String?
    /// Agent prose laid out a line at a time so wrapped lines can hang under
    /// their list marker (SwiftUI's Text can't indent wrapped lines itself).
    var paragraphs: [RenderedParagraph]? = nil
}

struct RenderedParagraph: Identifiable, Sendable {
    let id: Int
    /// Indent and marker ("  - ", "⏺ "), drawn beside the body.
    let hang: AttributedString?
    let body: AttributedString
}

/// Live view of one pane: a gateway watch whose ANSI frames are parsed,
/// split into messages/code blocks, and rendered off the main actor.
///
/// Claude Code panes: herdr keeps no scrollback for them, so the gateway also
/// follows Claude's session file and the conversation comes from there. The
/// screen is shown only from its first message that's in that transcript on
/// (see `TranscriptJoin`), so nothing repeats and nothing that scrolled off is
/// lost. What's loaded of the session is a `TranscriptTimeline`: runs of
/// blocks with gaps, each gap filled as it scrolls into view. Other panes load
/// earlier output on request and stitch it on by text.
///
/// One per pane, kept by `HerdrStore`, so history survives swiping between
/// panes, folding and reconnecting.
@MainActor @Observable
final class TerminalModel {
    enum Status: Equatable {
        case loading
        case live
        case ended(String?)
    }

    private(set) var segments: [RenderedSegment] = []
    /// Earlier output, shown above the live screen.
    private(set) var history: [HistoryRow] = []
    private(set) var historyState: HistoryState = .none
    /// History meets the screen exactly (a Claude transcript joined by
    /// message), rather than stitched on by matching text.
    private(set) var historyJoined = false
    private var historyLines: [StyledLine] = []
    /// History lines are whole paragraphs (Claude's transcript), not screen rows.
    private var historyLogical = false
    /// Lines asked for last time; each "load more" doubles it.
    private var historyRequest = 0

    enum HistoryState: Equatable {
        case none
        case loading
        /// Loaded; `more` when herdr had more than we asked for.
        case loaded(more: Bool)
        /// Asked, but there was nothing before the screen.
        case empty
        case failed(String)
    }

    static let historyFirstRequest = 1000
    static let historyMaxRequest = 16000
    private(set) var status: Status = .loading
    private(set) var lastFrameAt: Date?
    private var lines: [StyledLine] = []
    private var fontSize: CGFloat = 11
    /// Visible columns when wrapping (nil when not wrapping); separators are clipped to it.
    private var wrapColumns: Int?
    /// The pane's width on the Mac, used to re-join prose the agent wrapped.
    private var paneColumns: Int?
    private var agentPane = false
    /// The size the gateway holds the pane at, if fitting it to this screen.
    private var fit: PaneSize?
    private var watchId: String?
    private var client: GatewayClient?
    /// The watch that owns this model now; an older one still winding down
    /// (a fold/unfold rebuilds the view) must not touch it.
    private var activeWatch: UUID?

    /// The gateway follows this pane's Claude session.
    private var following = false
    private var timeline = TranscriptTimeline()
    /// Each block's lines, parsed, with a serial for segment ids.
    private var parsed: [String: (serial: Int, lines: [StyledLine])] = [:]
    private var firstLines: [String] = []
    private var cut: TranscriptJoin.Cut?
    /// Rendered blocks by id, for the current layout.
    private var renderedBlocks: [String: [RenderedSegment]] = [:]
    private var nextSerial = 0
    /// Gaps being fetched, and ones that failed, by where they start.
    private var fillingGaps: Set<Int> = []
    private var gapErrors: [Int: String] = [:]

    static let gapFillLines = 300

    private var usesTranscript: Bool { following && timeline.hasBlocks }

    var isEmpty: Bool { segments.isEmpty }

    /// Earlier output can be fetched now (on reaching the top, say). Claude
    /// panes fill their gaps as they come into view instead.
    var canLoadMore: Bool {
        if usesTranscript { return false }
        switch historyState {
        case .none: return status == .live
        case .loaded(let more): return more
        default: return false
        }
    }

    /// The "Load earlier output" header: not when the top is a gap, which loads itself.
    var showsHistoryHeader: Bool {
        if case .gap? = history.first { return false }
        return true
    }

    /// The live screen as the gateway sent it (ANSI), for the tabs overview's card.
    private(set) var screenText = ""

    /// Runs until cancelled or the watch ends (socket drop, pane closed).
    /// `agent` is the pane's agent kind: "claude" follows its session file.
    func watch(_ paneId: String, agent: String?, client: GatewayClient) async {
        let token = UUID()
        activeWatch = token
        status = .loading
        var follow: Task<Void, Never>?
        defer {
            follow?.cancel()
            if activeWatch == token { watchId = nil }
        }
        do {
            let (id, frames, transcript) = try await client.watchPane(
                paneId, fit: fit, transcriptLines: agent == "claude" ? Self.historyFirstRequest : nil)
            guard activeWatch == token else { return }
            watchId = id
            self.client = client
            following = transcript != nil
            if let transcript {
                follow = Task { [weak self] in
                    for await update in transcript {
                        guard let self, self.activeWatch == token else { return }
                        await self.apply(update)
                    }
                }
            }
            for try await frame in frames {
                let parsed = await Task.detached(priority: .userInitiated) { ANSIParser.parse(frame.text) }.value
                guard activeWatch == token else { return }
                lines = parsed
                screenText = frame.text
                await joinScreen()
                await rerender()
                lastFrameAt = .now
                status = .live
            }
            if activeWatch == token { status = .ended(nil) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, activeWatch == token { status = .ended(error.localizedDescription) }
        }
    }

    /// Takes in blocks from the gateway: the session's tail (on start, a
    /// reconnect, or a switch to another session) or ones Claude just added.
    private func apply(_ update: TranscriptUpdate) async {
        let sessionBefore = timeline.session
        await parse(update.blocks)
        timeline.apply(update)
        if timeline.session != sessionBefore {
            // Another session: nothing loaded before applies.
            let ids = Set(timeline.blocks.map(\.id))
            parsed = parsed.filter { ids.contains($0.key) }
            renderedBlocks = [:]
            gapErrors = [:]
        }
        firstLines = timeline.blocks.map { parsed[$0.id]?.lines.first?.plainText ?? "" }
        if usesTranscript {
            historyLines = []
            historyState = .loaded(more: false)
        } else if update.reset == true, historyState != .loading {
            // No session (yet): back to loading earlier output on request.
            historyState = .none
        }
        await joinScreen(force: true)
    }

    private func parse(_ blocks: [TranscriptBlock]) async {
        let fresh = blocks.filter { parsed[$0.id] == nil }
        guard !fresh.isEmpty else { return }
        let lines = await Task.detached(priority: .userInitiated) {
            fresh.map { ANSIParser.parse($0.lines.joined(separator: "\n")) }
        }.value
        for (block, lines) in zip(fresh, lines) {
            parsed[block.id] = (nextSerial, lines)
            nextSerial += 1
        }
    }

    /// Fetches the end of a gap (the part nearest what you're reading, since
    /// you reach gaps scrolling up); whatever's left stays a smaller gap.
    func fillGap(_ gap: TranscriptTimeline.Gap) async {
        guard usesTranscript, !fillingGaps.contains(gap.from), let watchId, let client else { return }
        fillingGaps.insert(gap.from)
        gapErrors[gap.from] = nil
        await rerenderHistory()
        do {
            let range = try await client.transcriptRange(watch: watchId, session: timeline.session, from: gap.from,
                                                         to: gap.to, lines: Self.gapFillLines)
            await parse(range.blocks)
            timeline.fill(gap, with: range)
            firstLines = timeline.blocks.map { parsed[$0.id]?.lines.first?.plainText ?? "" }
            fillingGaps.remove(gap.from)
            await joinScreen(force: true)
        } catch {
            fillingGaps.remove(gap.from)
            gapErrors[gap.from] = error.localizedDescription
            await rerenderHistory()
        }
    }

    /// Where the screen takes over from the transcript; re-renders the history
    /// when that moves.
    private func joinScreen(force: Bool = false) async {
        let newCut = usesTranscript ? TranscriptJoin.cut(firstLines: firstLines, screen: lines) : nil
        let changed = newCut?.block != cut?.block || (newCut == nil) != (cut == nil)
        cut = newCut
        historyJoined = newCut != nil
        if usesTranscript, changed || force { await rerenderHistory() }
    }

    /// Loads output from before the current screen (or more of it).
    /// `agent` is the pane's agent kind, if any ("claude" reads Claude's transcript).
    func loadEarlier(_ paneId: String, agent: String?, client: GatewayClient) async {
        guard historyState != .loading else { return }
        if usesTranscript {
            // Pull to refresh at the top: the top gap, if any.
            if case .gap(let gap)? = timeline.items.first { await fillGap(gap) }
            return
        }
        let request = historyRequest == 0 ? Self.historyFirstRequest : min(historyRequest * 2, Self.historyMaxRequest)
        let previousCount = historyLines.count
        historyState = .loading
        do {
            let (text, truncated, logical) = try await client.history(paneId: paneId, agent: agent, lines: request)
            historyLogical = logical
            let visible = lines
            let earlier = await Task.detached(priority: .userInitiated) {
                Scrollback.earlier(ANSIParser.parse(text), visible: visible)
            }.value
            // The transcript arrived meanwhile and took over.
            guard !usesTranscript else { return }
            historyRequest = request
            historyLines = earlier
            await rerenderHistory()
            if earlier.isEmpty {
                historyState = .empty
            } else {
                historyState = .loaded(more: truncated && request < Self.historyMaxRequest && earlier.count > previousCount)
            }
        } catch {
            if !usesTranscript { historyState = .failed(error.localizedDescription) }
        }
    }

    /// Fits the pane to this screen (or gives it back with nil), like a smaller
    /// tmux client: full-screen programs redraw at that size.
    func setFit(_ size: PaneSize?) async {
        guard size != fit else { return }
        fit = size
        if let watchId, let client { await client.fitWatch(watchId, to: size) }
    }

    func setLayout(fontSize size: CGFloat, wrapColumns columns: Int?, paneColumns pane: Int?, agentPane agent: Bool) async {
        guard size != fontSize || columns != wrapColumns || pane != paneColumns || agent != agentPane else { return }
        fontSize = size
        wrapColumns = columns
        paneColumns = pane
        agentPane = agent
        renderedBlocks = [:]
        await rerender()
        await rerenderHistory()
    }

    private func rerender() async {
        let size = fontSize
        let columns = wrapColumns
        let pane = drawnColumns
        let agent = agentPane
        let shown = cut.map { Array(lines[min($0.line, lines.count)...]) } ?? lines
        segments = await Self.render(shown, size: size, columns: columns, pane: pane, agent: agent)
    }

    /// History doesn't change with live frames, only when loaded, re-laid out,
    /// or (Claude) when the screen's join with the transcript moves.
    private func rerenderHistory() async {
        guard usesTranscript else {
            history = historyLines.isEmpty ? [] : await Self.render(historyLines, size: fontSize, columns: wrapColumns,
                                                                     pane: drawnColumns, agent: agentPane,
                                                                     reflow: !historyLogical).map(HistoryRow.segment)
            return
        }
        // Everything before the block the screen takes over at, gaps included.
        let upTo = cut?.block ?? Int.max
        var shown: [TranscriptTimeline.Item] = []
        var count = 0
        for item in timeline.items {
            if case .block = item {
                if count == upTo { break }
                count += 1
            }
            shown.append(item)
        }
        let missing: [(id: String, serial: Int, lines: [StyledLine])] = shown.compactMap {
            guard case .block(let b) = $0, renderedBlocks[b.id] == nil, let p = parsed[b.id] else { return nil }
            return (b.id, p.serial, p.lines)
        }
        if !missing.isEmpty {
            let (size, columns, pane, agent) = (fontSize, wrapColumns, drawnColumns, agentPane)
            let rendered = await Task.detached(priority: .userInitiated) {
                missing.map { block in
                    // A blank line between blocks, as on Claude's screen.
                    Self.renderNow([StyledLine(runs: [])] + block.lines, size: size, columns: columns, pane: pane,
                                   agent: agent, reflow: false)
                        .map { $0.withId(block.serial * 1000 + $0.id) }
                }
            }.value
            for (block, segments) in zip(missing, rendered) { renderedBlocks[block.id] = segments }
        }
        history = shown.flatMap { item -> [HistoryRow] in
            switch item {
            case .block(let b):
                return (renderedBlocks[b.id] ?? []).map(HistoryRow.segment)
            case .gap(let g):
                return [.gap(GapRow(gap: g, loading: fillingGaps.contains(g.from), error: gapErrors[g.from]))]
            }
        }
    }

    /// The width the pane's program drew at, which can be less than herdr's layout says.
    private var drawnColumns: Int? {
        agentPane ? TerminalSegmenter.drawnColumns(lines, layout: paneColumns) : paneColumns
    }

    private static func render(_ lines: [StyledLine], size: CGFloat, columns: Int?, pane: Int?, agent: Bool,
                               reflow: Bool = true) async -> [RenderedSegment] {
        await Task.detached(priority: .userInitiated) {
            renderNow(lines, size: size, columns: columns, pane: pane, agent: agent, reflow: reflow)
        }.value
    }

    nonisolated private static func renderNow(_ lines: [StyledLine], size: CGFloat, columns: Int?, pane: Int?, agent: Bool,
                                              reflow: Bool) -> [RenderedSegment] {
        TerminalSegmenter.segment(lines, columns: pane, agentPane: agent).map { seg in
            // When wrapping to the phone, undo the agent's wrapping at the Mac's width
            // first, so prose wraps once (here) instead of twice.
            var shown = seg.lines
            if reflow, seg.kind == .message, columns != nil, let pane {
                shown = TerminalSegmenter.reflowed(shown, columns: pane)
            }
            let fitted = shown.fittingRules(to: columns)
            var rendered = RenderedSegment(id: seg.id, kind: seg.kind,
                                           text: TerminalRenderer.render(fitted, fontSize: size, paneColumns: pane),
                                           copyText: seg.copyText)
            // A view per line; very long segments (big transcripts) stay one Text to keep scrolling smooth.
            if seg.kind == .message, columns != nil, fitted.count <= 300 {
                rendered.paragraphs = fitted.enumerated().map { i, line in
                    let n = line.isHorizontalRule ? 0 : line.hangingIndent
                    let (head, body) = n > 0 ? line.split(at: n) : (StyledLine(runs: []), line)
                    // A blank line still needs its height.
                    let bodyLine = body.plainText.isEmpty ? StyledLine(runs: [StyledRun(text: " ", style: TermStyle())]) : body
                    return RenderedParagraph(id: i,
                                             hang: n > 0 ? TerminalRenderer.render([head], fontSize: size) : nil,
                                             body: TerminalRenderer.render([bodyLine], fontSize: size))
                }
            }
            return rendered
        }
    }
}

/// A row above the live screen: rendered output, or a stretch of a Claude
/// session not loaded yet.
enum HistoryRow: Identifiable, Sendable {
    case segment(RenderedSegment)
    case gap(GapRow)

    var id: String {
        switch self {
        case .segment(let s): "s\(s.id)"
        case .gap(let g): "g\(g.gap.from)"
        }
    }
}

struct GapRow: Equatable, Sendable {
    let gap: TranscriptTimeline.Gap
    let loading: Bool
    let error: String?
}

extension RenderedSegment {
    func withId(_ id: Int) -> RenderedSegment {
        var copy = RenderedSegment(id: id, kind: kind, text: text, copyText: copyText)
        copy.paragraphs = paragraphs
        return copy
    }
}
