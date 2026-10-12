import Foundation

// herdr's `pane.read` with format "ansi" returns rendered rows joined by \r\n
// using only SGR escapes (ESC [ ... m) — no cursor movement — so a small SGR
// parser is enough, and lets the app reflow text to the phone's width.

public enum TermColor: Sendable, Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TermStyle: Sendable, Hashable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false

    public init() {}
}

public struct StyledRun: Sendable, Hashable {
    public var text: String
    public var style: TermStyle
}

public struct StyledLine: Sendable, Hashable {
    public var runs: [StyledRun]

    public var plainText: String { runs.map(\.text).joined() }

    private static let ruleCharacters: Set<Character> = ["─", "━", "═", "-", "—", "▁", "▔", "╌", "┄"]

    /// A full-width separator (only rule characters and spaces), which would
    /// otherwise wrap into several lines on a narrow screen.
    public var isHorizontalRule: Bool {
        var sawRule = false
        for ch in plainText where ch != " " {
            guard Self.ruleCharacters.contains(ch) else { return false }
            sawRule = true
        }
        return sawRule
    }

    /// Keeps the first `columns` characters, preserving styles.
    public func clipped(to columns: Int) -> StyledLine {
        var remaining = max(0, columns)
        var out: [StyledRun] = []
        for run in runs where remaining > 0 {
            let piece = String(run.text.prefix(remaining))
            remaining -= piece.count
            out.append(StyledRun(text: piece, style: run.style))
        }
        return StyledLine(runs: out)
    }
}

extension Array where Element == StyledLine {
    /// For wrapped display: clip separator lines to the visible width.
    public func fittingRules(to columns: Int?) -> [StyledLine] {
        guard let columns, columns > 0 else { return self }
        return map { $0.isHorizontalRule && $0.plainText.count > columns ? $0.clipped(to: columns) : $0 }
    }
}

public enum ANSIParser {
    /// Parses ANSI text into styled lines. Trailing blank padding (spaces with no
    /// background) and trailing empty lines are dropped.
    public static func parse(_ text: String) -> [StyledLine] {
        var lines: [StyledLine] = []
        var runs: [StyledRun] = []
        var buffer = ""
        var style = TermStyle()

        func flushRun() {
            guard !buffer.isEmpty else { return }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += buffer
            } else {
                runs.append(StyledRun(text: buffer, style: style))
            }
            buffer = ""
        }
        func endLine() {
            flushRun()
            lines.append(StyledLine(runs: trimTrailing(runs)))
            runs = []
        }

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "\u{1B}":
                // CSI: ESC [ params final
                if i + 1 < scalars.count, scalars[i + 1] == "[" {
                    var j = i + 2
                    var params = ""
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                        params.unicodeScalars.append(scalars[j])
                        j += 1
                    }
                    if j < scalars.count, scalars[j] == "m" {
                        flushRun()
                        applySGR(params, to: &style)
                    }
                    i = j + 1
                } else {
                    i += 2  // drop other two-byte escapes
                }
                continue
            case "\n":
                endLine()
            case "\r":
                break
            case "\t":
                buffer += "    "
            default:
                if c.value >= 0x20 && c.value != 0x7F {
                    buffer.unicodeScalars.append(c)
                }
            }
            i += 1
        }
        endLine()
        while let last = lines.last, last.runs.isEmpty { lines.removeLast() }
        return lines
    }

    private static func trimTrailing(_ runs: [StyledRun]) -> [StyledRun] {
        var runs = runs
        while let last = runs.last, last.style.bg == .default, !last.style.inverse {
            let trimmed = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
            if trimmed.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = trimmed
                break
            }
        }
        return runs
    }

    static func applySGR(_ raw: String, to style: inout TermStyle) {
        // Colon sub-parameters (e.g. 38:2::r:g:b, 4:3) are flattened into the
        // parameter list; the extended-color reader below skips the empty colorspace slot.
        let usesColons = raw.contains(":")
        var params = raw.split(separator: ";", omittingEmptySubsequences: false).flatMap { part -> [Int?] in
            part.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        }
        if params.isEmpty { params = [0] }
        var i = 0
        func extendedColor() -> TermColor? {
            guard i + 1 < params.count, let mode = params[i + 1] else { return nil }
            if mode == 5, i + 2 < params.count, let n = params[i + 2] {
                i += 2
                return .indexed(UInt8(clamping: n))
            }
            if mode == 2 {
                // 38;2;r;g;b or 38:2::r:g:b (empty colorspace id)
                var k = i + 2
                if usesColons, k < params.count, params[k] == nil, k + 3 < params.count { k += 1 }
                guard k + 2 < params.count, let r = params[k], let g = params[k + 1], let b = params[k + 2] else {
                    return nil
                }
                i = k + 2
                return .rgb(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
            }
            return nil
        }
        while i < params.count {
            let p = params[i] ?? 0
            switch p {
            case 0: style = TermStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4:
                // 4:0 turns underline off
                if usesColons, i + 1 < params.count, params[i + 1] == 0 {
                    style.underline = false
                    i += 1
                } else {
                    style.underline = true
                }
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 21: style.underline = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.fg = .indexed(UInt8(p - 30))
            case 38: if let c = extendedColor() { style.fg = c }
            case 39: style.fg = .default
            case 40...47: style.bg = .indexed(UInt8(p - 40))
            case 48: if let c = extendedColor() { style.bg = c }
            case 49: style.bg = .default
            case 58: _ = extendedColor()  // underline color: ignored
            case 90...97: style.fg = .indexed(UInt8(p - 90 + 8))
            case 100...107: style.bg = .indexed(UInt8(p - 100 + 8))
            default: break
            }
            i += 1
        }
    }
}

public struct RGB: Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
    public init(hex: UInt32) {
        self.init(UInt8(hex >> 16 & 0xFF), UInt8(hex >> 8 & 0xFF), UInt8(hex & 0xFF))
    }
}

public struct TerminalPalette: Sendable {
    public var foreground: RGB
    public var background: RGB
    public var ansi: [RGB]  // 16 entries

    /// Matches herdr's `gruvbox` theme.
    public static let gruvboxDark = TerminalPalette(
        foreground: RGB(hex: 0xEBDBB2),
        background: RGB(hex: 0x1D2021),
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2].map(RGB.init(hex:)))

    /// Resolves a color to RGB; `nil` means "use the default fg/bg".
    public func resolve(_ color: TermColor) -> RGB? {
        switch color {
        case .default: return nil
        case .rgb(let r, let g, let b): return RGB(r, g, b)
        case .indexed(let n): return Self.xterm256(n, ansi: ansi)
        }
    }

    static func xterm256(_ n: UInt8, ansi: [RGB]) -> RGB {
        switch n {
        case 0..<16:
            return ansi[Int(n)]
        case 16..<232:
            let v = Int(n) - 16
            let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
            return RGB(steps[v / 36], steps[(v / 6) % 6], steps[v % 6])
        default:
            let level = UInt8(8 + (Int(n) - 232) * 10)
            return RGB(level, level, level)
        }
    }
}
