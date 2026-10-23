import Foundation

/// Run-intent kinds mapped onto coaching pace styles.
enum PaceStyle: String, Codable {
    case easy, tempo, race, none

    init(kind: String) {
        switch kind.lowercased() {
        case "easy", "steady", "long": self = .easy
        case "tempo": self = .tempo
        case "race": self = .race
        default: self = .none
        }
    }
}

/// What this run is: a planned session, a target-distance race, or free.
enum CoachMode: Hashable, Codable {
    case plan(kind: String, km: Double, paceSPerKm: Double)
    case race(distanceKey: String)
    case free

    var isUnprescribed: Bool {
        switch self {
        case .race, .free: true
        case .plan: false
        }
    }
}

/// A PB or target profile to measure the live run against.
struct PBReference: Codable, Equatable {
    /// True when the reference is the target time rather than a PB.
    var isTarget: Bool
    var totalS: Double
    var metres: Double
    /// Moving seconds at each full km (already scaled); empty = even profile.
    var cumulative: [Double]

    /// Expected moving seconds at `distanceM`, linearly interpolated and
    /// clamped to [0, metres].
    func secondsAt(_ distanceM: Double) -> Double {
        let d = min(max(distanceM, 0), metres)
        return interpolated(at: d)
    }

    /// `secondsAt` inside the distance; beyond it, extrapolates at the
    /// reference's average pace.
    func projectedSecondsAt(_ distanceM: Double) -> Double {
        let d = max(distanceM, 0)
        if d <= metres { return interpolated(at: d) }
        return totalS * d / metres
    }

    private func interpolated(at d: Double) -> Double {
        guard !cumulative.isEmpty else { return totalS * d / metres }
        var points: [(Double, Double)] = [(0, 0)]
        for (i, s) in cumulative.enumerated() {
            points.append((Double(i + 1) * 1000, s))
        }
        if (points.last?.0 ?? 0) < metres - 0.5 {
            points.append((metres, totalS))
        }
        for i in 1..<points.count where d <= points[i].0 {
            let (d1, t1) = points[i - 1]
            let (d2, t2) = points[i]
            let f = d2 > d1 ? (d - d1) / (d2 - d1) : 0
            return t1 + f * (t2 - t1)
        }
        return totalS
    }
}

/// The most similar recent run, for "quicker than last time" split calls.
struct ComparableRun: Codable, Equatable {
    var startedAt: Date
    var splitSeconds: [Double] // moving s per full km
}

/// Everything the cue engine needs to know before the run starts.
struct RunContext: Codable, Equatable {
    var mode: CoachMode
    var style: PaceStyle
    var targetPace: Double? = nil // s/km
    var plannedM: Double? = nil
    var reference: PBReference? = nil
    /// Yardsticks for split progress sentences — PB and target kept
    /// separately so the engine can compare against both.
    var progressPB: PBReference? = nil
    var progressTarget: PBReference? = nil
    var comparable: ComparableRun? = nil
    /// "fm" | "default" — which coach lines the phrase book used.
    var linesSource: String? = nil

