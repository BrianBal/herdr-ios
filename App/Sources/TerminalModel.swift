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
@MainActor @Observable
final class TerminalModel {
    enum Status: Equatable {
        case loading
        case live
        case ended(String?)
    }

    private(set) var segments: [RenderedSegment] = []
    /// Earlier output loaded on request, shown above the live screen.
    private(set) var history: [RenderedSegment] = []
    private(set) var historyState: HistoryState = .none
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

    var isEmpty: Bool { segments.isEmpty }

    /// Runs until cancelled or the watch ends (socket drop, pane closed).
    func watch(_ paneId: String, client: GatewayClient) async {
        status = .loading
        do {
            let frames = try await client.watchPane(paneId)
            for try await frame in frames {
                let parsed = await Task.detached(priority: .userInitiated) { ANSIParser.parse(frame.text) }.value
                lines = parsed
                await rerender()
                lastFrameAt = .now
                status = .live
            }
            status = .ended(nil)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { status = .ended(error.localizedDescription) }
        }
    }

    /// Loads output from before the current screen (or more of it).
    /// `agent` is the pane's agent kind, if any ("claude" reads Claude's transcript).
    func loadEarlier(_ paneId: String, agent: String?, client: GatewayClient) async {
        guard historyState != .loading else { return }
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
            historyRequest = request
            historyLines = earlier
            await rerenderHistory()
            if earlier.isEmpty {
                historyState = .empty
            } else {
                historyState = .loaded(more: truncated && request < Self.historyMaxRequest && earlier.count > previousCount)
            }
        } catch {
            historyState = .failed(error.localizedDescription)
        }
    }

    func setLayout(fontSize size: CGFloat, wrapColumns columns: Int?, paneColumns pane: Int?, agentPane agent: Bool) async {
        guard size != fontSize || columns != wrapColumns || pane != paneColumns || agent != agentPane else { return }
        fontSize = size
        wrapColumns = columns
        paneColumns = pane
        agentPane = agent
        await rerender()
        await rerenderHistory()
    }

    private func rerender() async {
        let size = fontSize
        let columns = wrapColumns
        let pane = drawnColumns
        let agent = agentPane
        segments = await Self.render(lines, size: size, columns: columns, pane: pane, agent: agent)
    }

    /// History doesn't change with live frames, only when loaded or re-laid out.
    private func rerenderHistory() async {
        history = historyLines.isEmpty ? [] : await Self.render(historyLines, size: fontSize, columns: wrapColumns,
                                                                 pane: drawnColumns, agent: agentPane,
                                                                 reflow: !historyLogical)
    }

    /// The width the pane's program drew at, which can be less than herdr's layout says.
    private var drawnColumns: Int? {
        agentPane ? TerminalSegmenter.drawnColumns(lines, layout: paneColumns) : paneColumns
    }

    private static func render(_ lines: [StyledLine], size: CGFloat, columns: Int?, pane: Int?, agent: Bool,
                               reflow: Bool = true) async -> [RenderedSegment] {
        await Task.detached(priority: .userInitiated) {
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
        }.value
    }
}
