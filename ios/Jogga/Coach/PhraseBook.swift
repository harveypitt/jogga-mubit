import Foundation

/// Deterministic seedable RNG (SplitMix64) so replay and tests are stable.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick(_ n: Int) -> Int { n > 0 ? Int(next() % UInt64(n)) : 0 }
    mutating func chance(_ p: Double) -> Bool {
        Double(next() >> 11) / Double(1 << 53) < p
    }
}

/// Turns cue events into spoken sentences. The split cue is composed so
/// every kilometre sounds a little different; everything else rotates
/// deterministically per event kind.
struct PhraseBook {
    private var counters: [String: Int] = [:]
    private var rng: SeededRNG
    private var lines: CoachLines
    /// Shuffle bag per pool — lines are dealt out without repeats until the
    /// pool is exhausted, then reshuffled.
    private var bags: [String: [Int]] = [:]

    // Split composer state.
    private var previousSplitS: Double?
    private var lastSplitVariant = -1
    private var lastTotalVariant = 0
    private var lastProgressKey = ""
    private var lastProgressIdx = -1
    /// Indices of the slots chosen for the most recent split cue —
    /// [splitVariant, totalVariant or -1, commentKind, commentIdx], exposed
    /// so tests can compare structure across kilometres.
    private(set) var lastSplitIndices: [Int] = []

    init(seed: UInt64 = 0, lines: CoachLines = .defaults) {
        rng = SeededRNG(seed: seed)
        self.lines = lines
    }

    mutating func text(for event: CueEvent, context: RunContext, now: Date) -> String {
        switch event {
        case .start:
            switch context.mode {
            case let .plan(kind, km, pace):
                return "\(kind.capitalized) \(SpokenNumbers.km(km)) today. "
                    + "Around \(SpokenNumbers.pace(pace))."
            case let .race(distanceKey):
                let name = spokenDistance(distanceKey)
                if let ref = context.reference {
                    let label = ref.isTarget ? "Target" : "PB"
                    return "\(name) today. \(label) is "
                        + "\(SpokenNumbers.duration(ref.totalS)). Let's go."
                }
                return "\(name) today. Let's go."
            case .free:
                return "Free run. I'll call your splits."
            }
        case .tooFast:
            if context.mode.isUnprescribed { return "A quick kilometre. Keep building." }
            switch context.style {
            case .easy:
                return pick("tooFast.easy", [
                    "Ease off a touch. This should feel chatty.",
                    "Bit quick for an easy day. Back off.",
                    "Slow it down. Easy means easy.",
                ])
            default:
                return pick("tooFast", [
                    "A touch quick. Settle onto target.",
                    "Rein it in slightly.",
                ])
            }
        case .fastStart:
            if context.mode.isUnprescribed { return "Quick start. Keep building." }
            return pick("fastStart", [
                "First kilometre's quick. That's borrowed time.",
                "Quick start. Settle now, it pays later.",
            ])
        case let .tooSlow(deltaS):
            let s = SpokenNumbers.seconds(deltaS)
            return pick("tooSlow", [
                "You've dropped \(s). Lift for the next two hundred metres.",
                "\(s.prefix(1).uppercased() + s.dropFirst()) off target. Pick it up a little.",
            ])
        case .onTarget:
            return pick("onTarget", [
                "Lovely. Hold exactly this.",
                "That's the pace. Stay here.",
                "Right on it. Keep it there.",
            ])
        case let .split(km, seconds, totalS, comment, progress):
            defer { previousSplitS = seconds }
            return splitText(
                km: km, seconds: seconds, totalS: totalS,
                comment: comment, progress: progress, context: context, now: now,
                lines: lines.filtered(for: context.mode)
            )
        case let .pbOn(aheadS, isTarget):
            let label = isTarget ? "Target's" : "PB is"
            return "\(label) on. You're \(SpokenNumbers.seconds(aheadS)) ahead."
        case let .pbSlipping(behindS, isTarget):
            let label = isTarget ? "Target's" : "PB's"
            if let behindS {
                return "\(label) slipping. Find \(SpokenNumbers.seconds(behindS))."
            }
            return "\(label) slipping. Lift a touch."
        case let .pbHold(remainingM, isTarget):
            let label = isTarget ? "Target's" : "PB is"
            return "\(label) on. Hold this for \(SpokenNumbers.metres(remainingM))."
        case .halfway:
            if case .race = context.mode {
                return "Halfway. Try to run the second half a touch quicker."
            }
            return pick("halfway", [
                "Halfway. You've got more left than you think.",
                "Halfway. Try to run the second half a touch quicker.",
                "Halfway there. Nice and steady.",
            ])
        case let .lastKm(hard):
            return hard
                ? "Last kilometre. Empty the tank."
                : "Last kilometre. Nice and relaxed."
        case let .kmCheck(projectedDeltaS):
            if projectedDeltaS <= -3 {
                return "On track to beat your last kilometre."
            }
            if (-2...2).contains(projectedDeltaS) {
                return "Bang on pace for an even split."
            }
            return "Pace is dropping, about \(SpokenNumbers.seconds(projectedDeltaS)) "
                + "down on your last kilometre."
        case let .toGo500(label):
            if let label {
                return "Five hundred metres to \(spokenDistance(label)). Big finish."
            }
            return "Five hundred metres to go. Time for a big finish."
        }
    }

