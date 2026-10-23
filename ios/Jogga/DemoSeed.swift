#if DEBUG
import CoreLocation
import Foundation

/// DEBUG-only `-seedDemo` launch arg: fills plausible runs over ~14 months
/// around San Francisco so every screen is populated in the simulator.
/// `-resetDemo` wipes the local store, the seeded flag and the keychain token.
enum DemoSeed {
    /// SF start points the demo runs begin from. All inland so routes stay
    /// on land; the heading walk is also confined to ~1 km of the start.
    static let starts: [(lat: Double, lon: Double)] = [
        (37.7694, -122.4760), // Golden Gate Park
        (37.7915, -122.4280), // Lafayette Park / Pacific Heights
        (37.7925, -122.4150), // Nob Hill
        (37.7596, -122.4269), // Dolores
        (37.7880, -122.4550), // Presidio Heights
    ]

    /// (weeksAgo, weekday 0=Mon…6=Sun, metres, hillGain). One fully empty week
    /// ~5 weeks ago so the streak visibly restarts; weeks 0-4 all have runs.
    static let plan: [(weeksAgo: Int, day: Int, metres: Double, hillGain: Double)] = [
        (9, 0, 5010, 15),
        (9, 3, 4600, 12),
        (8, 1, 5030, 14),
        (8, 5, 10020, 16),
        (7, 0, 5020, 15),
        (7, 2, 5200, 13),
        (7, 6, 4100, 10),
        (6, 1, 5010, 14),
        (6, 4, 10040, 16),
        // week 5: deliberately empty
        (4, 0, 5020, 15),
        (4, 2, 3800, 9),
        (4, 5, 10010, 16),
        (3, 1, 5040, 14),
        (3, 3, 5200, 12),
        (3, 6, 3500, 8),
        (2, 0, 5030, 15),
        (2, 2, 10020, 16),
        (2, 5, 5010, 13),
        (1, 1, 5020, 14),
        (1, 4, 6200, 12),
        (18, 2, 5020, 16),
        (26, 5, 10030, 22),
        (35, 1, 5010, 15),
        (44, 4, 10010, 18),
        (52, 0, 5030, 14),
        (61, 3, 5010, 19),
    ]

    static func seed(into store: RunStore) {
        let key = "jogga.seeded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let now = Date.now
        var components = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear, .hour], from: now
        )
        components.weekday = 2
        components.hour = 8
        let thisMonday = calendar.date(from: components)!

        var index = 0
        for p in plan {
            let monday = calendar.date(
                byAdding: .weekOfYear, value: -p.weeksAgo, to: thisMonday
            )!
            let started = calendar.date(byAdding: .day, value: p.day, to: monday)!
            if started > now { continue } // never seed a future run
            // Older runs are slower to make long-term progress visible.
            let pace = 350.0 - Double(9 - p.weeksAgo) * 2.2 + Double(index % 3) * 3
            addRun(
                index: index, startedAt: started, metres: p.metres,
                seconds: p.metres / 1000 * pace, hillGain: p.hillGain, into: store
            )
            index += 1
        }

        // One run this morning a few hours before now (never in the future).
        let hour = calendar.component(.hour, from: now)
        let todayStart = hour < 9 ? now - 3600 : now - 3 * 3600
        addRun(
            index: index, startedAt: todayStart, metres: 5030,
            seconds: 1641, hillGain: 14, into: store
        )
    }

    private static func addRun(
        index: Int, startedAt: Date, metres: Double, seconds: Double,
        hillGain: Double, into store: RunStore
    ) {
        let start = starts[index % starts.count]
        var rng = SplitMix64(seed: UInt64(index + 1))
        let outAndBack = rng.next() % 3 == 0 // ~⅓ of runs
        let samples = SyntheticRun.samples(
            distance: metres, seconds: seconds, hillGain: hillGain,
            start: start, rng: &rng, outAndBack: outAndBack
        )
        let splits = RunMath.splits(samples).map {
            Run.Split(distanceM: $0.distanceM, movingS: $0.movingS, gainM: $0.gainM, lossM: $0.lossM)
        }
        let efforts = RunMath.efforts(samples)
        let (gain, loss) = RunMath.elevation(samples)
        let route = samples.map {
            Run.RoutePoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, t: $0.t)
        }
        let run = Run(
            id: UUID(),
            startedAt: startedAt,
            distanceM: RunMath.distance(samples),
            movingS: RunMath.movingTime(samples),
            elapsedS: RunMath.movingTime(samples) + 12,
            gainM: gain,
            lossM: loss,
            splits: splits,
            efforts: efforts,
            route: route
        )
        store.add(run)
        store.queueUpload(run.id)
    }

    /// `-resetDemo`: wipe everything so a relaunch starts clean.
    static func reset(store: RunStore, api: APIClient) {
        store.wipe()
        api.setToken(nil)
        UserDefaults.standard.removeObject(forKey: "jogga.seeded")
    }
}

