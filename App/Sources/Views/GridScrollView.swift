import CoreText
import HerdrKit
import SwiftUI
import UIKit

/// A pane drawn as its terminal grid in a UIKit scroll view, zoomed natively:
/// the grid is redrawn at the exact zoom on every frame of a pinch (glyphs
/// drawn scaled stay sharp), around the point under your fingers, so nothing
/// snaps when you let go. Above the grid, `top` (the history header, Claude's
/// transcript, the Live divider) is ordinary SwiftUI at its normal size.
///
/// Keeps your place: rows arriving above what you're reading (history
/// loading, rows kept as they scroll off) don't move it, and at the bottom it
/// follows the live screen.
struct GridPaneView<Top: View>: UIViewRepresentable {
    let top: Top
    /// Earlier rows drawn as the grid (empty when history is Claude's transcript, in `top`).
    let history: [StyledLine]
    let screen: [StyledLine]
    /// Cells across: the grid's width at fit.
    let columns: Int
    /// Most zoomed in, relative to fit.
    let maxZoom: CGFloat
    /// Changes each time the pane is opened: back to fit, at the bottom.
    let openCount: Int
    /// Within a screen of the top; `short` when everything fits on one screen.
    var onNearTop: (_ short: Bool) -> Void
    var onScrollStart: () -> Void
    var onTap: () -> Void

    func makeUIView(context: Context) -> GridScrollView {
        let view = GridScrollView()
        view.host = UIHostingController(rootView: AnyView(EmptyView()))
        return view
    }

    func updateUIView(_ view: GridScrollView, context: Context) {
        view.callbacks = (onNearTop, onScrollStart, onTap)
        view.maxZoom = maxZoom
        view.host?.rootView = AnyView(
            top
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak view] in view?.setTopHeight($0) }
                .frame(maxHeight: .infinity, alignment: .top)
        )
        view.update(history: history, screen: screen, columns: columns, openCount: openCount)
    }
}

final class GridScrollView: UIScrollView, UIScrollViewDelegate {
    var host: UIHostingController<AnyView>? {
        didSet {
            guard let host else { return }
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            addSubview(host.view)
        }
    }
    var callbacks: (nearTop: (Bool) -> Void, scrollStart: () -> Void, tap: () -> Void) = ({ _ in }, {}, {})
    var maxZoom: CGFloat = 3

    private let canvas = GridCanvas()
    private var zoom: CGFloat = 1
    private var topHeight: CGFloat = 0
    private var columns = 80
    private var openCount = -1
    private var history: [StyledLine] = []
    private var screen: [StyledLine] = []
    /// Following the live screen at the bottom.
    private var pinnedToBottom = true

