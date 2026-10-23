import CoreLocation
import XCTest
@testable import Jogga

final class CueEngineTests: XCTestCase {
    private let now = Date()

    /// Straight-line samples at 1 s steps. `pace` gives s/km at the current
    /// distance; `alt` gives altitude at the current distance.
    private func samples(
        distance: Double,
        pace: (Double) -> Double,
        alt: (Double) -> Double = { _ in 10 },
        hAcc: (Double) -> Double = { _ in 5 }
    ) -> [RunMath.Sample] {
        var out: [RunMath.Sample] = []
        var t = 0.0
        var d = 0.0
        while d < distance {
            let step = 1000 / pace(d) // metres covered this second
            t += 1
            d += step
            out.append(RunMath.Sample(
                t: t,
                coordinate: CLLocationCoordinate2D(
                    latitude: 37 + d / 111_320, longitude: -122
                ),
                horizontalAccuracy: hAcc(d), altitude: alt(d), verticalAccuracy: 4
            ))
        }
        return out
    }

    /// Piecewise pace: [(metres boundary, s/km)] — last entry wins.
    private func piecewise(_ segments: [(until: Double, pace: Double)]) -> (Double) -> Double {
        { d in segments.first { d < $0.until }?.pace ?? segments.last?.pace ?? 300 }
    }

    private func run(
        samples: [RunMath.Sample],
        mode: CoachMode, history: [Run] = [],
        targets: [String: Int] = [:], serverBest: [String: Double] = [:],
        level: CueLevel = .everyKm, coachingGapS: Double? = nil
    ) -> CueLog {
        let context = RunContext.make(
            mode: mode, history: history, targets: targets,
            serverBest: serverBest, now: now
        )
        var tuning = CueTuning()
        if let coachingGapS { tuning.coachingGapS = coachingGapS }
        return CueSimulator.run(
            samples: samples, context: context, tuning: tuning,
            level: level, now: now
        )
    }

    private func spoken(_ log: CueLog) -> [CueLog.Entry] {
        log.entries.filter { $0.outcome == "spoken" }
    }

    private func snapshot(
        clock: TimeInterval, distanceM: Double, movingS: Double = 0,
        paceSPerKm: Double = 300, splitSeconds: [Double] = [],
        climb: Double = 0, descent: Double = 0, paused: Bool = false
    ) -> CueSnapshot {
        CueSnapshot(
            clock: clock, distanceM: distanceM, movingS: movingS,
            paceSPerKm: paceSPerKm, splitSeconds: splitSeconds,
            climbLast200M: climb, descentLast200M: descent, paused: paused
        )
    }

    private func makeRun(
        daysAgo: Double, metres: Double, splits: [Double],
        efforts: [String: Double] = [:]
    ) -> Run {
        Run(
            id: UUID(),
            startedAt: now.addingTimeInterval(-daysAgo * 86400),
            distanceM: metres, movingS: splits.reduce(0, +), elapsedS: 0,
            gainM: 0, lossM: 0,
            splits: splits.map { Run.Split(distanceM: 1000, movingS: $0, gainM: 0, lossM: 0) },
            efforts: efforts, route: []
        )
    }

    // MARK: 1. Easy run on pace: start + splits only

