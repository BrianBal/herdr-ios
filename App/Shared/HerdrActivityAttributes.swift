import ActivityKit
import Foundation

/// The summary Live Activity ("2 working · 1 needs you"). The gateway starts,
/// updates and ends it with pushes whose `content-state` is this ContentState,
/// so field names must match `Board` in Gateway/src/push.ts.
struct HerdrActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        struct Agent: Codable, Hashable, Sendable {
            var paneId: String
            /// "claude · html-gen"
            var title: String
            var headline: String
            /// herdr's agent status string.
            var status: String
        }

        var working: Int
        var blocked: Int
        var done: Int
        var agents: [Agent]

        var isBusy: Bool { working + blocked > 0 }

        var summary: String {
            var parts: [String] = []
            if blocked > 0 { parts.append("\(blocked) need\(blocked == 1 ? "s" : "") you") }
            if working > 0 { parts.append("\(working) working") }
            if parts.isEmpty { parts.append(done > 0 ? "\(done) finished" : "All quiet") }
            return parts.joined(separator: " · ")
        }
    }

    var name: String
}
