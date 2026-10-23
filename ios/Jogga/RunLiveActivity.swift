import ActivityKit
import Foundation

final class RunLiveActivity {
    private var lastSent: Date?

    func start(title: String, state: RunActivityAttributes.ContentState) {
        Task {
            await Self.endExistingActivities()
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            do {
                _ = try ActivityKit.Activity<RunActivityAttributes>.request(
                    attributes: RunActivityAttributes(title: title),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                lastSent = .now
            } catch {
                NSLog("Jogga Live Activity start failed: %@", String(describing: error))
            }
        }
    }

    func update(_ state: RunActivityAttributes.ContentState, force: Bool = false) {
        let now = Date.now
        guard Self.shouldUpdate(lastSent: lastSent, now: now, force: force) else { return }
        lastSent = now
        Task {
            for activity in ActivityKit.Activity<RunActivityAttributes>.activities {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    func end() {
        lastSent = nil
        Task {
            await Self.endExistingActivities()
        }
    }

    static func endAll() {
        Task {
            await endExistingActivities()
        }
    }

    static func shouldUpdate(lastSent: Date?, now: Date, force: Bool) -> Bool {
        force || (lastSent.map { now.timeIntervalSince($0) >= 5 } ?? true)
    }

    static func splitPace(
        currentDistance: Double,
        currentTime: Double,
        lastSplit: Run.Split?
    ) -> Double {
        if currentDistance >= 50 {
            return currentTime / currentDistance * 1000
        }
        guard let lastSplit, lastSplit.distanceM > 0 else { return 0 }
        return lastSplit.movingS / lastSplit.distanceM * 1000
    }

    private static func endExistingActivities() async {
        for activity in ActivityKit.Activity<RunActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