    func testEasyOnPaceSpeaksStartAndSplits() {
        let log = run(
            samples: samples(distance: 5100, pace: { _ in 360 }),
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 360)
        )
        let kinds = spoken(log).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == "split" }.count, 5)
        XCTAssertTrue(kinds.allSatisfy {
            ["start", "split", "halfway", "lastKm", "toGo500"].contains($0)
        })
    }

    // MARK: 2. Easy run too fast: repeated tooFast after warmup

    func testEasyTooFast() {
        let log = run(
            samples: samples(distance: 5000, pace: { _ in 330 }),
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 360)
        )
        let fast = spoken(log).filter { $0.kind == "tooFast" }
        XCTAssertFalse(fast.isEmpty)
        guard let first = fast.first else { return }
        XCTAssertGreaterThanOrEqual(first.distanceM, 400)
        XCTAssertGreaterThanOrEqual(first.clock, 120)
        for pair in zip(fast, fast.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.clock - pair.0.clock, 120)
        }
        XCTAssertTrue(spoken(log).allSatisfy { $0.kind != "tooSlow" })
    }

    // MARK: 3. Easy run slow: no tooSlow ever

    func testEasyNeverTooSlow() {
        let log = run(
            samples: samples(distance: 4000, pace: { _ in 400 }),
            mode: .plan(kind: "easy", km: 4, paceSPerKm: 360)
        )
        XCTAssertTrue(log.entries.allSatisfy { $0.kind != "tooSlow" })
    }

    // MARK: 4. Race efforts never get tooFast or fastStart cues

    func testRaceDoesNotEmitTooFastOrFastStart() {
        let log = run(
            samples: samples(
                distance: 5000,
                pace: piecewise([(1000, 280), (5000, 300)])
            ),
            mode: .race(distanceKey: "5k"),
            targets: ["5k": 1500]
        )
        XCTAssertFalse(log.entries.contains {
            $0.kind == "fastStart" || $0.kind == "tooFast"
        })
    }

    // MARK: 5. Tempo tooSlow then onTarget

    func testTempoTooSlowThenOnTarget() {
        let log = run(
            samples: samples(
                distance: 6000,
                pace: piecewise([(2000, 300), (3500, 316), (6000, 300)])
            ),
            mode: .plan(kind: "tempo", km: 6, paceSPerKm: 300)
        )
        let kinds = spoken(log).map(\.kind)
        guard let slowIndex = kinds.firstIndex(of: "tooSlow") else {
            return XCTFail("no tooSlow spoken")
        }
        XCTAssertTrue(kinds.dropFirst(slowIndex + 1).contains("onTarget"))
        // delta 16 s: "You've dropped sixteen seconds…" or "Sixteen seconds…"
        XCTAssertNotNil(spoken(log)[slowIndex].text
            .range(of: "sixteen", options: .caseInsensitive))
    }

    // MARK: 6. Hill guard suppresses tooSlow while climbing

    func testHillGuardSuppressesTooSlow() {
        let log = run(
            samples: samples(
                distance: 4000,
                pace: piecewise([(2000, 300), (3000, 320), (4000, 300)]),
                alt: { d in d >= 2000 && d < 3000 ? 10 + (d - 2000) / 200 * 10 : 10 }
            ),
            mode: .plan(kind: "tempo", km: 4, paceSPerKm: 300)
        )
        XCTAssertTrue(spoken(log).allSatisfy { $0.kind != "tooSlow" })
        let suppressed = log.entries.filter {
            $0.kind == "tooSlow" && $0.outcome == "suppressed" && $0.reason == "hill"
        }
        XCTAssertFalse(suppressed.isEmpty)
    }

    // MARK: 7. A 10 s GPS blip produces no pacing cues

    func testGPSBlipNoPacing() {
        // 10 s of unusable accuracy at ~2 km — the acceptance filter drops
        // them, so the coach never sees the blip.
        let log = run(
            samples: samples(
                distance: 4000,
                pace: { _ in 300 },
                hAcc: { d in d >= 2000 && d < 2017 ? 50 : 5 }
            ),
            mode: .race(distanceKey: "5k"),
            targets: ["5k": 1500]
        )
        let pacing = spoken(log).filter {
            ["tooFast", "tooSlow", "fastStart", "onTarget"].contains($0.kind)
        }
        XCTAssertTrue(pacing.isEmpty, "unexpected pacing cues: \(pacing)")
    }

    // MARK: 8. Resume: no pacing within 200 m of a pause

    func testPauseResumeWarmup() {
        var out: [RunMath.Sample] = []
        var t = 0.0
        var d = 0.0
        func append(_ pace: Double) {
            t += 1
            d += 1000 / pace
            out.append(RunMath.Sample(
                t: t,
                coordinate: CLLocationCoordinate2D(
                    latitude: 37 + d / 111_320, longitude: -122
                ),
                horizontalAccuracy: 5, altitude: 10, verticalAccuracy: 4
            ))
        }
        while d < 2000 { append(300) }
        t += 60 // pause
        while d < 4000 { append(250) } // fast straight out of the pause
        let log = run(
            samples: out,
            mode: .plan(kind: "tempo", km: 4, paceSPerKm: 300)
        )
        let pacing = spoken(log).filter {
            ["tooFast", "tooSlow", "fastStart", "onTarget"].contains($0.kind)
        }
        XCTAssertTrue(pacing.allSatisfy { $0.distanceM >= 2200 || $0.distanceM < 2000 },
                      "pacing cue inside resume warmup: \(pacing)")
    }

    // MARK: 9. PB tracking: pbOn, pbHold, pbSlipping

    private var pbHistory: [Run] {
        [makeRun(daysAgo: 10, metres: 5000,
                 splits: [300, 300, 300, 300, 300],
                 efforts: ["5k": 1500])]
    }

    func testPBOnAndHold() {
        let context = RunContext.make(
            mode: .race(distanceKey: "5k"), history: pbHistory,
            targets: [:], serverBest: [:], now: now
        )
        XCTAssertEqual(context.style, .race)
        XCTAssertEqual(context.reference?.totalS, 1500)
        let log = run(
            samples: samples(distance: 5000, pace: { _ in 290 }),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            coachingGapS: 0
        )
        let on = spoken(log).filter { $0.kind == "pbOn" }
        guard let onCue = on.first else {
            return XCTFail("no pbOn: \(log.entries.map { ($0.kind, $0.outcome, $0.reason) })")
        }
        XCTAssertEqual(on.count, 1)
        XCTAssertGreaterThanOrEqual(onCue.distanceM, 1400)
        XCTAssertLessThanOrEqual(onCue.distanceM, 2100)
        let hold = spoken(log).filter { $0.kind == "pbHold" }
        XCTAssertEqual(hold.count, 1)
        XCTAssertEqual(hold[0].distanceM, 4200, accuracy: 150)
    }

    func testPBSlipping() {
        let log = run(
            samples: samples(
                distance: 5000,
                pace: piecewise([(3000, 290), (5000, 330)])
            ),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            coachingGapS: 0
        )
        let kinds = spoken(log).map(\.kind)
        guard let onIndex = kinds.firstIndex(of: "pbOn") else {
            return XCTFail("no pbOn")
        }
        XCTAssertTrue(kinds.dropFirst(onIndex + 1).contains("pbSlipping"))
    }

    // MARK: 10. Queue: priority, gaps, expiry, replace

    func testQueueGapsAndExpiry() {
        var queue = CueQueue()
        func cue(_ event: CueEvent, at t: TimeInterval) -> QueuedCue {
            QueuedCue(event: event, text: "x", enqueuedAt: t, distanceM: 0)
        }
        // Split spoken at t=0, finishes at t=5.
        queue.enqueue(cue(.split(
            km: 1, seconds: 300, totalS: 300, comment: false, progress: nil
        ), at: 0))
        let (split, _) = queue.next(now: 0, speaking: false)
        XCTAssertNotNil(split)
        queue.didFinishSpeaking(now: 5)
        // Pacing enqueued at t=5 must wait: 15 s after split, 60 s global.
        queue.enqueue(cue(.tooFast, at: 5))
        let (blocked, _) = queue.next(now: 10, speaking: false)
        XCTAssertNil(blocked)
        // Expires at t=16 (>10 s old) — dropped before it can ever play.
        let (none, dropped) = queue.next(now: 16, speaking: false)
        XCTAssertNil(none)
        XCTAssertEqual(dropped.first?.outcome, "expired")
        XCTAssertEqual(dropped.first?.kind, "tooFast")
        // A fresh pacing cue at t=60 plays once the 60 s global gap passes.
        queue.enqueue(cue(.tooFast, at: 60))
        let (stillBlocked, _) = queue.next(now: 64, speaking: false)
        XCTAssertNil(stillBlocked) // only 59 s since finish at t=5
        let (played, _) = queue.next(now: 66, speaking: false)
        XCTAssertEqual(played?.event, .tooFast)
    }

    func testQueueReplaceSameKind() {
        var queue = CueQueue()
        queue.enqueue(QueuedCue(
            event: .tooFast, text: "one", enqueuedAt: 0, distanceM: 0))
        let replaced = queue.enqueue(QueuedCue(
            event: .tooFast, text: "two", enqueuedAt: 1, distanceM: 0))
        XCTAssertEqual(replaced.first?.outcome, "replaced")
        XCTAssertEqual(replaced.first?.text, "one")
        let (cue, _) = queue.next(now: 2, speaking: false)
        XCTAssertEqual(cue?.text, "two")
    }

    func testToGo500HasSplitPriorityAndTwentySecondExpiry() {
        let split = CueEvent.split(
            km: 1, seconds: 300, totalS: 300, comment: false, progress: nil
        )
        let milestone = CueEvent.toGo500(label: nil)
        XCTAssertEqual(milestone.priority, split.priority)
        XCTAssertFalse(milestone.isPacing)
        XCTAssertTrue(CueEvent.kmCheck(projectedDeltaS: 0).isPacing)

        var queue = CueQueue()
        queue.enqueue(QueuedCue(
            event: milestone, text: "", enqueuedAt: 0, distanceM: 0
        ))
        let (next, dropped) = queue.next(now: 21, speaking: false)
        XCTAssertNil(next)
        XCTAssertEqual(dropped.map(\.outcome), ["expired"])
    }

    // MARK: 11. Spoken numbers and phrasing

    func testSpokenNumbers() {
        XCTAssertEqual(SpokenNumbers.pace(312), "five twelve")
        XCTAssertEqual(SpokenNumbers.pace(305), "five oh five")
        XCTAssertEqual(SpokenNumbers.pace(300), "five flat")
        XCTAssertEqual(SpokenNumbers.pace(3840), "one hour four")
        XCTAssertEqual(SpokenNumbers.duration(1620), "twenty-seven flat")
        XCTAssertEqual(SpokenNumbers.duration(1625), "twenty-seven oh five")
        XCTAssertEqual(SpokenNumbers.duration(6720), "one hour, fifty-two")
        XCTAssertEqual(SpokenNumbers.seconds(1), "one second")
        XCTAssertEqual(SpokenNumbers.seconds(8), "eight seconds")
        XCTAssertEqual(SpokenNumbers.seconds(70), "over a minute")
        XCTAssertEqual(SpokenNumbers.metres(800), "eight hundred metres")
        XCTAssertEqual(SpokenNumbers.km(4), "four")
        XCTAssertEqual(SpokenNumbers.km(4.5), "four point five")
        XCTAssertEqual(SpokenNumbers.km(3), "three")
        XCTAssertEqual(SpokenNumbers.minutesSeconds(336),
                       "five minutes thirty-six seconds")
        XCTAssertEqual(SpokenNumbers.minutesSeconds(300), "five minutes")
        XCTAssertEqual(SpokenNumbers.minutesSeconds(61),
                       "one minute one second")
        XCTAssertEqual(SpokenNumbers.minutesSeconds(3840),
                       "one hour four minutes")
        XCTAssertEqual(SpokenNumbers.kilometres(1), "one kilometre")
        XCTAssertEqual(SpokenNumbers.kilometres(3), "three kilometres")
    }

    func testPhraseBookDayNaming() {
        func splitText(daysAgo: Double) -> String {
            var phrases = PhraseBook()
            var context = RunContext(mode: .free, style: .none)
            context.comparable = ComparableRun(
                startedAt: now.addingTimeInterval(-daysAgo * 86400),
                splitSeconds: [300]
            )
            return phrases.text(
                for: .split(km: 2, seconds: 300, totalS: 600, comment: true,
                            progress: .vsRun(
                                date: context.comparable!.startedAt, deltaS: 0)),
                context: context, now: now
            )
        }
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let yesterday = now.addingTimeInterval(-86400)
        XCTAssertTrue(splitText(daysAgo: 0.1).contains("earlier today"))
        let daysBack = splitText(daysAgo: 1)
        XCTAssertTrue(daysBack.contains(
            yesterday.formatted(.dateTime.weekday(.wide))))
        XCTAssertTrue(splitText(daysAgo: 10).contains("last time"))
        _ = weekday
    }

    func testPhraseBookVariantsRotate() {
        var phrases = PhraseBook()
        let context = RunContext(mode: .free, style: .none)
        let a = phrases.text(for: .halfway, context: context, now: now)
        let b = phrases.text(for: .halfway, context: context, now: now)
        XCTAssertNotEqual(a, b)
        let c = phrases.text(for: .halfway, context: context, now: now)
        XCTAssertNotEqual(b, c)
        let d = phrases.text(for: .halfway, context: context, now: now)
        XCTAssertEqual(a, d) // three variants cycle
    }

    // MARK: 12. RunContext: scaled PB profile and comparable pick

    func testContextPBProfileScaled() {
        let context = RunContext.make(
            mode: .race(distanceKey: "5k"), history: pbHistory,
            targets: [:], serverBest: [:], now: now
        )
        let ref = context.reference
        XCTAssertNotNil(ref)
        XCTAssertFalse(ref?.isTarget ?? true)
        XCTAssertEqual(ref?.secondsAt(5000) ?? 0, 1500, accuracy: 1)
        XCTAssertEqual(ref?.secondsAt(2500) ?? 0, 750, accuracy: 2)
    }

    func testContextPicksFasterReference() {
        // Target (1400) faster than PB (1500) → target wins, even profile.
        let targetWins = RunContext.make(
            mode: .race(distanceKey: "5k"), history: pbHistory,
            targets: ["5k": 1400], serverBest: [:], now: now
        )
        XCTAssertEqual(targetWins.reference?.isTarget, true)
        XCTAssertEqual(targetWins.reference?.totalS ?? 0, 1400, accuracy: 0.5)
        XCTAssertEqual(targetWins.targetPace ?? 0, 280, accuracy: 0.5)
        // Target (1600) slower than PB (1500) → PB wins, shaped profile.
        let pbWins = RunContext.make(
            mode: .race(distanceKey: "5k"), history: pbHistory,
            targets: ["5k": 1600], serverBest: [:], now: now
        )
        XCTAssertEqual(pbWins.reference?.isTarget, false)
        XCTAssertEqual(pbWins.reference?.totalS ?? 0, 1500, accuracy: 0.5)
        XCTAssertEqual(pbWins.targetPace ?? 0, 300, accuracy: 0.5)
        // Neither → no reference, no target pace.
        let neither = RunContext.make(
            mode: .race(distanceKey: "5k"), history: [],
            targets: [:], serverBest: [:], now: now
        )
        XCTAssertNil(neither.reference)
        XCTAssertNil(neither.targetPace)
    }

    func testSplitProgressBranches() {
        // Target faster than PB (1400 < 1500) and the run beats the target:
        // aheadOfTarget while ahead of both.
        let ahead = run(
            samples: samples(distance: 3100, pace: { _ in 270 }),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            targets: ["5k": 1400], coachingGapS: 0
        )
        let aheadSplits = spoken(ahead).filter { $0.kind == "split" }
        XCTAssertTrue(
            aheadSplits.contains { $0.text.contains("target") },
            "texts: \(aheadSplits.map(\.text))")
        // On the PB pace → onPB ("Right on your PB pace").
        let on = run(
            samples: samples(distance: 3100, pace: { _ in 300 }),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            coachingGapS: 0
        )
        XCTAssertTrue(spoken(on).filter { $0.kind == "split" }
            .contains { $0.text.contains("PB pace") })
        // Slower than PB, not easy → behindPB.
        let behind = run(
            samples: samples(distance: 3100, pace: { _ in 330 }),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            coachingGapS: 0
        )
        XCTAssertTrue(spoken(behind).filter { $0.kind == "split" }
            .contains { $0.text.contains("PB pace") })
        // Slower than PB on an easy run → easy wording (5 km plan so the
        // progress slot isn't swallowed by one-to-go/finish).
        let easy = run(
            samples: samples(distance: 5100, pace: { _ in 330 }),
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 330),
            history: pbHistory, coachingGapS: 0
        )
        XCTAssertTrue(spoken(easy).filter { $0.kind == "split" }
            .contains { $0.text.contains("easy") })
        // Ahead of PB while the faster target is still ahead → factual PB wording.
        let chase = run(
            samples: samples(distance: 3100, pace: { _ in 290 }),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            targets: ["5k": 1400], coachingGapS: 0
        )
        XCTAssertTrue(spoken(chase).filter { $0.kind == "split" }
            .contains { $0.text.contains("PB") },
                      "texts: \(spoken(chase).filter { $0.kind == "split" }.map(\.text))")
        // No PB/target → vsRun against the comparable.
        let vs = run(
            samples: samples(distance: 5100, pace: { _ in 330 }),
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 330),
            history: [makeRun(daysAgo: 2, metres: 5000,
                              splits: [300, 300, 300, 300, 300])],
            coachingGapS: 0
        )
        XCTAssertTrue(spoken(vs).filter { $0.kind == "split" }
            .contains {
                $0.text.contains("slower than") || $0.text.contains("Down on")
            })
    }

    func testSplitProgressExtrapolatesBeyondPB() {
        // 6th km on a 5k PB: reference projects past its distance.
        let log = run(
            samples: samples(distance: 6100, pace: { _ in 290 }),
            mode: .race(distanceKey: "5k"), history: pbHistory,
            coachingGapS: 0
        )
        let splits = spoken(log).filter { $0.kind == "split" }
        XCTAssertEqual(splits.count, 6)
        XCTAssertTrue(splits[5].text.contains("PB"),
                      "km6 text: \(splits[5].text)")
    }

    func testSplitsOnlySpeaksStartSplitsAndMilestones() {
        // Fast easy run would trigger tooFast + coaching milestones.
        let log = run(
            samples: samples(distance: 5100, pace: { _ in 330 }),
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 360),
            level: .splitsOnly
        )
        let spokenKinds = spoken(log).map(\.kind)
        XCTAssertEqual(spokenKinds.filter { $0 == "split" }.count, 5)
        XCTAssertEqual(spokenKinds.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(spokenKinds.filter { $0 == "toGo500" }.count, 1)
        XCTAssertFalse(spoken(log).contains { $0.text.contains("One to go") })
        XCTAssertFalse(spoken(log).contains { $0.text.contains("Keep building") })
        let suppressedKinds = log.entries
            .filter { $0.outcome == "suppressed" && $0.reason == "level" }
            .map(\.kind)
        XCTAssertTrue(suppressedKinds.contains("tooFast"))
        XCTAssertTrue(log.entries.contains {
            $0.kind == "halfway" && $0.outcome == "suppressed"
        })
    }

    func testOffLevelSpeaksNothing() {
        let log = run(
            samples: samples(distance: 5100, pace: { _ in 300 }),
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 300),
            level: .off
        )
        XCTAssertTrue(spoken(log).isEmpty)
    }

    func testCoachingBudgetSuppressesAndLaterAllowsEvents() {
        var tuning = CueTuning()
        tuning.warmupM = 0
        tuning.warmupS = 0
        tuning.resumeWarmupM = 0
        tuning.sustainS = 0
        tuning.repeatS = 0
        tuning.coachingGapS = 300
        var engine = CueEngine(
            context: RunContext(
                mode: .plan(kind: "tempo", km: 5, paceSPerKm: 300),
                style: .tempo, targetPace: 300, plannedM: 5000
            ),
            tuning: tuning
        )

        let first = engine.step(snapshot(clock: 2, distanceM: 500, paceSPerKm: 270))
        XCTAssertTrue(first.contains { $0 == .fire(.tooFast) })
        let blocked = engine.step(snapshot(clock: 10, distanceM: 600, paceSPerKm: 330))
        XCTAssertTrue(blocked.contains {
            $0 == .suppress(.tooSlow(deltaS: 30), reason: "budget")
        })
        let allowed = engine.step(snapshot(clock: 303, distanceM: 700, paceSPerKm: 330))
        XCTAssertTrue(allowed.contains { $0 == .fire(.tooSlow(deltaS: 30)) })
    }

    func testSplitsFireEveryKilometreWithBudgetedComments() {
        let context = RunContext(
            mode: .plan(kind: "easy", km: 10, paceSPerKm: 300),
            style: .easy, targetPace: 300, plannedM: 10_000
        )
        var engine = CueEngine(context: context)
        let first = engine.step(snapshot(
            clock: 200, distanceM: 1000, movingS: 300, splitSeconds: [300]
        ))
        let second = engine.step(snapshot(
            clock: 400, distanceM: 2000, movingS: 600, splitSeconds: [300, 300]
        ))
        let comments = [first, second].flatMap { $0 }.compactMap { decision -> Bool? in
            guard case let .fire(.split(_, _, _, comment, _)) = decision else { return nil }
            return comment
        }
        XCTAssertEqual(comments, [true, false])
    }

    func testKmCheckBandsAndHillGuard() {
        func decisions(_ delta: Int, climb: Double = 0, descent: Double = 0) -> [CueDecision] {
            var tuning = CueTuning()
            tuning.warmupM = 400
            tuning.warmupS = 200
            var engine = CueEngine(
                context: RunContext(mode: .free, style: .none), tuning: tuning
            )
            _ = engine.step(snapshot(
                clock: 100, distanceM: 1000, movingS: 300, splitSeconds: [300]
            ))
            return engine.step(snapshot(
                clock: 500, distanceM: 1600, movingS: Double(480 + delta),
                splitSeconds: [300], climb: climb, descent: descent
            ))
        }

        XCTAssertTrue(decisions(-3).contains {
            $0 == .fire(.kmCheck(projectedDeltaS: -3))
        })
        XCTAssertTrue(decisions(2).contains {
            $0 == .fire(.kmCheck(projectedDeltaS: 2))
        })
        XCTAssertTrue(decisions(6).contains {
            $0 == .fire(.kmCheck(projectedDeltaS: 6))
        })
        XCTAssertFalse(decisions(4).contains {
            if case .fire(.kmCheck) = $0 { return true }
            if case .suppress(.kmCheck, _) = $0 { return true }
            return false
        })
        XCTAssertTrue(decisions(6, climb: 8).contains {
            $0 == .suppress(.kmCheck(projectedDeltaS: 6), reason: "hill")
        })
        XCTAssertTrue(decisions(-3, descent: 8).contains {
            $0 == .suppress(.kmCheck(projectedDeltaS: -3), reason: "hill")
        })
    }

    func testToGo500PlanAndRaceOnceEach() {
        let modes: [CoachMode] = [
            .plan(kind: "easy", km: 5, paceSPerKm: 300),
            .race(distanceKey: "5k"),
        ]
        for mode in modes {
            var context = RunContext(mode: mode, style: .easy)
            context.plannedM = 5000
            if case .race = mode {
                context = RunContext.make(
                    mode: mode, history: [], targets: ["5k": 1500],
                    serverBest: [:], now: now
                )
            }
            var engine = CueEngine(context: context)
            _ = engine.step(snapshot(clock: 2, distanceM: 4499))
            let crossed = engine.step(snapshot(clock: 3, distanceM: 4501))
            let later = engine.step(snapshot(clock: 4, distanceM: 4600))
            let cues = (crossed + later).compactMap { decision -> CueEvent? in
                guard case let .fire(event) = decision,
                      case .toGo500 = event else { return nil }
                return event
            }
            XCTAssertEqual(cues.count, 1)
            XCTAssertEqual(cues.first, .toGo500(label: nil))
        }
    }

    func testFreeToGo500MilestonesFireOnce() {
        var engine = CueEngine(context: RunContext(mode: .free, style: .none))
        let snapshots: [(TimeInterval, Double)] = [
            (2, 4499), (3, 4501), (4, 4600), (5, 9499), (6, 9501), (7, 9600),
        ]
        let cues = snapshots.flatMap { clock, distance in
            engine.step(snapshot(clock: clock, distanceM: distance))
        }.compactMap { decision -> CueEvent? in
            guard case let .fire(event) = decision,
                  case .toGo500 = event else { return nil }
            return event
        }
        XCTAssertEqual(cues, [
            .toGo500(label: "5k"), .toGo500(label: "10k"),
        ])
    }

    func testSplitsOnlyStripsCommentsAndLegacyLevelMapsToEveryKm() {
        let event = CueEvent.split(
            km: 2, seconds: 300, totalS: 600, comment: true, progress: nil
        )
        XCTAssertEqual(
            CueLevel.splitsOnly.eventForSpeaking(event),
            .split(km: 2, seconds: 300, totalS: 600, comment: false, progress: nil)
        )
        XCTAssertEqual(CueLevel(rawValue: "full"), .everyKm)
        XCTAssertEqual(CueLevel(rawValue: "everyKm")?.rawValue, "everyKm")
    }

    func testPhraseBookKmCheckToGoAndUnprescribedLanguage() {
        var phrases = PhraseBook()
        XCTAssertEqual(
            phrases.text(
                for: .kmCheck(projectedDeltaS: -3),
                context: RunContext(mode: .free, style: .none), now: now
            ),
            "On track to beat your last kilometre."
        )
        XCTAssertEqual(
            phrases.text(
                for: .kmCheck(projectedDeltaS: 0),
                context: RunContext(mode: .free, style: .none), now: now
            ),
            "Bang on pace for an even split."
        )
        XCTAssertEqual(
            phrases.text(
                for: .toGo500(label: "5k"),
                context: RunContext(mode: .free, style: .none), now: now
            ),
            "Five hundred metres to Five K. Big finish."
        )
        let banned = ["ease", "easy", "slow", "back off", "hold back", "patience",
                      "rein", "settle", "don't chase"]
        for mode in [CoachMode.free, .race(distanceKey: "5k")] {
            let context = RunContext(mode: mode, style: .none)
            let lines = CoachLines.defaults.filtered(for: mode)
            for line in lines.settle + lines.encourage + lines.steady + lines.finish {
                XCTAssertFalse(banned.contains {
                    line.localizedCaseInsensitiveContains($0)
                }, line)
            }
            var phraseBook = PhraseBook()
            let text = phraseBook.text(
                for: .split(
                    km: 2, seconds: 300, totalS: 600, comment: true,
                    progress: .behindPB(deltaS: 8, easy: true)
                ),
                context: context, now: now
            )
            XCTAssertFalse(banned.contains {
                text.localizedCaseInsensitiveContains($0)
            }, text)
            var book = PhraseBook(seed: 4)
            _ = book.text(
                for: .split(km: 1, seconds: 300, totalS: 300,
                            comment: false, progress: nil),
                context: context, now: now
            )
            let quicker = book.text(
                for: .split(km: 2, seconds: 295, totalS: 595,
                            comment: true, progress: nil),
                context: context, now: now
            )
            XCTAssertTrue(quicker.localizedCaseInsensitiveContains(
                "five seconds quicker than the last one. Keep building."
            ))
            let fade = book.text(
                for: .split(km: 3, seconds: 305, totalS: 900,
                            comment: true, progress: nil),
                context: context, now: now
            )
            XCTAssertTrue(fade.localizedCaseInsensitiveContains(
                "ten seconds down on the last one."
            ))
            for event in [
                CueEvent.tooFast, .fastStart, .tooSlow(deltaS: 8),
                .halfway, .lastKm(hard: false),
            ] {
                let cue = book.text(for: event, context: context, now: now)
                XCTAssertFalse(banned.contains {
                    cue.localizedCaseInsensitiveContains($0)
                }, cue)
            }
        }
    }

    func testRunModeUploadsAndOlderRunsDecodeWithoutIt() throws {
        var run = makeRun(daysAgo: 1, metres: 5000, splits: [300, 300, 300, 300, 300])
        run.mode = "free"
        XCTAssertEqual(run.uploadBody["mode"] as? String, "free")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any]
        )
        legacy.removeValue(forKey: "mode")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(Run.self, from: legacyData).mode)
    }

    func testContextComparable() {
        let old = makeRun(daysAgo: 40, metres: 5000, splits: [300, 300, 300, 300, 300])
        let wrongSize = makeRun(daysAgo: 2, metres: 21000,
                                splits: [], efforts: [:])
        let older5k = makeRun(daysAgo: 9, metres: 5100,
                              splits: [300, 300, 300, 300, 300])
        let recent5k = makeRun(daysAgo: 3, metres: 5200,
                               splits: [280, 290, 300, 310, 320])
        let context = RunContext.make(
            mode: .plan(kind: "easy", km: 5, paceSPerKm: 360),
            history: [old, wrongSize, older5k, recent5k],
            targets: [:], serverBest: [:], now: now
        )
        XCTAssertEqual(context.comparable?.startedAt, recent5k.startedAt)
        XCTAssertEqual(context.comparable?.splitSeconds, [280, 290, 300, 310, 320])
        // Free run ignores distance window: most recent ≥ 2 km still applies
        // but here the 21 km run qualifies under the free rule.
        let free = RunContext.make(
            mode: .free, history: [recent5k, wrongSize],
            targets: [:], serverBest: [:], now: now
        )
        XCTAssertEqual(free.comparable?.startedAt, wrongSize.startedAt)
    }

    // MARK: Varied split composer

    /// Collects the composed text + variant indices for kms 1...n of a run.
    private func composedSplits(
        plannedKm: Double, kms: Int, splits: [Double]? = nil,
        targets: [String: Int] = [:], history: [Run] = [],
        mode: CoachMode? = nil, seed: UInt64 = 7
    ) -> [(text: String, indices: [Int])] {
        let context = RunContext.make(
            mode: mode ?? .plan(kind: "tempo", km: plannedKm, paceSPerKm: 300),
            history: history, targets: targets, serverBest: [:], now: now
        )
        var phrases = PhraseBook(seed: seed)
        let secs = splits ?? Array(repeating: 336.0, count: kms)
        return (1...kms).map { km in
            let totalS = secs.prefix(km).reduce(0, +)
            let text = phrases.text(
                for: .split(km: km, seconds: secs[km - 1], totalS: totalS,
                            comment: true,
                            progress: nil),
                context: context, now: now
            )
            return (text, phrases.lastSplitIndices)
        }
    }

    func testSplitComposer10K() {
        let cues = composedSplits(plannedKm: 10, kms: 10)
        // Pool lines never repeat within a run until the bag is exhausted.
        let poolLines = Set(CoachLines.defaults.settle
            + CoachLines.defaults.encourage
            + CoachLines.defaults.steady
            + CoachLines.defaults.finish)
        let used = cues.map(\.text)
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }
            .filter { poolLines.contains($0) }
        XCTAssertFalse(used.isEmpty)
        for (i, cue) in cues.enumerated() {
            // Every cue says the split.
            XCTAssertTrue(
                cue.text.contains("thirty-six")
                    || cue.text.contains("thirty six"),
                "km \(i + 1): \(cue.text)")
            if i > 0 {
                XCTAssertNotEqual(cue.indices, cues[i - 1].indices,
                                  "km \(i) repeats structure: \(cue.text)")
            }
        }
        // Total time only on km 2, halfway (5) and final (10).
        for (i, cue) in cues.enumerated() {
            XCTAssertEqual(cue.indices[1] != -1, [2, 5, 10].contains(i + 1),
                           "km \(i + 1): \(cue.text)")
        }
        XCTAssertTrue(cues[8].text.contains("One to go"),
                      "km 9: \(cues[8].text)")
    }

    func testSplitComposer5K() {
        let cues = composedSplits(plannedKm: 5, kms: 5)
        XCTAssertFalse(cues[0].text.contains("PB"))
        XCTAssertEqual(cues[0].indices[1], -1)
        for (i, cue) in cues.enumerated() {
            XCTAssertEqual(cue.indices[1] != -1, [2, 5].contains(i + 1),
                           "km \(i + 1): \(cue.text)")
        }
    }

    func testSplitComposerEvery3rdUnplanned() {
        var context = RunContext(mode: .free, style: .none)
        context.plannedM = nil
        var phrases = PhraseBook(seed: 11)
        var totals: [Int] = []
        for km in 1...9 {
            _ = phrases.text(
                for: .split(km: km, seconds: 300, totalS: 300 * Double(km),
                            comment: true,
                            progress: nil),
                context: context, now: now
            )
            if phrases.lastSplitIndices[1] != -1 { totals.append(km) }
        }
        XCTAssertEqual(totals, [2, 3, 6, 9])
    }

    func testSplitComposerKm1NoPB() {
        // km 1 stays short even with PB progress available.
        var phrases = PhraseBook(seed: 3)
        var context = RunContext(mode: .free, style: .none)
        context.progressPB = PBReference(
            isTarget: false, totalS: 1500, metres: 5000, cumulative: [])
        let text = phrases.text(
            for: .split(km: 1, seconds: 290, totalS: 290, comment: true,
                        progress: .aheadOfPB(deltaS: 10, targetToChase: false)),
            context: context, now: now
        )
        XCTAssertFalse(text.contains("PB"), "km1 text: \(text)")
        XCTAssertFalse(text.contains("on the clock"))
        XCTAssertFalse(text.contains("done in"))
    }

    func testShortSplit() {
        XCTAssertEqual(SpokenNumbers.shortSplit(336), "five thirty-six")
        XCTAssertEqual(SpokenNumbers.shortSplit(304), "five oh four")
        XCTAssertEqual(SpokenNumbers.shortSplit(300), "five minutes flat")
        XCTAssertEqual(SpokenNumbers.shortSplit(61), "one oh one")
    }

    func testCoachLinesValidator() {
        XCTAssertFalse(CoachLines.isValidLine("Hold five K"))
        XCTAssertFalse(CoachLines.isValidLine("3 more"))
        XCTAssertFalse(CoachLines.isValidLine("half way there"))
        XCTAssertFalse(CoachLines.isValidLine("Keep going for a minute"))
        XCTAssertFalse(CoachLines.isValidLine(""))
        XCTAssertTrue(CoachLines.isValidLine("Stay tall and relaxed."))
    }

    func testVoiceChoiceMapping() {
        let defaults = UserDefaults.standard
        for (raw, expected) in [
            ("emily", CoachVoiceChoice.sophie),
            ("paul", .sophie),
            ("sophie", .sophie),
            ("steven", .steven),
            ("system", .system),
        ] as [(String, CoachVoiceChoice)] {
            defaults.set(raw, forKey: "jogga.coachVoice")
            XCTAssertEqual(CoachVoiceChoice.current, expected, raw)
        }
        defaults.removeObject(forKey: "jogga.coachVoice")
        // With the models bundled the default is the Neuphonic voice and
        // make() never returns the system voice.
        if NeuTTSVoice.modelsBundled {
            XCTAssertEqual(CoachVoiceChoice.current, .sophie)
            XCTAssertTrue(CoachVoiceChoice.make() is NeuTTSVoice)
            defaults.set("sophie", forKey: "jogga.coachVoice")
            let v = CoachVoiceChoice.make()
            XCTAssertTrue(v is NeuTTSVoice)
            XCTAssertFalse(v is SystemVoice)
            defaults.removeObject(forKey: "jogga.coachVoice")
        }
    }
}
