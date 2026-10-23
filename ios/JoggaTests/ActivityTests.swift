import CoreLocation
import XCTest
@testable import Jogga

private let london = TimeZone(identifier: "Europe/London")!

private func mkRun(startedAt: Date, km: Double = 5.0) -> Run {
    Run(
        id: UUID(),
        startedAt: startedAt,
        distanceM: km * 1000,
        movingS: km * 320,
        elapsedS: km * 320,
        gainM: 0,
        lossM: 0,
        splits: [],
        efforts: [:],
        route: []
    )
}

private func date(_ string: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    return f.date(from: string + "T00:00:00Z")!
}

final class ActivityTests: XCTestCase {
    private var cal: Calendar { Activity.calendar(timeZone: london) }

    // now = Wednesday 2026-09-30 12:00 London.
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00+01:00")!

    func testWeeksBucketingAndSundayNight() {
        // A run on Sunday 21:00 belongs to the Mon–Sun week ending that day.
        let sundayNight = ISO8601DateFormatter().date(from: "2026-09-27T21:00:00+01:00")!
        let run = mkRun(startedAt: sundayNight, km: 6)
        let weeks = Activity.weeks([run], count: 2, now: now, calendar: cal)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0].runs, 1)
        XCTAssertEqual(weeks[0].km, 6, accuracy: 0.001)
        XCTAssertEqual(weeks[1].runs, 0)
        XCTAssertEqual(weeks[0].days.count, 7)
    }

    func testFutureDaysFlagged() {
        let weeks = Activity.weeks([], count: 1, now: now, calendar: cal)
        let week = weeks[0]
        // now is Wednesday: Mon/Tue/Wed are not future, Thu–Sun are.
        XCTAssertFalse(week.days[0].isFuture) // Mon
        XCTAssertFalse(week.days[2].isFuture) // Wed (today)
        XCTAssertTrue(week.days[3].isFuture) // Thu
        XCTAssertTrue(week.days[6].isFuture) // Sun
    }

    func testStreakContinuesOverInProgressWeek() {
        // No run this week yet; runs last week and the week before -> streak 2.
        let w1 = mkRun(startedAt: date("2026-09-16"))
        let w2 = mkRun(startedAt: date("2026-09-23"))
        XCTAssertEqual(Activity.streakWeeks([w1, w2], now: now, calendar: cal), 2)
    }

    func testStreakBrokenByGap() {
        let runs = [
            mkRun(startedAt: date("2026-08-24")), // 5+ weeks back
            mkRun(startedAt: date("2026-09-23")), // last week
            mkRun(startedAt: date("2026-09-30")), // today
        ]
        XCTAssertEqual(Activity.streakWeeks(runs, now: now, calendar: cal), 2)
    }

    func testStreakZero() {
        let old = mkRun(startedAt: date("2026-09-01"))
        XCTAssertEqual(Activity.streakWeeks([old], now: now, calendar: cal), 0)
        XCTAssertEqual(Activity.streakWeeks([], now: now, calendar: cal), 0)
    }

    func testAverageWeeklyKmNewUserDivisorCapped() {
        // First run ever was last week; divisor caps at 2 weeks not 8.
        let runs = [mkRun(startedAt: date("2026-09-23"), km: 10), mkRun(startedAt: now, km: 6)]
        let avg = Activity.averageWeeklyKm(runs, weeks: 8, now: now, calendar: cal)
        XCTAssertEqual(avg, 8, accuracy: 0.001) // 16 km / 2 weeks
    }

    func testAverageWeeklyKmOlderUser() {
        var runs: [Run] = []
        // 10 km each week for the last 8 weeks.
        for offset in 0..<8 {
            var day = now.addingTimeInterval(-Double(offset) * 7 * 86400)
            day = day.addingTimeInterval(-86400) // earlier in each week
            runs.append(mkRun(startedAt: day, km: 10))
        }
        let avg = Activity.averageWeeklyKm(runs, weeks: 8, now: now, calendar: cal)
        XCTAssertEqual(avg, 10, accuracy: 0.001)
    }

    func testRunsToday() {
        let today = mkRun(startedAt: now.addingTimeInterval(-3600))
        let yesterday = mkRun(startedAt: now.addingTimeInterval(-86400))
        XCTAssertEqual(Activity.runsToday([today, yesterday], now: now, calendar: cal).count, 1)
    }
}

