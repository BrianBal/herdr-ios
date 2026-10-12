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

    func setLayout(fontSize size: CGFloat, wrapColumns columns: Int?, paneColumns pane: Int?, agentPane agent: Bool) async {
        guard size != fontSize || columns != wrapColumns || pane != paneColumns || agent != agentPane else { return }
        fontSize = size
        wrapColumns = columns
        paneColumns = pane
        agentPane = agent
        await rerender()
    }

    private func rerender() async {
        let lines = self.lines
        let size = fontSize
        let columns = wrapColumns
        let pane = paneColumns
        let agent = agentPane
        segments = await Task.detached(priority: .userInitiated) {
            TerminalSegmenter.segment(lines, columns: pane, agentPane: agent).map { seg in
                RenderedSegment(id: seg.id, kind: seg.kind,
                                text: TerminalRenderer.render(seg.lines.fittingRules(to: columns), fontSize: size,
                                                              paneColumns: pane),
                                copyText: seg.copyText)
            }
        }.value
    }
}