    /// `history` must contain only runs strictly before the run being coached.
    static func make(
        mode: CoachMode, history: [Run], targets: [String: Int],
        serverBest: [String: Double], now: Date, calendar: Calendar = .current
    ) -> RunContext {
        var context = RunContext(mode: mode, style: .none)
        switch mode {
        case let .plan(kind, km, pace):
            context.style = PaceStyle(kind: kind)
            context.targetPace = pace
            context.plannedM = km * 1000
        case let .race(distanceKey):
            context.style = .race
            guard let metres = RunMath.standardDistances
                .first(where: { $0.key == distanceKey })?.metres else { break }
            context.plannedM = metres
            // One yardstick: the more ambitious of PB and target.
            let candidates = [
                makePBReference(
                    distanceKey: distanceKey, history: history,
                    serverBest: serverBest, metres: metres
                ),
                targets[distanceKey].map {
                    PBReference(isTarget: true, totalS: Double($0),
                                metres: metres, cumulative: [])
                },
            ].compactMap { $0 }
            context.reference = candidates.min { $0.totalS < $1.totalS }
            if let ref = context.reference {
                context.targetPace = ref.totalS / ref.metres * 1000
            }
        case .free:
            break
        }
        // Progress yardsticks: race uses its own distance; other modes use
        // the nearest standard distance that has a PB or a target.
        let progressKey: String? = switch mode {
        case let .race(key): key
        default: RunMath.standardDistances
            .filter { dist in
                targets[dist.key] != nil || serverBest[dist.key] != nil
                    || history.contains { $0.efforts[dist.key] != nil }
            }
            .min {
                abs($0.metres - (context.plannedM ?? 5000))
                    < abs($1.metres - (context.plannedM ?? 5000))
            }?.key
        }
        if let progressKey, let metres = RunMath.standardDistances
            .first(where: { $0.key == progressKey })?.metres {
            context.progressPB = makePBReference(
                distanceKey: progressKey, history: history,
                serverBest: serverBest, metres: metres
            )
            context.progressTarget = targets[progressKey].map {
                PBReference(isTarget: true, totalS: Double($0),
                            metres: metres, cumulative: [])
            }
        }
        context.comparable = makeComparable(
            history: history, plannedM: context.plannedM,
            now: now, calendar: calendar
        )
        return context
    }

    /// PB reference for race mode: best known total (server best vs local
    /// efforts), shaped like the local PB run's splits when available, else
    /// even.
    private static func makePBReference(
        distanceKey: String, history: [Run],
        serverBest: [String: Double], metres: Double
    ) -> PBReference? {
        let pbRun = history
            .filter { $0.efforts[distanceKey] != nil }
            .min {
                ($0.efforts[distanceKey] ?? .infinity)
                    < ($1.efforts[distanceKey] ?? .infinity)
            }
        let pbTotal = [serverBest[distanceKey], pbRun?.efforts[distanceKey]]
            .compactMap { $0 }.min()
        if let pbTotal {
            var cumulative: [Double] = []
            // Shape from the PB run's own full-km splits when that run is the
            // source of the best total.
            if let pbRun, abs((pbRun.efforts[distanceKey] ?? .infinity) - pbTotal) < 0.5 {
                var sum = 0.0
                for split in pbRun.splits where split.distanceM >= 999 {
                    sum += split.movingS
                    if Double(cumulative.count + 1) * 1000 <= metres + 0.5 {
                        cumulative.append(sum)
                    } else { break }
                }
                if !cumulative.isEmpty {
                    // Scale so the profile reaches metres at the PB total.
                    var ref = PBReference(
                        isTarget: false, totalS: pbTotal,
                        metres: metres, cumulative: cumulative
                    )
                    let raw = ref.secondsAt(metres)
                    if raw > 0 {
                        ref.cumulative = cumulative.map { $0 * pbTotal / raw }
                    }
                    cumulative = ref.cumulative
                }
            }
            return PBReference(
                isTarget: false, totalS: pbTotal, metres: metres,
                cumulative: cumulative
            )
        }
        return nil
    }

    /// Most recent run within 30 days and ±20 % of the planned distance
    /// (or ≥ 2 km for free runs).
    private static func makeComparable(
        history: [Run], plannedM: Double?, now: Date, calendar: Calendar
    ) -> ComparableRun? {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let best = history
            .filter { run in
                guard run.startedAt >= cutoff, run.startedAt <= now else { return false }
                if let plannedM {
                    return abs(run.distanceM - plannedM) <= 0.2 * plannedM
                }
                return run.distanceM >= 2000
            }
            .max { $0.startedAt < $1.startedAt }
        guard let best else { return nil }
        return ComparableRun(
            startedAt: best.startedAt,
            splitSeconds: best.splits
                .filter { $0.distanceM >= 999 }
                .map(\.movingS)
        )
    }
}