    /// Rotating variant picker — consecutive calls never repeat.
    private mutating func pick(_ kind: String, _ variants: [String]) -> String {
        let i = counters[kind, default: 0]
        counters[kind] = i + 1
        return variants[i % variants.count]
    }

    // MARK: Split composer

    /// One varied cue per kilometre: always says the split, sometimes the
    /// total, and includes a comment only when it was granted by the engine.
    private mutating func splitText(
        km: Int, seconds: Double, totalS: Double,
        comment: Bool, progress: SplitProgress?, context: RunContext, now: Date,
        lines: CoachLines
    ) -> String {
        let plannedKm = context.plannedM.map { Int(($0 / 1000).rounded()) }
        var parts: [String] = []
        var indices: [Int] = [-1, -1, -1, -1]
        defer { lastSplitIndices = indices }

        // Split phrasing — rotate, never the same variant twice running.
        // Variant 3 uses the long minutesSeconds form at most 1 km in 3.
        let kmWord = SpokenNumbers.word(km)
        let short = SpokenNumbers.shortSplit(seconds)
        // Long minutesSeconds phrasing at most one km in three (kms 3, 6, …).
        var candidates = [0, 1, 2, 3].filter { $0 != lastSplitVariant }
        if km % 3 != 0 {
            candidates.removeAll { $0 == 3 }
        }
        if candidates.isEmpty { candidates = [0, 1, 2].filter { $0 != lastSplitVariant } }
        let splitVariant = candidates[rng.pick(candidates.count)]
        lastSplitVariant = splitVariant
        switch splitVariant {
        case 0:
            parts.append("Kilometre \(kmWord), \(short).")
        case 1:
            parts.append("That one was \(short).")
        case 2:
            parts.append("Last K in \(short).")
        default:
            let long = SpokenNumbers.minutesSeconds(seconds)
            parts.append(
                "\(long.prefix(1).uppercased() + long.dropFirst()) "
                + "for kilometre \(kmWord).")
        }
        indices[0] = splitVariant

        // km 1 stays short: split plus at most one comment.
        if km == 1 {
            if comment,
               let line = pickFrom(
                   context.mode.isUnprescribed ? lines.encourage : lines.settle,
                   bag: context.mode.isUnprescribed ? "encourage" : "settle"
               ) {
                parts.append(line)
                indices[2] = context.mode.isUnprescribed ? 3 : 4
            }
            return parts.joined(separator: " ")
        }

        // Total time: km 2, halfway of a ≥4 km plan, final km, or every 3rd
        // km without a plan.
        let halfway = plannedKm.map { $0 >= 4 && km == $0 / 2 } ?? false
        let finalKm = km == plannedKm
        let unplannedEvery3 = plannedKm == nil && km % 3 == 0
        if km == 2 || halfway || finalKm || unplannedEvery3 {
            let v = lastTotalVariant
            lastTotalVariant = (v + 1) % 3
            switch v {
            case 0:
                let done = "\(kmWord) K done in \(SpokenNumbers.shortClock(totalS))."
                parts.append(done.prefix(1).uppercased() + done.dropFirst())
            case 1:
                let m = Int(totalS) / 60
                let r = Int(totalS) % 60
                let mins = r == 0
                    ? "\(SpokenNumbers.word(m)) minutes"
                    : "\(SpokenNumbers.word(m)) minutes \(SpokenNumbers.word(r))"
                parts.append("\(mins.prefix(1).uppercased() + mins.dropFirst()) on the clock.")
            default:
                let kmWords = SpokenNumbers.kilometres(km)
                parts.append(
                    "\(kmWords.prefix(1).uppercased() + kmWords.dropFirst()) "
                    + "in \(SpokenNumbers.shortClock(totalS)).")
            }
            indices[1] = v
        }

        guard comment else { return parts.joined(separator: " ") }

        // Comment slot — at most one sentence by priority.
        if km == (plannedKm ?? -1) - 1 {
            indices[2] = 0
            var one = "One to go."
            if let line = pickFrom(lines.encourage, bag: "encourage") { one += " \(line)" }
            parts.append(one)
        } else if km == plannedKm {
            indices[2] = 0
            indices[3] = 1
            parts.append(
                pickFrom(lines.finish, bag: "finish") ?? "That's the run. Well run."
            )
        } else if let progress {
            indices[2] = 1
            parts.append(progressSentence(progress, now: now, mode: context.mode))
        } else if let prev = previousSplitS {
            let delta = Int((prev - seconds).rounded())
            if abs(delta) >= 5 {
                indices[2] = 2
                if delta > 0 {
                    let s = SpokenNumbers.seconds(delta)
                    let quicker = "\(s.prefix(1).uppercased() + s.dropFirst()) "
                        + "quicker than the last one."
                    parts.append(context.mode.isUnprescribed
                        ? "\(quicker) Keep building." : quicker)
                } else {
                    if context.mode.isUnprescribed {
                        parts.append(
                            "\(SpokenNumbers.seconds(-delta).capitalized) "
                                + "down on the last one."
                        )
                    } else {
                        parts.append("Eased off a little there.")
                    }
                }
            } else if let line = pickFrom(lines.encourage, bag: "encourage") {
                indices[2] = 3
                parts.append(line)
            }
        } else if let line = pickFrom(lines.encourage, bag: "encourage") {
            indices[2] = 3
            parts.append(line)
        }
        return parts.joined(separator: " ")
    }

