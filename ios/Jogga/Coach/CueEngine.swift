import Foundation

/// What the coach wants to say. `priority` orders the queue.
enum CueEvent: Equatable, Codable {
    case start
    case tooFast, fastStart, onTarget
    case tooSlow(deltaS: Int)
    case split(km: Int, seconds: Double, totalS: Double, comment: Bool, progress: SplitProgress?)
    case pbOn(aheadS: Int, isTarget: Bool)
    case pbSlipping(behindS: Int?, isTarget: Bool) // nil = still marginally ahead
    case pbHold(remainingM: Int, isTarget: Bool)
    case halfway
    case lastKm(hard: Bool)
    case kmCheck(projectedDeltaS: Int)
    case toGo500(label: String?)

    var isPacing: Bool {
        switch self {
        case .tooFast, .fastStart, .onTarget, .tooSlow, .kmCheck: return true
        default: return false
        }
    }

    var priority: Int {
        switch self {
        case .pbOn, .pbSlipping, .pbHold: return 40
        case .tooFast, .fastStart, .onTarget, .tooSlow: return 30
        case .kmCheck: return 30
        case .split, .toGo500: return 20
        case .start, .halfway, .lastKm: return 10
        }
    }

    /// Log kind identifier.
    var name: String {
        switch self {
        case .start: return "start"
        case .tooFast: return "tooFast"
        case .fastStart: return "fastStart"
        case .onTarget: return "onTarget"
        case .tooSlow: return "tooSlow"
        case .split: return "split"
        case .pbOn: return "pbOn"
        case .pbSlipping: return "pbSlipping"
        case .pbHold: return "pbHold"
        case .halfway: return "halfway"
        case .lastKm: return "lastKm"
        case .kmCheck: return "kmCheck"
        case .toGo500: return "toGo500"
        }
    }
}

/// How this km's cumulative moving time compares to the relevant yardstick.
enum SplitProgress: Equatable, Codable {
    case aheadOfTarget(deltaS: Int)
    case aheadOfPB(deltaS: Int, targetToChase: Bool)
    case onPB
    case behindPB(deltaS: Int, easy: Bool)
    case vsRun(date: Date, deltaS: Int) // cumulative, + = slower
}

/// Engine thresholds; all values overridable for tests.
struct CueTuning {
    var warmupM: Double = 400
    var warmupS: Double = 90
    var coachingGapS: Double = 300
    var resumeWarmupM: Double = 200
    var sustainS: Double = 30
    var easyFastS: Double = 15
    var easyRepeatS: Double = 120
    var tempoBandS: Double = 8
    var repeatS: Double = 90
    var fastStartS: Double = 8
    var fastStartSustainS: Double = 15
    var raceBandS: Double = 6
    var hillM: Double = 6
    var onTargetSustainS: Double = 45
    var onTargetMinGapM: Double = 2000
    var pbStartM: Double = 1500
    var pbOnS: Double = 5
    var pbSlipS: Double = 2
}

enum CueDecision: Equatable {
    case fire(CueEvent)
    case suppress(CueEvent, reason: String)
}

/// Pure cue rules: one `step` per tick, decisions only — no speech, no queue.
struct CueEngine {
    let context: RunContext
    let tuning: CueTuning

    private enum PBState { case unknown, on, off }

    private var didStart = false
    private var lastDistance = 0.0
    private var wasPaused = false
    private var resumeDistance = -Double.greatestFiniteMagnitude
    private var tooFastSince: TimeInterval?
    private var tooSlowSince: TimeInterval?
    private var inBandSince: TimeInterval?
    private var lastFired: [String: TimeInterval] = [:] // per-kind repeat cooldown
    private var correctionPending = false
    private var lastOnTargetDistance = -Double.greatestFiniteMagnitude
    private var splitCount = 0
    private var pbState: PBState = .unknown
    private var nextPBCheck: Double
    private var pbHoldFired = false
    private var halfwayFired = false
    private var lastKmFired = false
    private var lastCoachingClock: TimeInterval?
    private var lastKmCheckIndex = 0
    private var toGo500Fired: Set<String> = []

    init(context: RunContext, tuning: CueTuning = .init()) {
        self.context = context
        self.tuning = tuning
        nextPBCheck = tuning.pbStartM
    }

