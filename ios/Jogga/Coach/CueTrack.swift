import CoreLocation
import Foundation

/// Immutable view of the live metrics at a moment — the cue engine's only
/// input, identical for live runs and replay simulation.
struct CueSnapshot: Equatable {
    var clock: TimeInterval
    var distanceM: Double
    var movingS: Double
    var paceSPerKm: Double
    var splitSeconds: [Double]
    var climbLast200M: Double
    var descentLast200M: Double
    var paused: Bool
}

/// Incremental live-metrics accumulator feeding the audio coach — one source
/// for the live recorder and the replay simulator. Mirrors RunRecorder's
/// maths: accepted samples only, pause-clamped leg time, rolling 30 s pace.
final class CueTrack {
    private(set) var distanceM = 0.0
    private(set) var movingS = 0.0
    private(set) var splitSeconds: [Double] = []

    private var previous: RunMath.Sample?
    private var recentWindow: [RunMath.Sample] = []
    private var elevationAcc = RunMath.ElevationAccumulator()
    private var splitAcc = RunMath.SplitAccumulator()
    /// (distance, cumulative gain, cumulative loss) per sample, ~300 m deep.
    private var trail: [(distance: Double, gain: Double, loss: Double)] = []
    private var pace: Double = 0

    /// Feed one already-accepted sample.
    func ingest(_ s: RunMath.Sample) {
        var legDistance = 0.0
        var legTime = 0.0
        if let previous {
            legDistance = RunMath.haversine(previous.coordinate, s.coordinate)
            legTime = max(min(s.t - previous.t, 10), 0) // paused gaps don't count
        }
        distanceM += legDistance
        movingS += legTime
        previous = s
        elevationAcc.ingest(s)
        splitAcc.ingest(s, legDistance: legDistance, legTime: legTime)
        splitSeconds = splitAcc.splits.map(\.movingS)
        recentWindow.append(s)
        recentWindow.removeAll { s.t - $0.t > 30 }
        let d = RunMath.distance(recentWindow)
        let t = RunMath.movingTime(recentWindow)
        pace = d > 5 && t > 2 ? t / (d / 1000) : 0
        trail.append((distanceM, elevationAcc.gain, elevationAcc.loss))
        while trail.count > 1, distanceM - trail[1].distance > 300 {
            trail.removeFirst()
        }
    }

    /// Drop the previous sample so the next leg adds nothing (resume).
    func breakLeg() {
        previous = nil
        recentWindow = []
        pace = 0
    }

    func snapshot(clock: TimeInterval, paused: Bool) -> CueSnapshot {
        let target = distanceM - 200
        var base = trail.first ?? (0, 0, 0)
        for point in trail where point.distance <= target { base = point }
        return CueSnapshot(
            clock: clock,
            distanceM: distanceM,
            movingS: movingS,
            paceSPerKm: pace,
            splitSeconds: splitSeconds,
            climbLast200M: max(elevationAcc.gain - base.gain, 0),
            descentLast200M: max(elevationAcc.loss - base.loss, 0),
            paused: paused
        )
    }
}