    /// One item from a pool via a seeded shuffle bag — every line is used
    /// once before the bag reshuffles, so nothing repeats back to back.
    private mutating func pickFrom(_ pool: [String], bag name: String) -> String? {
        guard !pool.isEmpty else { return nil }
        var bag = bags[name] ?? []
        if bag.isEmpty {
            bag = Array(0..<pool.count)
            // Fisher–Yates with the seeded RNG.
            for i in stride(from: bag.count - 1, through: 1, by: -1) {
                bag.swapAt(i, rng.pick(i + 1))
            }
        }
        let idx = bag.removeLast()
        bags[name] = bag
        return pool[idx]
    }

    /// Progress sentence with rotation: 2–3 rewordings per case, never the
    /// same sentence two kms running.
    private mutating func progressSentence(
        _ p: SplitProgress, now: Date, mode: CoachMode
    ) -> String {
        let key = progressKey(p)
        let pool = progressVariants(p, now: now, mode: mode)
        if key != lastProgressKey { lastProgressIdx = -1 }
        lastProgressKey = key
        var i = rng.pick(pool.count)
        if i == lastProgressIdx, pool.count > 1 { i = (i + 1) % pool.count }
        lastProgressIdx = i
        return pool[i]
    }

    private func progressKey(_ p: SplitProgress) -> String {
        switch p {
        case .aheadOfTarget: return "aheadOfTarget"
        case let .aheadOfPB(_, chase): return chase ? "aheadOfPB.chase" : "aheadOfPB"
        case .onPB: return "onPB"
        case let .behindPB(_, easy): return easy ? "behindPB.easy" : "behindPB"
        case let .vsRun(_, d): return d < -3 ? "vsRun.quicker"
            : d > 3 ? "vsRun.slower" : "vsRun.level"
        }
    }

