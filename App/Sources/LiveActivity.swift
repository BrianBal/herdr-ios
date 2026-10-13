import ActivityKit
import Foundation
import HerdrKit
import Observation

/// The app's half of the summary Live Activity. The gateway does most of the
/// work with pushes (start, update, end); the app
///   * reports tokens: the push-to-start token, and each running activity's
///     update token (iOS wakes the app briefly to deliver it after a push start),
///   * and while it's open, starts one right away when agents are busy and
///     keeps it current from the live snapshot.
@MainActor @Observable
final class LiveActivityManager {
    typealias Attributes = HerdrActivityAttributes

    private static let enabledKey = "liveActivity.enabled"
    /// How long things must stay quiet before the app ends the activity itself
    /// (the gateway uses the same window).
    private static let quietWindow: TimeInterval = 2 * 60

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { Task { await Self.endAll() } }
            onRegistrationChange?()
        }
    }
    private(set) var startToken: String?
    /// A summary activity is on the Lock Screen right now.
    private(set) var isRunning = false
    /// Live Activities are allowed for this app in iOS Settings.
    private(set) var systemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

    /// A running activity's update token arrived (ended false), or the
    /// activity holding that token ended (ended true).
    var onActivityToken: ((_ token: String, _ ended: Bool) -> Void)?
    /// Something the gateway registration carries changed.
    var onRegistrationChange: (() -> Void)?

    private var watched: Set<String> = []
    /// Latest update token per activity id, to say which one ended.
    private var tokens: [String: String] = [:]
    private var quietSince: Date?

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func observe() {
        Task {
            for await data in Activity<Attributes>.pushToStartTokenUpdates {
                startToken = data.hex
                onRegistrationChange?()
            }
        }
        Task {
            // Only one summary at a time: a new one (pushed by a gateway or
            // started here) replaces any left over, including ones whose
            // gateway never got their token and so can't end them.
            for await activity in Activity<Attributes>.activityUpdates {
                watch(activity)
                await Self.endAll(except: activity.id)
                refreshRunning()
            }
        }
        Task {
            for await allowed in ActivityAuthorizationInfo().activityEnablementUpdates { systemEnabled = allowed }
        }
        for activity in Activity<Attributes>.activities { watch(activity) }
        refreshRunning()
    }

    private func refreshRunning() {
        isRunning = Activity<Attributes>.activities.contains { $0.activityState == .active || $0.activityState == .stale }
    }

    /// Settings' "Start now": shows the summary even if nothing is busy.
    func startNow(_ board: AgentBoard) async {
        await Self.apply(Attributes.ContentState(board: board), end: false, force: true)
        refreshRunning()
    }

    /// Settings' "End now". While the switch is on, the gateway starts a new
    /// one the next time agents get busy.
    func endNow() async {
        await Self.endAll()
        refreshRunning()
    }

    private func watch(_ activity: Activity<Attributes>) {
        guard watched.insert(activity.id).inserted else { return }
        refreshRunning()
        Task {
            for await data in activity.pushTokenUpdates {
                tokens[activity.id] = data.hex
                onActivityToken?(data.hex, false)
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                refreshRunning()
                if state == .ended || state == .dismissed, let token = tokens.removeValue(forKey: activity.id) {
                    onActivityToken?(token, true)
                }
            }
        }
    }

    /// Called with every new board while the app is open.
    func sync(_ board: AgentBoard) async {
        let state = Attributes.ContentState(board: board)
        quietSince = state.isBusy ? nil : (quietSince ?? .now)
        guard enabled else { return }
        let quietLongEnough = quietSince.map { Date.now.timeIntervalSince($0) > Self.quietWindow } ?? false
        await Self.apply(state, end: quietLongEnough)
        refreshRunning()
    }

    // ActivityKit's Activity isn't Sendable, so the work happens off the main
    // actor on activities looked up right here.
    private nonisolated static func apply(_ state: Attributes.ContentState, end: Bool, force: Bool = false) async {
        let running = Activity<Attributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        // A push start racing a local start can leave two; keep one.
        for extra in running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(30 * 60))
        if let activity = running.first {
            if end {
                await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(5 * 60)))
            } else {
                await activity.update(content)
            }
        } else if state.isBusy || force, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                _ = try Activity.request(attributes: Attributes(name: "herdr"), content: content, pushType: .token)
            } catch {
                print("Live Activity request failed: \(error)")
            }
        }
    }

    private nonisolated static func endAll(except keep: String? = nil) async {
        for activity in Activity<Attributes>.activities where activity.id != keep {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