final class DemoSeedTests: XCTestCase {
    /// Every seeded route stays within 1300 m of its start point, and the
    /// measured distance stays within 1% of the planned distance.
    func testSeededRoutesStayNearStart() {
        let cases = DemoSeed.plan.map { ($0.metres) } + [5030]
        for (index, metres) in cases.enumerated() {
            let start = DemoSeed.starts[index % DemoSeed.starts.count]
            var rng = SplitMix64(seed: UInt64(index + 1))
            let outAndBack = rng.next() % 3 == 0
            let samples = SyntheticRun.samples(
                distance: metres, seconds: metres * 0.34, hillGain: 14,
                start: start, rng: &rng, outAndBack: outAndBack
            )
            let first = samples[0].coordinate
            for s in samples {
                XCTAssertLessThanOrEqual(
                    RunMath.haversine(first, s.coordinate), 1300,
                    "run \(index) wanders >1300 m from start"
                )
            }
            // Smoothness: consecutive steps turn <= 25°, apart from the
            // out-and-back reversal step and its neighbours (18 m offset).
            let mpd = SyntheticRun.metresPerDegree
            var bearings: [Double] = []
            for j in 1..<samples.count {
                let a = samples[j - 1].coordinate
                let b = samples[j].coordinate
                let dy = (b.latitude - a.latitude) * mpd
                let dx = (b.longitude - a.longitude) * mpd * cos(a.latitude * .pi / 180)
                bearings.append(atan2(dx, dy))
            }
            var reversalSteps = Set<Int>()
            var deltas: [(Int, Double)] = []
            for j in 1..<bearings.count {
                var d = abs(bearings[j] - bearings[j - 1])
                if d > .pi { d = 2 * .pi - d }
                deltas.append((j, d))
                if d > 1.7 { // ~100°, only the out-and-back reversal
                    reversalSteps.formUnion([j - 1, j, j + 1])
                }
            }
            for (j, d) in deltas where !reversalSteps.contains(j) {
                XCTAssertLessThanOrEqual(
                    d, 25 * .pi / 180, "run \(index) hairpin at step \(j)"
                )
            }
            XCTAssertEqual(
                RunMath.distance(samples), metres, accuracy: metres * 0.01,
                "run \(index) distance drift"
            )
        }
    }
}

final class RoutePaceTests: XCTestCase {
    private func route(
        count: Int,
        speedMps: (Int) -> Double,
        gapAt: Int? = nil,
        gapSeconds: Double = 60
    ) -> [Run.RoutePoint] {
        var t = 0.0
        var lat = 37.78
        var points: [Run.RoutePoint] = []
        for i in 0..<count {
            let speed = speedMps(i)
            t += 1.0 // 1 Hz
            lat += speed / 111_320 // metres north per second
            if let gapAt, i == gapAt { t += gapSeconds }
            points.append(Run.RoutePoint(lat: lat, lon: -122.42, t: t))
        }
        return points
    }

    func testConstantSpeedAllHalf() {
        let segs = RoutePace.segments(route(count: 600) { _ in 5 }, chunkM: 100)
        XCTAssertFalse(segs.isEmpty)
        for s in segs {
            XCTAssertEqual(s.score, 0.5, accuracy: 1e-9)
        }
    }

