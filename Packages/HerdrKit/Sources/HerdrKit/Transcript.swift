import Foundation

/// One thing a Claude Code session showed (a prompt, a reply or a tool call),
/// rendered like Claude's screen. `id` is stable, so blocks can be merged.
public struct TranscriptBlock: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var lines: [String]

    public init(id: String, lines: [String]) {
        self.id = id
        self.lines = lines
    }
}

/// What a watch following a Claude pane's session sends: the last blocks
/// (`reset`: replace what you have), or blocks Claude just added.
public struct TranscriptUpdate: Sendable, Codable, Hashable {
    public var reset: Bool?
    public var blocks: [TranscriptBlock]
    /// These reach back to the start of the session (nothing older to page in).
    public var start: Bool?

    public init(reset: Bool? = nil, blocks: [TranscriptBlock], start: Bool? = nil) {
        self.reset = reset
        self.blocks = blocks
        self.start = start
    }
}

/// Joins a Claude session's transcript to its live screen by message rather
/// than by line: Claude's screen ends with the latest messages, each starting
/// at column 0 with ⏺/● (replies, tool calls) or ❯ (your prompts). The
/// earliest one on screen that's also in the transcript is where the screen
/// takes over. Everything above it comes from the transcript, so nothing is
/// shown twice and nothing that scrolled off the screen goes missing.
public enum TranscriptJoin {
    public struct Cut: Equatable, Sendable {
        /// Transcript blocks before this index are history.
        public var block: Int
        /// The screen is shown from this line on.
        public var line: Int
    }

    /// `firstLines` is each block's first line. Nil when no message on screen
    /// can be found in the transcript (a screen full of one tool's output, or a
    /// transcript from another session).
    public static func cut(firstLines: [String], screen: [StyledLine]) -> Cut? {
        let blockKeys = firstLines.map(key)
        var starts: [(line: Int, key: Key)] = []
        var previous = ""
        for (i, line) in screen.enumerated() {
            let text = line.plainText
            // ❯ between two rules is the input box, not a message.
            if let k = key(text), !(k.prompt && isRule(previous)) { starts.append((i, k)) }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { previous = text }
        }
        // From the bottom: each message on screen matches a block no later than
        // the one below it. Messages not in the transcript yet (Claude still
        // writing) or drawn differently (some tool calls) just don't match.
        var next = blockKeys.count - 1
        var found: Cut?
        for start in starts.reversed() where next >= 0 {
            for b in stride(from: next, through: max(0, next - searchWindow), by: -1) {
                if let k = blockKeys[b], matches(screen: start.key, block: k) {
                    found = Cut(block: b, line: start.line)
                    next = b - 1
                    break
                }
            }
        }
        return found
    }

    /// How far back from the last match to look for the next one.
    static let searchWindow = 60

    struct Key: Equatable {
        var prompt: Bool
        var text: String
        var tool: Bool
    }

    static func key(_ line: String) -> Key? {
        guard let first = line.unicodeScalars.first else { return nil }
        let prompt: Bool
        switch first {
        case "❯", ">": prompt = true
        case "⏺", "●": prompt = false
        default: return nil
        }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        var text = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.hasSuffix("…") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // "Bash(git status)": the same call shows up again and again.
        let tool = !prompt && text.range(of: #"^[A-Za-z_]+\("#, options: .regularExpression) != nil
        return Key(prompt: prompt, text: text, tool: tool)
    }

    /// The screen wraps the first line at the phone's width, so it's a prefix
    /// of the block's. Tool calls only count when identical and specific:
    /// they repeat, and Claude shows paths and names differently on screen.
    static func matches(screen: Key, block: Key) -> Bool {
        guard screen.prompt == block.prompt else { return false }
        if screen.tool || block.tool { return screen.text == block.text && screen.text.count >= 16 }
        return screen.text == block.text || (screen.text.count >= 8 && block.text.hasPrefix(screen.text))
    }

    private static func isRule(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 && t.allSatisfy { $0 == "─" || $0 == "━" }
    }
}