/// Deterministic per-run randomness (stable route shapes across launches).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// Plausible GPS samples for a run: a heading-walk route, slightly varying
/// pace per km plus one hilly kilometre (~`hillGain` m of gain, ~15% slower).
enum SyntheticRun {
    /// Matches RunMath.haversine's 6371 km Earth radius.
    static let metresPerDegree = 6_371_000.0 * .pi / 180
    static let stepM = 12.0
    /// Soft confinement radius (m) around the start point.
    static let confinementM = 1000.0

    /// Heading walk: `base + A·sin(travelled/λ1) + B·sin(travelled/λ2+φ)`.
    /// Out-and-back runs reverse (heading + π) at half distance with a small
    /// lateral offset; loops steer toward the start over the last ~30%.
    static func samples(
        distance: Double,
        seconds: Double,
        hillGain: Double,
        start: (lat: Double, lon: Double) = (37.78, -122.42),
        rng: inout SplitMix64,
        outAndBack: Bool = false
    ) -> [RunMath.Sample] {
        let base = rng.double() * 2 * .pi
        let a1 = 0.5 + rng.double() * 0.9
        let a2 = 0.3 + rng.double() * 0.5
        let l1 = 300 + rng.double() * 500
        let l2 = 90 + rng.double() * 140
        let phi = rng.double() * 2 * .pi

        let pace = seconds / (distance / 1000) // s/km
        let hillyKm = min(2, max(0, Int(distance / 1000) - 2)) // third km from last

        var out: [RunMath.Sample] = []
        var t = 0.0
        var travelled = 0.0
        var altitude = 20.0
        var lat = start.lat
        var lon = start.lon
        var reversed = false
        var turnOffset = 0.0
        var steer = 0.0
        var i = 0
        while travelled < distance {
            let kmIndex = Int(travelled / 1000)
            let hilly = kmIndex == hillyKm
            // Alternate kms a touch slower/faster; the hilly km is slower still.
            let paceFactor = hilly ? 1.15 : (kmIndex % 2 == 0 ? 1.01 : 0.99)
            t += pace * paceFactor * (stepM / 1000)
            travelled += stepM
            altitude += hilly ? hillGain * stepM / 1000 : 0.4 * sin(Double(i) / 3)
            i += 1

            var heading = base + a1 * sin(travelled / l1) + a2 * sin(travelled / l2 + phi)
            if outAndBack {
                if !reversed, travelled >= distance / 2 {
                    reversed = true
                    // Small lateral offset so the return leg doesn't overlap.
                    let perp = heading + .pi / 2
                    lat += 18 * cos(perp) / metresPerDegree
                    lon += 18 * sin(perp) / (metresPerDegree * cos(lat * .pi / 180))
                    turnOffset = .pi
                }
                heading += turnOffset
            }
            // Accumulated steering toward the start bearing: active when the
            // point is beyond 0.6R or (for loops) in the last 30%, changing by
            // at most 4° per step; decays toward 0 by 1.5° per step otherwise.
            let fromStart = hypot(
                (lat - start.lat) * metresPerDegree,
                (lon - start.lon) * metresPerDegree * cos(lat * .pi / 180)
            )
            let wantHome = fromStart > confinementM * 0.6
                || (!outAndBack && travelled > distance * 0.7)
            if wantHome {
                let error = angleDelta(
                    from: heading + steer, to: bearingToStart(lat, lon, start)
                )
                let maxTurn = 4.0 * .pi / 180
                steer += min(max(error, -maxTurn), maxTurn)
            } else {
                let maxDecay = 1.5 * .pi / 180
                steer += min(max(-steer, -maxDecay), maxDecay)
            }
            heading += steer
            lat += stepM * cos(heading) / metresPerDegree
            lon += stepM * sin(heading) / (metresPerDegree * cos(lat * .pi / 180))
            out.append(RunMath.Sample(
                t: t,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                horizontalAccuracy: 5,
                altitude: altitude,
                verticalAccuracy: 4
            ))
        }
        return out
    }

    /// Signed shortest rotation from `a` to `b` (radians).
    private static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    private static func bearingToStart(
        _ lat: Double, _ lon: Double, _ start: (lat: Double, lon: Double)
    ) -> Double {
        let dx = (start.lon - lon) * metresPerDegree * cos(lat * .pi / 180)
        let dy = (start.lat - lat) * metresPerDegree
        return atan2(dx, dy)
    }
}
#endif
