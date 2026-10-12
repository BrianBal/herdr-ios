import Foundation

extension StyledLine {
    /// Splits the line at a character offset, keeping each side's styling.
    public func split(at offset: Int) -> (StyledLine, StyledLine) {
        var head: [StyledRun] = []
        var tail: [StyledRun] = []
        var remaining = offset
        for run in runs {
            if remaining <= 0 {
                tail.append(run)
            } else if run.text.count <= remaining {
                head.append(run)
                remaining -= run.text.count
            } else {
                let cut = run.text.index(run.text.startIndex, offsetBy: remaining)
                head.append(StyledRun(text: String(run.text[..<cut]), style: run.style))
                tail.append(StyledRun(text: String(run.text[cut...]), style: run.style))
                remaining = 0
            }
        }
        return (StyledLine(runs: head), StyledLine(runs: tail))
    }

    /// How many leading characters should hang: the indent plus a list or
    /// message marker ("- ", "1. ", "⏺ ", "❯ "), so wrapped text lines up
    /// after them. 0 when there's nothing to hang.
    public var hangingIndent: Int {
        let text = plainText
        let indent = text.prefix(while: { $0 == " " }).count
        let rest = text.dropFirst(indent)
        let markers: [String] = ["⏺ ", "● ", "• ", "❯ ", "› ", "- ", "* ", "+ ", "└ ", "⎿ "]
        if let m = markers.first(where: { rest.hasPrefix($0) }) {
            return indent + m.count + rest.dropFirst(m.count).prefix(while: { $0 == " " }).count
        }
        let digits = rest.prefix(while: \.isNumber)
        if (1...3).contains(digits.count) {
            let after = rest.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return indent + digits.count + 2
            }
        }
        // Plain indented text (a continuation paragraph) hangs at its indent.
        return indent < text.count ? indent : 0
    }
}
