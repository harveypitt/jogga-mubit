import CoreLocation
import Foundation

/// Pure run maths: GPS filtering, distance, splits, elevation, efforts,
/// Riegel prediction and formatters. Everything here is unit-testable.
enum RunMath {
    static let standardDistances: [(key: String, metres: Double)] = [
        ("5k", 5_000),
        ("10k", 10_000),
        ("half", 21_097.5),
        ("marathon", 42_195),
    ]

    /// A filtered-location input independent of CLLocation for testing.
    struct Sample {
        var t: TimeInterval // seconds since run start
        var coordinate: CLLocationCoordinate2D
        var horizontalAccuracy: Double
        var altitude: Double
        var verticalAccuracy: Double
    }

    struct Split {
        var distanceM: Double
        var movingS: Double
        var gainM: Double
        var lossM: Double
    }

    // MARK: Filtering

    /// Incremental acceptance: accuracy, staleness at receipt and implied
    /// speed vs the previous *raw* sample (so one teleport doesn't poison
    /// everything after it).
    static func accept(
        _ sample: Sample, previousRaw: Sample?, receivedAt: TimeInterval
    ) -> Bool {
        guard sample.horizontalAccuracy >= 0, sample.horizontalAccuracy <= 25 else { return false }
        guard receivedAt - sample.t <= 10 else { return false }
        if let previous = previousRaw {
            let gap = sample.t - previous.t
            if gap > 0, gap <= 10,
               haversine(previous.coordinate, sample.coordinate) / gap > 12 {
                return false
            }
        }
        return true
    }