    func testFasterSecondHalfScoresHigher() {
        let segs = RoutePace.segments(route(count: 600) { $0 < 300 ? 4 : 7 }, chunkM: 100)
        // The chunk straddling the pace change is mid-range; compare means.
        let early = segs.prefix(segs.count / 2).map(\.score)
        let late = segs.suffix(segs.count / 2).map(\.score)
        let earlyMean = early.reduce(0, +) / Double(early.count)
        let lateMean = late.reduce(0, +) / Double(late.count)
        XCTAssertLessThan(earlyMean, lateMean)
        XCTAssertEqual(segs.first!.score, 0, accuracy: 0.01)
        XCTAssertEqual(segs.last!.score, 1, accuracy: 0.01)
    }

    func testGapBreaksLine() {
        // 1 Hz, 5 m/s, 60 s gap at sample 200.
        let segs = RoutePace.segments(route(count: 400, speedMps: { _ in 5 }, gapAt: 200), chunkM: 100)
        // Find the segment boundary: no segment should share an endpoint
        // across the gap — the break point must be a chunk end AND a start.
        var foundBreak = false
        for i in 0..<(segs.count - 1) {
            if segs[i].coordinates.last?.latitude != segs[i + 1].coordinates.first?.latitude {
                foundBreak = true
            }
        }
        XCTAssertTrue(foundBreak)
        // And shared boundaries elsewhere.
        var sharedCount = 0
        for i in 0..<(segs.count - 1) where segs[i].coordinates.last?.latitude
            == segs[i + 1].coordinates.first?.latitude {
            sharedCount += 1
        }
        XCTAssertGreaterThan(sharedCount, 1)
    }

    func testTooFewPoints() {
        XCTAssertTrue(RoutePace.segments([]).isEmpty)
        XCTAssertTrue(RoutePace.segments([Run.RoutePoint(lat: 0, lon: 0, t: 0)]).isEmpty)
    }
}

final class PacingLabelTests: XCTestCase {
    private func payload(_ pacing: String) -> CoachNote.Payload {
        CoachNote.Payload(
            feedback: "f",
            pacing: pacing,
            next: CoachNote.Payload.Next(km: 5, pace: 300, kind: "easy", detail: "d", why: "w"),
            frequency: CoachNote.Payload.Frequency(runsPerWeek: 3, note: "n")
        )
    }

    func testPacingLabels() {
        XCTAssertEqual(payload("positive").pacingLabel, "Faded")
        XCTAssertEqual(payload("negative").pacingLabel, "Finished faster")
        XCTAssertEqual(payload("even").pacingLabel, "Even pacing")
        XCTAssertEqual(payload("erratic").pacingLabel, "Uneven pacing")
        XCTAssertEqual(payload("weird").pacingLabel, "Weird pacing")
    }
}

final class CoachNoteDecodeTests: XCTestCase {
    private func decode(_ payload: String) throws -> CoachNote {
        let json = """
            {"source":"llm","model":"m","created_at":"2026-09-30T10:00:00Z","payload":\(payload)}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CoachNote.self, from: Data(json.utf8))
    }

    func testStructuredFeedbackDecodes() throws {
        let note = try decode("""
            {"feedback":"a b c","pacing":"positive",
             "next":{"km":5,"pace":480,"kind":"easy","detail":"d","why":"w"},
             "frequency":{"runs_per_week":3,"note":"n"},
             "went_well":"a","work_on":"b","result":"c"}
            """)
        XCTAssertEqual(note.payload.wentWell, "a")
        XCTAssertEqual(note.payload.workOn, "b")
        XCTAssertEqual(note.payload.result, "c")
    }

    func testLegacyFeedbackOnlyDecodes() throws {
        let note = try decode("""
            {"feedback":"a b c","pacing":"even",
             "next":{"km":5,"pace":300,"kind":"easy","detail":"d","why":"w"},
             "frequency":{"runs_per_week":3,"note":"n"}}
            """)
        XCTAssertNil(note.payload.wentWell)
        XCTAssertNil(note.payload.workOn)
        XCTAssertNil(note.payload.result)
        XCTAssertEqual(note.payload.feedback, "a b c")
    }
}
