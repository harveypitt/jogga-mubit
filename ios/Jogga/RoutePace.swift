import CoreLocation
import Foundation

/// Splits a route into consecutive ~`chunkM` chunks, each scored 0...1 by
/// speed (1 = fastest), for pace-coloured polylines.
enum RoutePace {
    struct Segment {
        var coordinates: [CLLocationCoordinate2D]
        var score: Double
    }

    static func segments(_ route: [Run.RoutePoint], chunkM: Double = 100) -> [Segment] {
        guard route.count >= 2 else { return [] }

        // Build chunks sharing their boundary point; a >30 s gap breaks the
        // line (no shared endpoint across the pause).
        var chunks: [[CLLocationCoordinate2D]] = []
        var speeds: [Double] = []
        var current: [CLLocationCoordinate2D] = [route[0].coordinate]
        var chunkDistance = 0.0
        var chunkTime = 0.0
        for i in 1..<route.count {
            let prev = route[i - 1]
            let cur = route[i]
            let gap = cur.t - prev.t
            if gap > 30 {
                // Close the chunk at the pre-gap point; start fresh at cur.
                if chunkDistance > 0, chunkTime > 0 {
                    chunks.append(current)
                    speeds.append(chunkDistance / chunkTime)
                }
                current = [cur.coordinate]
                chunkDistance = 0
                chunkTime = 0
                continue
            }
            let leg = RunMath.haversine(prev.coordinate, cur.coordinate)
            chunkDistance += leg
            chunkTime += max(gap, 0)
            current.append(cur.coordinate)
            if chunkDistance >= chunkM {
                chunks.append(current)
                speeds.append(chunkTime > 0 ? chunkDistance / chunkTime : 0)
                // Next chunk starts at the shared boundary point.
                current = [cur.coordinate]
                chunkDistance = 0
                chunkTime = 0
            }
        }
        if chunkDistance > 0, chunkTime > 0 {
            chunks.append(current)
            speeds.append(chunkDistance / chunkTime)
        }
        guard chunks.count == speeds.count else { return [] }

        // Score each chunk: speed normalised between the 10th and 90th
        // percentile speeds, clamped; 0.5 for all if speeds are equal.
        let sorted = speeds.sorted()
        func percentile(_ p: Double) -> Double {
            let index = p * Double(sorted.count - 1)
            let lo = sorted[Int(index)]
            let hi = sorted[min(Int(index) + 1, sorted.count - 1)]
            return lo + (hi - lo) * (index - floor(index))
        }
        let p10 = percentile(0.10)
        let p90 = percentile(0.90)
        return zip(chunks, speeds).map { coords, speed in
            let score: Double
            if p90 - p10 < 1e-9 {
                score = 0.5
            } else {
                score = min(max((speed - p10) / (p90 - p10), 0), 1)
            }
            return Segment(coordinates: coords, score: score)
        }
    }
}