    mutating func step(_ s: CueSnapshot) -> [CueDecision] {
        var decisions: [CueDecision] = []
        func emit(_ d: CueDecision) {
            decisions.append(d)
            if case .fire(let e) = d, e.isPacing, e != .onTarget {
                correctionPending = true
            }
        }

        if !didStart, s.clock >= 2 {
            didStart = true
            emit(.fire(.start))
        }
        if wasPaused, !s.paused { resumeDistance = s.distanceM }

        // Completed-km splits.
        if s.splitSeconds.count > splitCount {
            for km in (splitCount + 1)...s.splitSeconds.count {
                let seconds = s.splitSeconds[km - 1]
                let totalS = s.splitSeconds.prefix(km).reduce(0, +)
                let isFinish = context.plannedM.map {
                    km == Int(($0 / 1000).rounded())
                } ?? false
                let comment = isFinish || consumeCoachingBudget(at: s)
                emit(.fire(.split(
                    km: km, seconds: seconds, totalS: totalS,
                    comment: comment,
                    progress: splitProgress(km: km, totalS: totalS)
                )))
            }
            splitCount = s.splitSeconds.count
        }

        // Pacing corrections.
        let pace = s.paceSPerKm
        let active = context.style != .none && context.targetPace != nil
            && !s.paused
            && s.distanceM >= tuning.warmupM && s.clock >= tuning.warmupS
            && s.distanceM >= resumeDistance + tuning.resumeWarmupM
        guard active, let target = context.targetPace else {
            tooFastSince = nil
            tooSlowSince = nil
            inBandSince = nil
            return finish(s, decisions: decisions)
        }
        guard pace > 0 else {
            tooFastSince = nil
            tooSlowSince = nil
            inBandSince = nil
            return finish(s, decisions: decisions)
        }

        switch context.style {
        case .easy:
            if sustain(pace < target - tuning.easyFastS, since: &tooFastSince,
                       clock: s.clock, sustainS: tuning.sustainS),
               cooled("tooFast", clock: s.clock, gap: tuning.easyRepeatS) {
                emit(s.descentLast200M >= tuning.hillM
                    ? .suppress(.tooFast, reason: "hill")
                    : coachingDecision(for: .tooFast, at: s))
            }
        case .tempo:
            if sustain(pace < target - tuning.tempoBandS, since: &tooFastSince,
                       clock: s.clock, sustainS: tuning.sustainS),
               cooled("tooFast", clock: s.clock, gap: tuning.repeatS) {
                emit(s.descentLast200M >= tuning.hillM
                    ? .suppress(.tooFast, reason: "hill")
                    : coachingDecision(for: .tooFast, at: s))
            }
            if sustain(pace > target + tuning.tempoBandS, since: &tooSlowSince,
                       clock: s.clock, sustainS: tuning.sustainS),
               cooled("tooSlow", clock: s.clock, gap: tuning.repeatS) {
                let event = CueEvent.tooSlow(deltaS: Int((pace - target).rounded()))
                emit(s.climbLast200M >= tuning.hillM
                    ? .suppress(event, reason: "hill")
                    : coachingDecision(for: event, at: s))
            }
        case .race:
            if s.distanceM >= 1000 {
                if sustain(pace > target + tuning.raceBandS, since: &tooSlowSince,
                           clock: s.clock, sustainS: tuning.sustainS),
                   cooled("tooSlow", clock: s.clock, gap: tuning.repeatS) {
                    let event = CueEvent.tooSlow(deltaS: Int((pace - target).rounded()))
                    emit(s.climbLast200M >= tuning.hillM
                        ? .suppress(event, reason: "hill")
                        : coachingDecision(for: event, at: s))
                }
            }
        case .none:
            break
        }

        // On-target confirmation once pace settles after a correction.
        if correctionPending {
            let inBand: Bool = switch context.style {
            case .easy: pace >= target - tuning.easyFastS
            case .tempo: abs(pace - target) <= tuning.tempoBandS
            case .race: abs(pace - target) <= tuning.raceBandS
            case .none: false
            }
            if sustain(inBand, since: &inBandSince, clock: s.clock,
                       sustainS: tuning.onTargetSustainS),
               s.distanceM - lastOnTargetDistance >= tuning.onTargetMinGapM {
                let decision = coachingDecision(for: .onTarget, at: s)
                emit(decision)
                if case .fire = decision {
                    lastOnTargetDistance = s.distanceM
                    correctionPending = false
                }
            }
        } else {
            inBandSince = nil
        }

        return finish(s, decisions: decisions)
    }

