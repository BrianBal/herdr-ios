import Foundation

/// Display names for herdr's agent kinds.
enum AgentKind {
    static func displayName(_ kind: String) -> String {
        switch kind {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "gemini": "Gemini"
        case "opencode": "OpenCode"
        case "cursor": "Cursor"
        case "copilot": "Copilot"
        case "amp": "Amp"
        case "droid": "Droid"
        case "qwen": "Qwen Code"
        case "kimi": "Kimi"
        case "kiro": "Kiro"
        case "cline": "Cline"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}