    /// Batch acceptance built on `accept` — mainly for tests.
    static func filter(_ samples: [Sample], now: TimeInterval) -> [Sample] {
        var accepted: [Sample] = []
        var previous: Sample?
        for s in samples {
            if accept(s, previousRaw: previous, receivedAt: now) {
                accepted.append(s)
            }
            previous = s
        }
        return accepted
    }

    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(sqrt(h))
    }

    // MARK: Distance and moving time

    static func distance(_ samples: [Sample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) {
            $0 + haversine($1.0.coordinate, $1.1.coordinate)
        }
    }

    /// Moving time excludes gaps > 10 s between accepted samples (pauses).
    static func movingTime(_ samples: [Sample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.t - pair.0.t
            return total + (gap <= 10 ? gap : 0)
        }
    }

    // MARK: Elevation (3 m hysteresis)

    /// Altitudes are only trusted when verticalAccuracy is in (0, 10].
    /// Gain/loss counts a climb/descent once altitude moves >= 3 m from the anchor.
    static func elevation(_ samples: [Sample]) -> (gain: Double, loss: Double) {
        let acc = ElevationAccumulator()
        for s in samples { acc.ingest(s) }
        return (acc.gain, acc.loss)
    }

    /// Incremental elevation hysteresis — same rules as `elevation` but O(1)
    /// per sample for the live recorder.
    final class ElevationAccumulator {
        private(set) var gain = 0.0
        private(set) var loss = 0.0
        private var anchor: Double?

        func ingest(_ s: Sample) {
            guard s.verticalAccuracy > 0, s.verticalAccuracy <= 10 else { return }
            guard let a = anchor else {
                anchor = s.altitude
                return
            }
            let delta = s.altitude - a
            if delta >= 3 {
                gain += delta
                anchor = s.altitude
            } else if delta <= -3 {
                loss -= delta
                anchor = s.altitude
            }
        }

        func seed(altitude: Double, verticalAccuracy: Double) {
            guard verticalAccuracy > 0, verticalAccuracy <= 10 else { return }
            anchor = altitude
        }
    }

    /// Incremental splits — same output as `splits` but O(1) per sample.
    /// Matches the batch semantics: the boundary sample's altitude feeds both
    /// the closing split and seeds the next one.
    final class SplitAccumulator {
        private(set) var splits: [Split] = []
        private var distance = 0.0
        private var time = 0.0
        private var elevationAcc = ElevationAccumulator()

        var currentDistance: Double { distance }
        var currentTime: Double { time }

        /// Feed one accepted sample after another. `legTime` is the moving
        /// time attributable to the leg from `previous` (already pause-clamped).
        func ingest(_ s: Sample, legDistance: Double, legTime: Double) {
            elevationAcc.ingest(s)
            var remaining = legDistance
            while remaining > 0 {
                let take = min(remaining, 1000 - distance)
                distance += take
                time += legTime * (legDistance > 0 ? take / legDistance : 0)
                remaining -= take
                if distance >= 1000 - 1e-9 {
                    splits.append(Split(
                        distanceM: 1000, movingS: time,
                        gainM: elevationAcc.gain, lossM: elevationAcc.loss
                    ))
                    distance = 0
                    time = 0
                    elevationAcc = ElevationAccumulator()
                    elevationAcc.seed(
                        altitude: s.altitude,
                        verticalAccuracy: s.verticalAccuracy
                    )
                }
            }
        }

        /// Call at finish: emits the trailing partial split when >= 50 m.
        func finalize() -> [Split] {
            if distance >= 50 {
                splits.append(Split(
                    distanceM: distance, movingS: time,
                    gainM: elevationAcc.gain, lossM: elevationAcc.loss
                ))
            }
            return splits
        }
    }

    // MARK: Splits

    /// Per full km plus a final partial split when >= 50 m.
    static func splits(_ samples: [Sample]) -> [Split] {
        guard samples.count > 1 else { return [] }
        var result: [Split] = []
        var splitDistance = 0.0
        var splitTime = 0.0
        var splitSamples: [Sample] = [samples[0]]

        func closeSplit(distance: Double, moving: Double, elevationSource: [Sample]) {
            guard distance >= 0.5 else { return }
            let (g, l) = elevation(elevationSource)
            result.append(Split(distanceM: distance, movingS: moving, gainM: g, lossM: l))
        }

        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            let leg = haversine(prev.coordinate, cur.coordinate)
            let legTime = max(min(cur.t - prev.t, 10), 0) // paused gaps don't count
            splitSamples.append(cur)
            // Distribute the leg across splits, closing each at 1000 m.
            var remaining = leg
            while remaining > 0 {
                let take = min(remaining, 1000 - splitDistance)
                splitDistance += take
                splitTime += legTime * (leg > 0 ? take / leg : 0)
                remaining -= take
                if splitDistance >= 1000 - 1e-9 {
                    closeSplit(distance: 1000, moving: splitTime, elevationSource: splitSamples)
                    splitSamples = [cur]
                    splitDistance = 0
                    splitTime = 0
                }
            }
        }
        if splitDistance >= 50 {
            closeSplit(distance: splitDistance, moving: splitTime, elevationSource: splitSamples)
        }
        return result
    }

    // MARK: Efforts

    /// For each standard distance the run reaches, the moving time elapsed when
    /// cumulative distance first crossed it (linear interpolation).
    static func efforts(_ samples: [Sample]) -> [String: Double] {
        var out: [String: Double] = [:]
        var cumulative = 0.0
        var pending = standardDistances.map { $0 }
        guard samples.count > 1 else { return out }
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            let leg = haversine(prev.coordinate, cur.coordinate)
            let legTime = min(cur.t - prev.t, 10)
            while let next = pending.first, cumulative + leg >= next.metres {
                let frac = leg > 0 ? (next.metres - cumulative) / leg : 0
                out[next.key] = movingTime(Array(samples[0...i - 1])) + frac * legTime
                pending.removeFirst()
            }
            cumulative += leg
        }
        return out
    }

    /// Largest standard distance reached, else nil (free run).
    static func primaryDistance(_ distanceM: Double) -> String? {
        standardDistances.last(where: { distanceM >= $0.metres })?.key
    }

    // MARK: Prediction

    /// Riegel: T2 = T1 * (D2/D1)^1.06 from the best effort at the nearest other distance.
    static func riegel(
        target targetKey: String, efforts: [String: Double]
    ) -> (from: String, seconds: Double)? {
        guard let target = standardDistances.first(where: { $0.key == targetKey }),
              let targetIndex = standardDistances.firstIndex(where: { $0.key == targetKey })
        else { return nil }
        for offset in 1...standardDistances.count {
            for index in [targetIndex - offset, targetIndex + offset]
            where standardDistances.indices.contains(index) {
                if let t1 = efforts[standardDistances[index].key] {
                    let d1 = standardDistances[index].metres
                    let t2 = t1 * pow(target.metres / d1, 1.06)
                    return (standardDistances[index].key, t2)
                }
            }
        }
        return nil
    }

    /// Required pace in s/km for a target time.
    static func requiredPace(distanceKey: String, targetS: Double) -> Double {
        guard let d = standardDistances.first(where: { $0.key == distanceKey }) else { return 0 }
        return targetS / (d.metres / 1000)
    }

    // MARK: Formatters

    /// `26:40`, `1:52:07`
    static func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `5:19 /km`
    static func formatPace(_ sPerKm: Double) -> String {
        guard sPerKm.isFinite, sPerKm > 0 else { return "–:–– /km" }
        let s = Int(sPerKm.rounded())
        return String(format: "%d:%02d /km", s / 60, s % 60)
    }

    /// `5.02 km`
    static func formatDistance(_ metres: Double) -> String {
        String(format: "%.2f km", metres / 1000)
    }

    /// `12.4 km`
    static func formatKm(_ km: Double) -> String {
        String(format: "%.1f km", km)
    }
}
