import Foundation

// Finds agent messages and code blocks in a rendered pane so the app can mark
// them and offer copy buttons. Heuristics, tuned on Claude Code and Codex:
//
//   * An agent message starts at column 0 with a marker (`⏺`/`●` for Claude,
//     `•` for Codex) and continues through indented lines until the next
//     column-0 line or a horizontal rule (Claude's input box is fenced by rules).
//   * Tool calls use the same markers (`⏺ Bash(…)`, `• Ran …`, `• Edited …`); they are kept
//     as plain text without copy buttons.
//   * Neither agent prints ``` fences. Code is rendered fully syntax-colored,
//     while prose is default-colored with short colored spans for inline code,
//     so a run of lines that are almost entirely colored is a code block.

public struct TerminalSegment: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case plain
        case message
        case code
    }

    public var id: Int
    public var kind: Kind
    public var lines: [StyledLine]
    /// What the copy button copies; nil means no button. The last prose segment
    /// of a message carries the whole message (the button sits at its end, where
    /// the reader is); code segments carry just the code.
    public var copyText: String?
}

public enum TerminalSegmenter {
    static let messageMarkers: Set<Character> = ["⏺", "●", "•"]
    /// Continuation lines indented this far are right-aligned status notices, not message text.
    static let maxContinuationIndent = 24

