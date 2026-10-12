import Foundation

/// Joins a pane's history (`pane.read`/`agent.read` with `source: recent`)
/// to the live screen the app is already showing.
public enum Scrollback {
    /// The lines of `recent` that come before the screen `visible`. `recent`
    /// ends with that same screen, so this finds where the screen's first
    /// lines appear in it (comparing text, since agent history has no colors)
    /// and keeps what's above.
    ///
    /// Agents' history comes from their own transcript, which breaks lines
    /// differently from the screen, so when the exact match fails it looks for
    /// the screen's first substantial line by its start. Failing both, it drops
    /// a screen's worth of lines.
    public static func earlier(_ recent: [StyledLine], visible: [StyledLine]) -> [StyledLine] {
        let key = { (line: StyledLine) in line.plainText.trimmingCharacters(in: .whitespaces) }
        let recentKeys = recent.map(key)
        // Anchor on the first few non-blank lines of the screen, with their offsets.
        let anchors = visible.enumerated().map { ($0.offset, key($0.element)) }.filter { !$0.1.isEmpty }.prefix(3)
        var cut: Int?
        if let first = anchors.first {
            // The latest match: the screen sits at the end of the history.
            for i in stride(from: recentKeys.count - 1, through: 0, by: -1) where recentKeys[i] == first.1 {
                let start = i - first.0
                let fits = anchors.allSatisfy { offset, text in
                    let j = start + offset
                    return j >= 0 && j < recentKeys.count && recentKeys[j] == text
                }
                if fits, start >= 0 {
                    cut = start
                    break
                }
            }
        }
        if cut == nil { cut = looseCut(recentKeys, visible: visible.map(key)) }
        var lines = Array(recent.prefix(cut ?? max(0, recent.count - visible.count)))
        while let last = lines.last, key(last).isEmpty { lines.removeLast() }
        return lines
    }

    private static let looseKeyLength = 40

    private static func looseKey(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(looseKeyLength))
    }

    /// Where the screen starts in a transcript that wraps differently: the
    /// latest history line containing one of the screen's first substantial
    /// lines (trying a few, since some screen lines, like tool output, may not
    /// be in the transcript at all). A screen line that starts mid-paragraph
    /// keeps that paragraph in the history, so its beginning isn't lost.
    private static func looseCut(_ recentKeys: [String], visible: [String]) -> Int? {
        let normalized = recentKeys.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        for line in visible.filter({ $0.count >= 12 }).prefix(12) {
            let anchor = looseKey(line)
            guard let i = normalized.lastIndex(where: { $0.contains(anchor) }) else { continue }
            return normalized[i].hasPrefix(anchor) ? i : i + 1
        }
        return nil
    }
}
