import ActivityKit
import Foundation

struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Run start shifted forward by paused time; the widget counts up from here.
        var timerStart: Date
        /// Frozen elapsed seconds while paused; nil while running.
        var pausedElapsed: TimeInterval?
        var distanceM: Double
        /// Rolling s/km, 0 when unknown.
        var paceSPerKm: Double
        /// 1-based number of the kilometre currently in progress.
        var splitKm: Int
        /// Current or most recent split pace in s/km, 0 when unknown.
        var splitPaceSPerKm: Double
    }

    /// e.g. "Free run", "Race 5K", "Tempo 6 km · 5:30/km".
    var title: String
}

extension RunActivityAttributes.ContentState {
    var distanceText: String {
        String(format: "%.2f", distanceM / 1000)
    }

    var paceText: String {
        Self.formattedPace(paceSPerKm)
    }

    var splitPaceText: String {
        Self.formattedPace(splitPaceSPerKm)
    }

    var pausedText: String {
        let seconds = max(0, Int((pausedElapsed ?? 0).rounded()))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func formattedPace(_ paceSPerKm: Double) -> String {
        guard paceSPerKm.isFinite, paceSPerKm > 0 else { return "–:––" }
        let seconds = Int(paceSPerKm.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
