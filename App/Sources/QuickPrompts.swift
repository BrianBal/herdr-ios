import Foundation
import Observation
import SwiftUI

/// One-tap prompts shown as chips above the composer: one list for agent
/// panes, one for shells. Kept in UserDefaults; edited from the chips
/// themselves or in Settings.
@MainActor @Observable
final class QuickPrompts {
    enum Kind: String, CaseIterable, Identifiable {
        case agent, shell
        var id: String { rawValue }
        var title: String { self == .agent ? "Agent prompts" : "Shell commands" }
    }

    static let defaults: [Kind: [String]] = [
        // No /clear: it throws away the conversation, too costly for a mis-tap.
        .agent: ["continue", "yes", "run the tests", "/compact", "commit this"],
        .shell: ["git status", "ls -la", "git pull"],
    ]

    private(set) var agent: [String]
    private(set) var shell: [String]

    init() {
        agent = Self.load(.agent)
        shell = Self.load(.shell)
    }

    func list(_ kind: Kind) -> [String] { kind == .agent ? agent : shell }

    func add(_ text: String, to kind: Kind) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !list(kind).contains(t) else { return }
        set(list(kind) + [t], kind)
    }

    func remove(_ text: String, from kind: Kind) {
        set(list(kind).filter { $0 != text }, kind)
    }

    func remove(atOffsets offsets: IndexSet, from kind: Kind) {
        var l = list(kind)
        l.remove(atOffsets: offsets)
        set(l, kind)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int, in kind: Kind) {
        var l = list(kind)
        l.move(fromOffsets: source, toOffset: destination)
        set(l, kind)
    }

    func replace(_ old: String, with new: String, in kind: Kind) {
        let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return remove(old, from: kind) }
        set(list(kind).map { $0 == old ? t : $0 }, kind)
    }

    func resetToDefaults(_ kind: Kind) {
        set(Self.defaults[kind] ?? [], kind)
    }

    private func set(_ l: [String], _ kind: Kind) {
        if kind == .agent { agent = l } else { shell = l }
        UserDefaults.standard.set(l, forKey: Self.key(kind))
    }

    private static func key(_ kind: Kind) -> String { "quickPrompts.\(kind.rawValue)" }

    private static func load(_ kind: Kind) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(kind)) ?? defaults[kind] ?? []
    }
}
