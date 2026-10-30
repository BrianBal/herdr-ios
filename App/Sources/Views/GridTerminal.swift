import HerdrKit
import SwiftUI

/// A pane drawn as the terminal grid it is: every row exactly as the program
/// drew it, never re-wrapped, sized so the widest row fits the screen and
/// zoomed from there (like Safari with a page made for a desktop). Boxes,
/// tables and side-by-side layouts stay intact.
///
/// History comes in stretches of different widths (the pane was wider on the
/// Mac, say), so each chunk of rows is shrunk to fit on its own instead of
/// making everything as small as the widest.
enum GridTerminal {
    /// SF Mono's advance per point of font size.
    static let advance: CGFloat = 0.602
    /// Rows per Text: few enough that a chunk renders quickly, many enough
    /// that a long history isn't thousands of views.
    static let chunkRows = 40
    /// How far past the aA size you can zoom in.
    static let maxZoomOverText: CGFloat = 3
    /// Panes split narrower than this are widened to it while viewed.
    static let minColumns = 80

    static func lineHeight(_ fontSize: CGFloat) -> CGFloat {
        UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).lineHeight
    }

    /// Cells in the widest row.
    static func columns(_ lines: [StyledLine]) -> Int {
        lines.reduce(0) { max($0, $1.plainText.count) }
    }

    /// The font size at which `columns` fill `width`.
    static func fitFont(columns: Int, width: CGFloat) -> CGFloat {
        guard columns > 0, width > 0 else { return 11 }
        return width / (CGFloat(columns) * advance)
    }

    /// Zoom (1 = fit to width) can go up to a few times the aA size, and never below fit.
    static func maxZoom(fitFont: CGFloat, textSize: CGFloat) -> CGFloat {
        max(1, maxZoomOverText * textSize / fitFont)
    }
}

/// Rows of the grid at one font size, in chunks; a chunk wider than
/// `columns` is drawn smaller so it fits too. Lazy, with every chunk's size
/// known from its row count, so a long history isn't laid out (on a zoom,
/// say) until it's scrolled to.
struct GridRows: View {
    let lines: [StyledLine]
    /// Cells across at `fontSize`: the screen's width.
    let columns: Int
    let fontSize: CGFloat

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<chunkCount, id: \.self) { i in
                let rows = Array(lines[(i * GridTerminal.chunkRows)..<min(lines.count, (i + 1) * GridTerminal.chunkRows)])
                let font = fontSize * scale(rows)
                GridChunk(lines: rows, fontSize: font, columns: columns)
                    .equatable()
                    .frame(width: CGFloat(columns) * GridTerminal.advance * fontSize,
                           height: CGFloat(rows.count) * GridTerminal.lineHeight(font), alignment: .topLeading)
            }
        }
    }

    private var chunkCount: Int { (lines.count + GridTerminal.chunkRows - 1) / GridTerminal.chunkRows }

    private func scale(_ rows: [StyledLine]) -> CGFloat {
        let wide = GridTerminal.columns(rows)
        return wide > columns ? CGFloat(columns) / CGFloat(wide) : 1
    }
}

private struct GridChunk: View, Equatable {
    let lines: [StyledLine]
    let fontSize: CGFloat
    let columns: Int

    var body: some View {
        Text(TerminalRenderer.render(lines, fontSize: fontSize, paneColumns: columns))
            .lineLimit(nil)
            .fixedSize()
    }
}

/// Holds a drag in the enclosing scroll view to the direction it started in,
/// so reading down a wide pane doesn't drift sideways (SwiftUI's ScrollView
/// has no setting for it). Put it in the scroll view's content.
struct DirectionalScrollLock: UIViewRepresentable {
    func makeUIView(context: Context) -> LockView { LockView() }
    func updateUIView(_ view: LockView, context: Context) {}

    final class LockView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            (view as? UIScrollView)?.isDirectionalLockEnabled = true
        }
    }
}