    static let pad = CGPoint(x: 8, y: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        alwaysBounceVertical = true
        isDirectionalLockEnabled = true
        keyboardDismissMode = .interactive
        contentInsetAdjustmentBehavior = .never
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        addSubview(canvas)

        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        double.cancelsTouchesInView = false
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        single.cancelsTouchesInView = false
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// Font size at fit: `columns` cells fill the width inside the padding.
    private var fitFont: CGFloat {
        GridTerminal.fitFont(columns: columns, width: bounds.width - 2 * Self.pad.x)
    }
    private var gridTop: CGFloat { topHeight + Self.pad.y }
    /// Where the live screen starts, in content coordinates.
    private var screenTop: CGFloat { gridTop + canvas.historyHeight * zoom }
    private var maxOffset: CGPoint {
        CGPoint(x: max(0, contentSize.width - bounds.width), y: max(minOffsetY, contentSize.height - bounds.height))
    }
    /// A screen shorter than the view sits at its bottom, like a terminal: the
    /// space above is an inset.
    private var minOffsetY: CGFloat { -contentInset.top }

    func update(history: [StyledLine], screen: [StyledLine], columns: Int, openCount: Int) {
        if openCount != self.openCount {
            self.openCount = openCount
            zoom = 1
            pinnedToBottom = true
        }
        let readingFromScreen = contentOffset.y - screenTop
        let historyChanged = history != self.history
        self.history = history
        self.screen = screen
        self.columns = columns
        canvas.set(history: history, screen: screen, historyChanged: historyChanged, columns: columns, font: fitFont)
        relayout(keeping: readingFromScreen)
    }

    func setTopHeight(_ height: CGFloat) {
        guard abs(height - topHeight) > 0.5 else { return }
        let readingFromScreen = contentOffset.y - screenTop
        topHeight = height
        relayout(keeping: readingFromScreen)
    }

    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            canvas.set(history: history, screen: screen, historyChanged: true, columns: columns, font: fitFont)
            relayout(keeping: contentOffset.y - screenTop)
        }
        canvas.frame = bounds
    }

    /// Sizes the content for the current zoom and puts the view back: at the
    /// bottom if it was following it, else the same distance from the live screen.
    private func relayout(keeping readingFromScreen: CGFloat) {
        guard bounds.width > 0 else { return }
        host?.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topHeight)
        let width = (bounds.width - 2 * Self.pad.x) * zoom + 2 * Self.pad.x
        let height = gridTop + canvas.gridHeight * zoom + Self.pad.y
        contentSize = CGSize(width: max(bounds.width, width), height: height)
        let inset = max(0, bounds.height - height)
        if abs(contentInset.top - inset) > 0.5 { contentInset.top = inset }
        var offset = contentOffset
        offset.y = pinnedToBottom ? maxOffset.y : min(max(minOffsetY, screenTop + readingFromScreen), maxOffset.y)
        offset.x = min(offset.x, maxOffset.x)
        if offset != contentOffset { contentOffset = offset }
        redraw()
        // A short screen is "near the top" without any scrolling.
        if inset > 0 { callbacks.nearTop(true) }
    }

    private func redraw() {
        // The transcript above the grid doesn't zoom, so it doesn't pan sideways either.
        host?.view.frame.origin.x = contentOffset.x
        canvas.frame = bounds
        canvas.view = (offset: contentOffset, zoom: zoom, gridTop: gridTop)
        canvas.setNeedsDisplay()
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        redraw()
        if isTracking || isDecelerating {
            pinnedToBottom = contentOffset.y >= maxOffset.y - 4
        }
        if contentOffset.y < bounds.height { callbacks.nearTop(contentSize.height <= bounds.height) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        callbacks.scrollStart()
    }

    // MARK: Zoom

    /// The pinch's anchor: a point of the grid at zoom 1 (nil when it started
    /// above the grid, in the transcript, which doesn't zoom).
    private var anchor: CGPoint?
    private var startZoom: CGFloat = 1

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        let point = pinch.location(in: self)
        switch pinch.state {
        case .began:
            startZoom = zoom
            anchor = gridPoint(at: point)
            callbacks.scrollStart()
        case .changed:
            setZoom(startZoom * pinch.scale, keeping: anchor, at: CGPoint(x: point.x - contentOffset.x, y: point.y - contentOffset.y))
        default:
            anchor = nil
        }
    }

    /// The grid point (at zoom 1) under a content point.
    private func gridPoint(at point: CGPoint) -> CGPoint? {
        guard point.y >= gridTop else { return nil }
        return CGPoint(x: (point.x - Self.pad.x) / zoom, y: (point.y - gridTop) / zoom)
    }

    /// Zooms so the grid point `anchor` sits at `viewPoint` in the viewport.
    private func setZoom(_ target: CGFloat, keeping anchor: CGPoint?, at viewPoint: CGPoint) {
        let new = min(maxZoom, max(1, target))
        zoom = new
        pinnedToBottom = false
        let width = (bounds.width - 2 * Self.pad.x) * zoom + 2 * Self.pad.x
        let height = gridTop + canvas.gridHeight * zoom + Self.pad.y
        contentSize = CGSize(width: max(bounds.width, width), height: height)
        contentInset.top = max(0, bounds.height - height)
        var offset = contentOffset
        if let anchor {
            offset.x = Self.pad.x + anchor.x * zoom - viewPoint.x
            offset.y = gridTop + anchor.y * zoom - viewPoint.y
        }
        offset.x = min(max(0, offset.x), maxOffset.x)
        offset.y = min(max(minOffsetY, offset.y), maxOffset.y)
        contentOffset = offset
        if offset.y >= maxOffset.y - 4 { pinnedToBottom = true }
        redraw()
    }

    private var animation: CADisplayLink?
    private var animationFrom: (zoom: CGFloat, start: CFTimeInterval)?
    private var animationTo: (zoom: CGFloat, anchor: CGPoint?, viewPoint: CGPoint)?

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: self)
        let target: CGFloat = zoom > 1.01 ? 1 : min(2, maxZoom)
        animationFrom = (zoom, CACurrentMediaTime())
        animationTo = (target, gridPoint(at: point), CGPoint(x: point.x - contentOffset.x, y: point.y - contentOffset.y))
        animation?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        animation = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let from = animationFrom, let to = animationTo else { return link.invalidate() }
        let t = min(1, (CACurrentMediaTime() - from.start) / 0.25)
        let eased = 1 - pow(1 - t, 3)
        setZoom(from.zoom + (to.zoom - from.zoom) * eased, keeping: to.anchor, at: to.viewPoint)
        if t >= 1 {
            link.invalidate()
            animation = nil
        }
    }

    @objc private func tapped() { callbacks.tap() }
}