    static let toolCall = try! NSRegularExpression(
        pattern: #"^(?:[A-Z][A-Za-z0-9_]*(?:\(|$)|(?:Ran|Explored|Edited|Searched|Waited|Called)\b)"#)
    static let listItem = try! NSRegularExpression(pattern: #"^(?:\d+[.)]|[-*•+]|[a-z][.)])\s"#)

    /// - Parameters:
    ///   - columns: the pane's width in cells (from herdr's layout), used to tell
    ///     where the agent wrapped prose. Falls back to the longest line.
    ///   - agentPane: the pane runs an agent, so indented text at the very top is
    ///     the tail of a message whose marker scrolled off-screen.
    public static func segment(_ lines: [StyledLine], columns: Int? = nil, agentPane: Bool = false) -> [TerminalSegment] {
        let width = columns ?? (lines.map { $0.plainText.count }.max() ?? 0)
        var segments: [TerminalSegment] = []

        func append(_ kind: TerminalSegment.Kind, _ chunk: ArraySlice<StyledLine>, copy: String? = nil) {
            guard !chunk.isEmpty else { return }
            if kind == .plain, copy == nil, let last = segments.last, last.kind == .plain, last.copyText == nil {
                segments[segments.count - 1].lines += chunk
            } else {
                segments.append(TerminalSegment(id: segments.count, kind: kind, lines: Array(chunk), copyText: copy))
            }
        }

        var i = 0
        var plainStart = 0
        if agentPane, let first = lines.firstIndex(where: { !$0.plainText.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].plainText.first == " ", isContinuation(lines[first])
        {
            // The message's marker scrolled off the top; offer its visible tail.
            let last = messageEnd(lines, from: first, after: first)
            for piece in messagePieces(lines[first..<last], width: width, hasMarker: false) {
                append(piece.kind, piece.lines, copy: piece.copy)
            }
            plainStart = last
            i = last
        }
        while i < lines.count {
            guard isAgentMessageStart(lines[i]) else {
                i += 1
                continue
            }
            append(.plain, lines[plainStart..<i])
            let last = messageEnd(lines, from: i, after: i + 1)
            for piece in messagePieces(lines[i..<last], width: width, hasMarker: true) {
                append(piece.kind, piece.lines, copy: piece.copy)
            }
            plainStart = last
            i = last
        }
        append(.plain, lines[plainStart..<lines.count])
        return segments
    }

    /// End (exclusive) of the message starting at `start`: indented and blank
    /// lines continue it; trailing blank lines are left out.
    private static func messageEnd(_ lines: [StyledLine], from start: Int, after: Int) -> Int {
        var end = after
        while end < lines.count {
            let text = lines[end].plainText
            if text.isEmpty || isContinuation(lines[end]) { end += 1 } else { break }
        }
        while end > start + 1, lines[end - 1].plainText.trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return end
    }

    /// An indented line that still belongs to the message above it. Claude's
    /// input box is fenced by column-0 rules (indented rules are table borders),
    /// deep indents are right-aligned notices, and "Worked for …" is Codex's footer.
    static func isContinuation(_ line: StyledLine) -> Bool {
        let text = line.plainText
        guard text.first == " " else { return false }
        let indent = text.prefix(while: { $0 == " " }).count
        if indent >= maxContinuationIndent { return false }
        return !text.dropFirst(indent).hasPrefix("Worked for ")
    }

    /// Splits one message into prose and code runs. The last prose run carries
    /// the copy text for the whole message; each code run carries its code.
    private static func messagePieces(
        _ message: ArraySlice<StyledLine>, width: Int, hasMarker: Bool
    ) -> [(kind: TerminalSegment.Kind, lines: ArraySlice<StyledLine>, copy: String?)] {
        var isCode = message.map(isCodeLine)
        // A fully colored line can also be a long inline-code span that the
        // agent wrapped from the prose line above; that's prose, not a block.
        let rows = message.map(\.plainText)
        for k in 1..<max(1, rows.count) where isCode[k] && !isCode[k - 1] {
            if wraps(rows[k - 1], into: rows[k], width: width), !rows[k - 1].hasSuffix(":") { isCode[k] = false }
        }
        var runs: [(code: Bool, range: Range<Int>)] = []
        var start = message.startIndex
        while start < message.endIndex {
            let code = isCode[start - message.startIndex]
            var end = start + 1
            while end < message.endIndex, isCode[end - message.startIndex] == code { end += 1 }
            runs.append((code, start..<end))
            start = end
        }
        let lastProse = runs.lastIndex { !$0.code }
        let messageCopy = lastProse == nil ? nil : messageText(message, isCode: isCode, width: width, hasMarker: hasMarker)
        return runs.enumerated().map { n, run in
            let chunk = message[run.range]
            return run.code
                ? (.code, chunk, codeText(chunk))
                : (.message, chunk, n == lastProse ? messageCopy : nil)
        }
    }

    // MARK: Classification

    static func isAgentMessageStart(_ line: StyledLine) -> Bool {
        let text = line.plainText
        guard let first = text.first, messageMarkers.contains(first) else { return false }
        let rest = text.dropFirst().drop(while: { $0 == " " })
        guard text.dropFirst().first == " ", !rest.isEmpty else { return false }
        let body = String(rest)
        let range = NSRange(body.startIndex..., in: body)
        return toolCall.firstMatch(in: body, range: range) == nil
    }

    /// Almost every visible character is explicitly colored (syntax highlighting).
    static func isCodeLine(_ line: StyledLine) -> Bool {
        // Table borders and separators are often fully colored too.
        if line.isHorizontalRule { return false }
        var total = 0
        var colored = 0
        var bold = 0
        for run in line.runs {
            let n = run.text.reduce(0) { $0 + ($1 == " " ? 0 : 1) }
            total += n
            if run.style.fg != .default { colored += n }
            if run.style.bold { bold += n }
        }
        // All-bold colored lines are headings (e.g. table headers), not code.
        guard total >= 2, Double(bold) / Double(total) < 0.85 else { return false }
        if let first = line.plainText.first, messageMarkers.contains(first) { return false }
        return Double(colored) / Double(total) >= 0.85
    }

    // MARK: Copy text

    static func codeText(_ chunk: ArraySlice<StyledLine>) -> String {
        let rows = chunk.map { trimTrailing($0.plainText) }
        let indent = rows.filter { !$0.isEmpty }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return rows.map { String($0.dropFirst(min(indent, $0.count))) }.joined(separator: "\n")
    }

    /// Whole message: marker and hanging indent stripped, prose that the agent
    /// wrapped to the terminal width re-joined into paragraphs, code kept as-is.
    static func messageText(_ message: ArraySlice<StyledLine>, isCode: [Bool], width: Int, hasMarker: Bool = true) -> String {
        var rows = message.map { trimTrailing($0.plainText) }
        guard !rows.isEmpty else { return "" }
        // Drop "⏺ " and the matching hanging indent from continuation lines.
        let markerWidth = hasMarker
            ? rows[0].prefix(while: { !$0.isWhitespace }).count + 1
            : rows.filter { !$0.isEmpty }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        if hasMarker { rows[0] = String(rows[0].dropFirst(markerWidth)) }
        for k in (hasMarker ? 1 : 0)..<rows.count {
            let spaces = rows[k].prefix(while: { $0 == " " }).count
            rows[k] = String(rows[k].dropFirst(min(spaces, markerWidth)))
        }

        var out: [String] = []
        var previousWasWrapped = false
        for (k, row) in rows.enumerated() {
            let code = isCode[k]
            if previousWasWrapped, !code, !row.isEmpty, !isListItem(row), let last = out.last {
                // A URL broken across the lines rejoins without a space.
                let tail = String(last.split(separator: " ").last ?? "")
                let joinsURL = tail.contains("://")
                    && LinkDetector.continuation(of: tail, lineLength: last.count, in: row, columns: nil) != nil
                out[out.count - 1] = last + (joinsURL ? "" : " ") + row.trimmingCharacters(in: .whitespaces)
            } else {
                out.append(row)
            }
            if !code, !row.isEmpty, k + 1 < rows.count, !isCode[k + 1] {
                previousWasWrapped = wraps(message[message.startIndex + k].plainText,
                                           into: message[message.startIndex + k + 1].plainText, width: width)
            } else {
                previousWasWrapped = false
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    // MARK: Display

    /// Prose the agent hard-wrapped at its pane width, rejoined into one line
    /// per paragraph so the phone can wrap it at its own width instead of
    /// wrapping the Mac's lines a second time. Lines that weren't wrapped
    /// (short ones, list items, blank lines) keep their breaks; styling is kept.
    /// Meant for `.message` segments, which hold no code.
    public static func reflowed(_ lines: [StyledLine], columns: Int) -> [StyledLine] {
        var out: [StyledLine] = []
        var joinNext = false
        for (k, line) in lines.enumerated() {
            let text = line.plainText
            if joinNext, var last = out.popLast() {
                last = last.trimmingTrailingSpaces()
                let lastText = last.plainText
                // A URL broken across the lines rejoins without a space.
                let tail = String(lastText.split(separator: " ").last ?? "")
                let joinsURL = tail.contains("://")
                    && LinkDetector.continuation(of: tail, lineLength: lastText.count, in: text, columns: nil) != nil
                if !joinsURL { last.runs.append(StyledRun(text: " ", style: TermStyle())) }
                last.runs += line.droppingLeadingSpaces().runs
                out.append(last)
            } else {
                out.append(line)
            }
            // Decided on the lines as the agent printed them, before joining.
            joinNext = k + 1 < lines.count && wraps(text, into: lines[k + 1].plainText, width: columns)
        }
        return out
    }

    /// Greedy wrapping broke `line` here if the next line's first word wouldn't have fit.
    static func wraps(_ line: String, into next: String, width: Int) -> Bool {
        let nextTrimmed = next.drop(while: { $0 == " " })
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !nextTrimmed.isEmpty,
              !isListItem(String(nextTrimmed)) else { return false }
        let nextWord = nextTrimmed.prefix(while: { $0 != " " }).count
        return line.count + 1 + nextWord > width - 2
    }

    private static func isListItem(_ row: String) -> Bool {
        let t = row.trimmingCharacters(in: .whitespaces)
        return listItem.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    private static func trimTrailing(_ s: String) -> String {
        String(s.reversed().drop(while: { $0 == " " }).reversed())
    }
}

extension StyledLine {
    func droppingLeadingSpaces() -> StyledLine {
        var runs = self.runs
        while let first = runs.first {
            let trimmed = String(first.text.drop(while: { $0 == " " }))
            if trimmed.isEmpty {
                runs.removeFirst()
            } else {
                runs[0].text = trimmed
                break
            }
        }
        return StyledLine(runs: runs)
    }

    func trimmingTrailingSpaces() -> StyledLine {
        var runs = self.runs
        while let last = runs.last {
            let trimmed = String(last.text.reversed().drop(while: { $0 == " " }).reversed())
            if trimmed.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = trimmed
                break
            }
        }
        return StyledLine(runs: runs)
    }
}