    /// PB race calls and distance milestones — evaluated every step.
    private mutating func finish(_ s: CueSnapshot,
                                 decisions: [CueDecision]) -> [CueDecision] {
        var decisions = decisions
        func emit(_ d: CueDecision) { decisions.append(d) }

        if let planned = context.plannedM, planned >= 1500,
           s.distanceM >= planned - 500,
           toGo500Fired.insert("planned").inserted {
            emit(.fire(.toGo500(label: nil)))
        } else if case .free = context.mode {
            for distance in RunMath.standardDistances
                where s.distanceM >= distance.metres - 500
                    && s.distanceM < distance.metres
                    && !toGo500Fired.contains(distance.key) {
                toGo500Fired.insert(distance.key)
                emit(.fire(.toGo500(label: distance.key)))
            }
        }

        let kmIndex = Int(s.distanceM / 1000)
        if context.mode.isUnprescribed, !s.paused,
           kmIndex >= 1, kmIndex > lastKmCheckIndex,
           s.distanceM >= Double(kmIndex) * 1000 + 600,
           let previousSplitS = s.splitSeconds.last, s.paceSPerKm > 0 {
            lastKmCheckIndex = kmIndex
            let elapsedInKm = s.movingS - s.splitSeconds.reduce(0, +)
            let projectedS = elapsedInKm + s.paceSPerKm * 0.4
            let deltaS = Int((projectedS - previousSplitS).rounded())
            if deltaS <= -3 || (-2...2).contains(deltaS) || deltaS >= 6 {
                let event = CueEvent.kmCheck(projectedDeltaS: deltaS)
                let onHill = deltaS >= 6
                    ? s.climbLast200M >= tuning.hillM
                    : deltaS <= -3 && s.descentLast200M >= tuning.hillM
                emit(onHill
                    ? .suppress(event, reason: "hill")
                    : coachingDecision(for: event, at: s))
            }
        }

        if context.style == .race, let ref = context.reference {
            if s.distanceM >= nextPBCheck, s.distanceM < ref.metres {
                nextPBCheck += 500
                let delta = ref.secondsAt(s.distanceM) - s.movingS
                if delta > tuning.pbOnS, pbState != .on {
                    pbState = .on
                    emit(coachingDecision(
                        for: .pbOn(aheadS: Int(delta.rounded()), isTarget: ref.isTarget),
                        at: s
                    ))
                } else if pbState == .on, delta < tuning.pbSlipS {
                    pbState = .off
                    emit(coachingDecision(
                        for: .pbSlipping(
                            behindS: delta < 0 ? Int((-delta).rounded()) : nil,
                            isTarget: ref.isTarget
                        ),
                        at: s
                    ))
                }
            }
            if !pbHoldFired, pbState == .on,
               lastDistance < ref.metres - 800, s.distanceM >= ref.metres - 800 {
                pbHoldFired = true
                emit(coachingDecision(
                    for: .pbHold(remainingM: 800, isTarget: ref.isTarget),
                    at: s
                ))
            }
        }

        if let planned = context.plannedM {
            if !halfwayFired, planned >= 3000,
                lastDistance < planned / 2, s.distanceM >= planned / 2 {
                halfwayFired = true
                emit(coachingDecision(for: .halfway, at: s))
            }
            if !lastKmFired, planned >= 2000,
               lastDistance < planned - 1000, s.distanceM >= planned - 1000 {
                lastKmFired = true
                emit(coachingDecision(
                    for: .lastKm(hard: context.style == .race || context.style == .tempo),
                    at: s
                ))
            }
        }

        lastDistance = s.distanceM
        wasPaused = s.paused
        return decisions
    }

    private mutating func coachingDecision(
        for event: CueEvent, at snapshot: CueSnapshot
    ) -> CueDecision {
        consumeCoachingBudget(at: snapshot)
            ? .fire(event)
            : .suppress(event, reason: "budget")
    }

    private mutating func consumeCoachingBudget(at snapshot: CueSnapshot) -> Bool {
        guard snapshot.distanceM >= tuning.warmupM,
              snapshot.clock >= tuning.warmupS,
              lastCoachingClock.map({
                  snapshot.clock - $0 >= tuning.coachingGapS
              }) ?? true
        else { return false }
        lastCoachingClock = snapshot.clock
        return true
    }

    /// True once `condition` has held continuously for `sustainS`.
    private func sustain(
        _ condition: Bool, since: inout TimeInterval?,
        clock: TimeInterval, sustainS: Double
    ) -> Bool {
        guard condition else { since = nil; return false }
        if since == nil { since = clock }
        return clock - (since ?? clock) >= sustainS
    }

    /// Per-kind repeat cooldown; passing it also stamps the clock (so a hill
    /// suppression still counts against the repeat gap).
    private mutating func cooled(
        _ kind: String, clock: TimeInterval, gap: Double
    ) -> Bool {
        if let last = lastFired[kind], clock - last < gap { return false }
        lastFired[kind] = clock
        return true
    }

    /// Cumulative progress at the completed km against target, PB, or the
    /// most comparable past run — positive deltas mean ahead.
    private func splitProgress(km: Int, totalS: Double) -> SplitProgress? {
        let d = Double(km) * 1000
        let pb = context.progressPB
        let target: PBReference? = if case .free = context.mode {
            nil
        } else {
            context.progressTarget
        }
        let dPB = pb.map { $0.projectedSecondsAt(d) - totalS }
        let dT = target.map { $0.projectedSecondsAt(d) - totalS }
        if let target, let dT, dT > 3,
           pb == nil || target.totalS < (pb?.totalS ?? .infinity) {
            return .aheadOfTarget(deltaS: Int(dT.rounded()))
        }
        if let pb, let dPB {
            if dPB > 3 {
                let chase = target != nil && dT != nil && dT! <= 3
                    && target!.totalS < pb.totalS
                return .aheadOfPB(deltaS: Int(dPB.rounded()), targetToChase: chase)
            }
            if abs(dPB) <= 3 { return .onPB }
            return .behindPB(
                deltaS: Int((-dPB).rounded()), easy: context.style == .easy)
        }
        if let comparable = context.comparable,
           comparable.splitSeconds.count >= km {
            let theirs = comparable.splitSeconds.prefix(km).reduce(0, +)
            return .vsRun(
                date: comparable.startedAt,
                deltaS: Int((totalS - theirs).rounded())
            )
        }
        return nil
    }
}