/// Draws the grid rows that are on screen, at the scroll view's zoom. Rows
/// are kept as CTLines at the fit size and drawn scaled, so they're sharp at
/// any zoom; each 40-row chunk wider than the grid is drawn smaller to fit.
final class GridCanvas: UIView {
    var view: (offset: CGPoint, zoom: CGFloat, gridTop: CGFloat) = (.zero, 1, 0)
    /// Heights at zoom 1.
    private(set) var historyHeight: CGFloat = 0
    private(set) var gridHeight: CGFloat = 0

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var scale: CGFloat
        var line: StyledLine
    }
    private var rows: [Row] = []
    private var historyCount = 0
    private var font: CGFloat = 11
    private var cache: [Int: DrawnLine] = [:]

    func set(history: [StyledLine], screen: [StyledLine], historyChanged: Bool, columns: Int, font: CGFloat) {
        if historyChanged || abs(font - self.font) > 0.001 { cache = [:] }
        // Screen rows change with every frame.
        for i in historyCount..<max(historyCount, rows.count) { cache[i] = nil }
        self.font = font
        rows = []
        var y: CGFloat = 0
        func add(_ lines: [StyledLine]) {
            for start in stride(from: 0, to: lines.count, by: GridTerminal.chunkRows) {
                let chunk = lines[start..<min(lines.count, start + GridTerminal.chunkRows)]
                let wide = chunk.reduce(0) { max($0, $1.plainText.count) }
                let scale = wide > columns ? CGFloat(columns) / CGFloat(wide) : 1
                let height = GridTerminal.lineHeight(font * scale)
                for line in chunk {
                    rows.append(Row(y: y, height: height, scale: scale, line: line))
                    y += height
                }
            }
        }
        add(history)
        historyHeight = y
        historyCount = history.count
        add(screen)
        gridHeight = y
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !rows.isEmpty else { return }
        let (offset, zoom, gridTop) = view
        // Visible grid range at zoom 1.
        let top = (offset.y - gridTop) / zoom
        let bottom = (offset.y + bounds.height - gridTop) / zoom
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].y + rows[mid].height < top { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < rows.count, rows[i].y <= bottom {
            let row = rows[i]
            let drawn = cache[i] ?? DrawnLine(row.line, font: font)
            cache[i] = drawn
            let k = zoom * row.scale
            let origin = CGPoint(x: GridScrollView.pad.x - offset.x, y: gridTop + row.y * zoom - offset.y)
            drawn.draw(in: ctx, at: origin, scale: k, rowHeight: row.height * zoom)
            i += 1
        }
    }
}

/// One row ready to draw: its text as a CTLine at the fit size, and the
/// background runs (by cell) behind it.
private struct DrawnLine {
    let line: CTLine
    let backgrounds: [(cells: Range<Int>, color: CGColor)]
    let underlines: [Range<Int>]
    let ascent: CGFloat
    let advance: CGFloat

    init(_ styled: StyledLine, font size: CGFloat) {
        let regular = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let palette = TerminalRenderer.palette
        let text = NSMutableAttributedString()
        var backgrounds: [(Range<Int>, CGColor)] = []
        var underlines: [Range<Int>] = []
        var cell = 0
        for run in styled.runs {
            let s = run.style
            var fg = palette.resolve(s.fg) ?? palette.foreground
            var bg = palette.resolve(s.bg)
            if s.inverse {
                let oldFg = fg
                fg = bg ?? palette.background
                bg = oldFg
            }
            if s.dim { fg = TerminalRenderer.blend(fg, bg ?? palette.background, 0.45) }
            let cells = run.text.count
            if let bg { backgrounds.append((cell..<cell + cells, Self.cg(bg))) }
            if s.underline { underlines.append(cell..<cell + cells) }
            cell += cells
            text.append(NSAttributedString(string: run.text, attributes: [
                .font: s.bold ? bold : regular,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): Self.cg(fg),
            ]))
        }
        line = CTLineCreateWithAttributedString(text)
        self.backgrounds = backgrounds
        self.underlines = underlines
        ascent = regular.ascender
        advance = size * GridTerminal.advance
    }

    static func cg(_ c: RGB) -> CGColor {
        CGColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    func draw(in ctx: CGContext, at origin: CGPoint, scale k: CGFloat, rowHeight: CGFloat) {
        for (cells, color) in backgrounds {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: origin.x + CGFloat(cells.lowerBound) * advance * k, y: origin.y,
                            width: CGFloat(cells.count) * advance * k + 0.5, height: rowHeight + 0.5))
        }
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y + ascent * k)
        ctx.scaleBy(x: k, y: -k)
        ctx.textMatrix = .identity
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        for cells in underlines {
            ctx.setFillColor(TerminalRenderer.palette.foreground.cgColor)
            ctx.fill(CGRect(x: origin.x + CGFloat(cells.lowerBound) * advance * k, y: origin.y + (ascent + 1.5) * k,
                            width: CGFloat(cells.count) * advance * k, height: max(0.5, 0.6 * k)))
        }
    }
}

private extension RGB {
    var cgColor: CGColor { CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}