    private func progressVariants(
        _ p: SplitProgress, now: Date, mode: CoachMode
    ) -> [String] {
        if mode.isUnprescribed {
            return unprescribedProgressVariants(p, now: now)
        }
        switch p {
        case let .aheadOfTarget(deltaS):
            let s = SpokenNumbers.seconds(deltaS)
            return [
                "You're \(s) ahead of your target. Brilliant, hold this.",
                "\(s.prefix(1).uppercased() + s.dropFirst()) up on target. Keep it smooth.",
            ]
        case let .aheadOfPB(deltaS, chase):
            let s = SpokenNumbers.seconds(deltaS)
            if chase {
                return [
                    "That's good progress compared to your PB. Just keep this pace and don't worry about your target today.",
                    "Ahead of your PB and looking easy. The target can look after itself today.",
                ]
            }
            return [
                "You're \(s) ahead of your PB pace. Keep this up and it's a new PB.",
                "\(s.prefix(1).uppercased() + s.dropFirst()) up on your PB. Stay relaxed, it's coming.",
            ]
        case .onPB:
            return [
                "Right on your PB pace. Hold this.",
                "Bang on PB pace. Lovely running.",
            ]
        case let .behindPB(deltaS, easy):
            if easy {
                return [
                    "Nice and controlled. Exactly right for an easy day.",
                    "Behind PB pace, and that's right for today. Keep it easy.",
                ]
            }
            let s = SpokenNumbers.seconds(deltaS)
            return [
                "\(s.prefix(1).uppercased() + s.dropFirst()) behind your PB pace. Stay relaxed and keep it steady.",
                "\(s.prefix(1).uppercased() + s.dropFirst()) off PB pace. Keep the effort honest.",
            ]
        case let .vsRun(date, deltaS):
            let day = dayName(date, now: now)
            if abs(deltaS) < 3 {
                return ["Level with \(day).", "Neck and neck with \(day)."]
            }
            let s = SpokenNumbers.seconds(abs(deltaS))
            if deltaS < 0 {
                return [
                    "\(s.prefix(1).uppercased() + s.dropFirst()) quicker than \(day). Great progress.",
                    "Up on \(day) by \(s). Keep it rolling.",
                ]
            }
            return [
                "\(s.prefix(1).uppercased() + s.dropFirst()) slower than \(day). Keep it steady.",
                "Down on \(day) by \(s). Stay patient.",
            ]
        }
    }

    private func unprescribedProgressVariants(
        _ p: SplitProgress, now: Date
    ) -> [String] {
        switch p {
        case let .aheadOfTarget(deltaS):
            return ["You're \(SpokenNumbers.seconds(deltaS)) ahead of your target."]
        case let .aheadOfPB(deltaS, _):
            let seconds = SpokenNumbers.seconds(deltaS)
            return [
                "You're \(seconds) ahead of your PB pace. Keep building.",
                "\(seconds.capitalized) up on your PB. Great running.",
            ]
        case .onPB:
            return ["Right on your PB pace. Great running."]
        case let .behindPB(deltaS, _):
            return ["\(SpokenNumbers.seconds(deltaS).capitalized) behind your PB pace."]
        case let .vsRun(date, deltaS):
            let day = dayName(date, now: now)
            if abs(deltaS) < 3 { return ["Level with \(day)."] }
            let seconds = SpokenNumbers.seconds(abs(deltaS)).capitalized
            return deltaS < 0
                ? ["\(seconds) quicker than \(day). Keep building."]
                : ["\(seconds) down on \(day). Keep going."]
        }
    }

    /// "earlier today" / weekday name for a run 1–6 days back / "last time".
    private func dayName(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 { return "earlier today" }
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return "last time"
    }

    private func spokenDistance(_ key: String) -> String {
        switch key {
        case "5k": return "Five K"
        case "10k": return "Ten K"
        case "half": return "Half marathon"
        case "marathon": return "Marathon"
        default: return key
        }
    }
}
