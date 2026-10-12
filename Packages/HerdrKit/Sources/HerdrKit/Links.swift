import Foundation

/// Finds http(s) URLs in terminal lines, including ones the program wrapped
/// onto following lines (terminal-width wraps, or an agent breaking a long URL
/// at a `-` or `/`).
public enum LinkDetector {
    /// One URL and where it sits: a character range per line it spans.
    public struct Link: Sendable, Hashable {
        public var url: URL
        public var pieces: [Piece]
    }

    public struct Piece: Sendable, Hashable {
        public var line: Int
        /// Character offsets within the line.
        public var range: Range<Int>
    }

    static let start = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#)
    static let urlChars = try! NSRegularExpression(pattern: #"^[^\s<>"'`]+"#)

    /// - Parameter columns: the program's line width, if known; a URL that runs
    ///   to it is assumed to continue on the next line.
    public static func links(in lines: [String], columns: Int? = nil) -> [Link] {
        var links: [Link] = []
        var line = 0
        var skipUntil: (line: Int, offset: Int)? = nil
        while line < lines.count {
            let text = lines[line]
            let ns = text as NSString
            for match in start.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let lower = characterOffset(text, utf16: match.range.location)
                if let skip = skipUntil, skip.line == line, lower < skip.offset { continue }
                let first = ns.substring(with: match.range)
                var pieces = [Piece(line: line, range: lower..<(lower + first.count))]
                var url = first
                // Follow the URL onto the next lines while it looks wrapped.
                var current = line
                while current + 1 < lines.count,
                      pieces.last!.range.upperBound == trimmedLength(lines[current]),
                      let next = continuation(of: url, lineLength: trimmedLength(lines[current]),
                                              in: lines[current + 1], columns: columns)
                {
                    current += 1
                    pieces.append(Piece(line: current, range: next.range))
                    url += next.text
                }
                let (trimmed, dropped) = trimTrailing(url)
                if dropped > 0 {
                    var last = pieces.removeLast()
                    let cut = min(dropped, last.range.count)
                    last.range = last.range.lowerBound..<(last.range.upperBound - cut)
                    if !last.range.isEmpty { pieces.append(last) }
                }
                if let u = URL(string: trimmed), u.host != nil, !pieces.isEmpty {
                    links.append(Link(url: u, pieces: pieces))
                }
                if current > line { skipUntil = (current, pieces.last?.range.upperBound ?? 0) }
            }
            line += 1
        }
        return links
    }

    /// Whether `next` carries on a URL that ended a line, and if so the part of it that does.
    static func continuation(of url: String, lineLength: Int, in next: String, columns: Int?)
        -> (text: String, range: Range<Int>)?
    {
        let indent = next.prefix(while: { $0 == " " }).count
        let rest = String(next.dropFirst(indent))
        let ns = rest as NSString
        guard let m = urlChars.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let token = ns.substring(with: m.range)
        // A list marker or a new URL starts something else.
        if token.hasPrefix("http://") || token.hasPrefix("https://") || ["-", "–", "•", "*"].contains(token) { return nil }
        let filledLine = columns.map { lineLength >= $0 - 1 } ?? false
        let brokenAtSeparator = url.last.map { "-/_?=&#.".contains($0) } ?? false
            && token.contains(where: { "./-_?=&#%".contains($0) })
        guard filledLine || brokenAtSeparator else { return nil }
        return (token, indent..<(indent + token.count))
    }

    /// Strips sentence punctuation that follows a URL, keeping a `)` that closes a `(` inside it.
    static func trimTrailing(_ url: String) -> (String, Int) {
        var s = url
        var dropped = 0
        while let last = s.last {
            if ".,;:!?'\"".contains(last) || (last == ")" && s.filter { $0 == "(" }.count < s.filter { $0 == ")" }.count) {
                s.removeLast()
                dropped += 1
            } else {
                break
            }
        }
        return (s, dropped)
    }

    private static func trimmedLength(_ s: String) -> Int {
        s.count - s.reversed().prefix(while: { $0 == " " }).count
    }

    private static func characterOffset(_ s: String, utf16 offset: Int) -> Int {
        let idx = String.Index(utf16Offset: offset, in: s)
        return s.distance(from: s.startIndex, to: idx)
    }
}
