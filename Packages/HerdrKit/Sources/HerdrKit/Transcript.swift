import Foundation

/// One thing a Claude Code session showed (a prompt, a reply or a tool call),
/// rendered like Claude's screen. `id` is stable, so blocks can be merged;
/// `at` is where its entry starts in the session file (which only grows), the
/// address gaps are filled by.
public struct TranscriptBlock: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var at: Int
    public var lines: [String]

    public init(id: String, at: Int, lines: [String]) {
        self.id = id
        self.at = at
        self.lines = lines
    }
    /// Gateways from before gap filling don't send `at`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        at = try c.decodeIfPresent(Int.self, forKey: .at) ?? 0
        lines = try c.decode([String].self, forKey: .lines)
    }
}

/// What a watch following a Claude pane's session sends: the last blocks
/// (`reset`: replace what you have), or blocks Claude just added.
public struct TranscriptUpdate: Sendable, Codable, Hashable {
    public var reset: Bool?
    /// Which session file (resets only); the same one again means keep what you have.
    public var session: String?
    public var blocks: [TranscriptBlock]
    /// These reach back to the start of the session (nothing older to page in).
    public var start: Bool?
    /// Where the entry just before `blocks` starts, when known: blocks you
    /// already have up to there join on with no gap.
    public var prev: Int?

    public init(reset: Bool? = nil, session: String? = nil, blocks: [TranscriptBlock], start: Bool? = nil, prev: Int? = nil) {
        self.reset = reset
        self.session = session
        self.blocks = blocks
        self.start = start
        self.prev = prev
    }
}

/// Part of a gap in the session: `blocks` from the requested range, and how
/// far the read got. Reading from the end, what's left is `from..<edge`.
public struct TranscriptRange: Sendable, Codable, Hashable {
    public var blocks: [TranscriptBlock]
    public var more: Bool
    public var edge: Int

    public init(blocks: [TranscriptBlock], more: Bool, edge: Int) {
        self.blocks = blocks
        self.more = more
        self.edge = edge
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

/// What the app has of a Claude session: runs of blocks, with gaps where it
/// knows more exists but hasn't fetched it yet. Gaps are byte ranges of the
/// session file (entries starting in `from..<to`), filled by
/// `gw.transcript_range` as you scroll to them. Coming back to the same
/// session keeps what was loaded, with a gap for whatever happened meanwhile
/// beyond the new tail.
public struct TranscriptTimeline: Sendable, Equatable {
    public struct Gap: Sendable, Hashable {
        public var from: Int
        public var to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    public enum Item: Sendable, Hashable {
        case block(TranscriptBlock)
        case gap(Gap)
    }

    public private(set) var items: [Item] = []
    /// The session file these came from.
    public private(set) var session: String?

    public init() {}

    public var blocks: [TranscriptBlock] {
        items.compactMap { if case .block(let b) = $0 { b } else { nil } }
    }

    public var hasBlocks: Bool { items.contains { if case .block = $0 { true } else { false } } }

    public mutating func apply(_ update: TranscriptUpdate) {
        let incoming = update.blocks
        guard update.reset == true else {
            let known = Set(blocks.map(\.id))
            items += incoming.filter { !known.contains($0.id) }.map(Item.block)
            return
        }
        guard let first = incoming.first else {
            // No session (yet), or an empty one.
            items = []
            session = update.session
            return
        }
        var kept: [Item] = []
        if update.session != nil, update.session == session {
            // The same session (a reconnect): keep what's before the new tail.
            for item in items {
                switch item {
                case .block(let b) where b.at < first.at:
                    kept.append(item)
                case .gap(let g) where g.from < first.at:
                    kept.append(.gap(Gap(from: g.from, to: min(g.to, first.at))))
                default:
                    break
                }
            }
            if case .block(let last)? = kept.last, update.prev != last.at {
                // More happened while we were away than the tail covers.
                kept.append(.gap(Gap(from: last.at + 1, to: first.at)))
            }
        }
        session = update.session
        if kept.isEmpty, update.start != true, first.at > 0 {
            kept.append(.gap(Gap(from: 0, to: first.at)))
        }
        items = kept + incoming.map(Item.block)
    }

    /// Puts a range read into its gap: the blocks, after whatever's still
    /// missing. Ignored if the gap is gone (a reset since it was asked for).
    public mutating func fill(_ gap: Gap, with range: TranscriptRange) {
        guard let i = items.firstIndex(where: { if case .gap(let g) = $0 { g.from == gap.from } else { false } }),
              case .gap(let current) = items[i] else { return }
        let known = Set(blocks.map(\.id))
        var replacement: [Item] = []
        if range.more, range.edge > current.from { replacement.append(.gap(Gap(from: current.from, to: min(range.edge, current.to)))) }
        replacement += range.blocks.filter { !known.contains($0.id) && $0.at >= current.from && $0.at < current.to }.map(Item.block)
        items.replaceSubrange(i...i, with: replacement)
    }
}
