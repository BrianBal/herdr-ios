import Foundation

/// Completions for the word at the end of a shell command line (gw.complete).
public struct ShellCompletions: Decodable, Sendable, Equatable {
    /// The word being completed, as typed.
    public let word: String
    /// Ready to insert; folders end in "/".
    public let candidates: [String]

    public init(word: String, candidates: [String]) {
        self.word = word
        self.candidates = candidates
    }

    /// The line with its last word replaced by `candidate`, plus a space
    /// unless it's a folder (there's more to type after a "/").
    public static func apply(_ candidate: String, to line: String, replacing word: String) -> String {
        let head = line.hasSuffix(word) ? String(line.dropLast(word.count)) : line
        return head + candidate + (candidate.hasSuffix("/") ? "" : " ")
    }
}

public enum ShellInput {
    /// Undoes the keyboard's smart punctuation, which turns "--" into "—" and
    /// quotes into curly ones: neither means anything to a shell.
    public static func plain(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "—": out += "--"
            case "–": out += "-"
            case "‘", "’": out += "'"
            case "“", "”": out += "\""
            default: out.append(c)
            }
        }
        return out
    }
}
