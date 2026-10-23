import XCTest
@testable import Jogga

final class ProgressChartTests: XCTestCase {
    func testProgressRangeStarts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earliest = now.addingTimeInterval(-500 * 86_400)

        XCTAssertEqual(ProgressRange.week.start(now: now, earliest: earliest), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(ProgressRange.month.start(now: now, earliest: earliest), now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(ProgressRange.year.start(now: now, earliest: earliest), now.addingTimeInterval(-365 * 86_400))
        XCTAssertEqual(ProgressRange.all.start(now: now, earliest: earliest), earliest)
    }

    func testTimeAxisUsesNiceTicksAndPadding() {
        let axis = ProgressChartMath.timeAxis(values: [1500, 1560])
        let step = axis.ticks[1] - axis.ticks[0]

        XCTAssertTrue([15.0, 30.0].contains(step))
        XCTAssertEqual(axis.domain.lowerBound, 1490, accuracy: 0.001)
        XCTAssertEqual(axis.domain.upperBound, 1570, accuracy: 0.001)
        XCTAssertTrue((2...5).contains(axis.ticks.count))
        XCTAssertTrue(axis.ticks.allSatisfy { abs($0.truncatingRemainder(dividingBy: step)) < 0.001 })
        XCTAssertTrue(axis.ticks.allSatisfy {
            $0 >= axis.domain.lowerBound && $0 <= axis.domain.upperBound
        })
    }

    func testTimeAxisForThirteenMinuteSpan() {
        let axis = ProgressChartMath.timeAxis(values: [25 * 60, 38 * 60])
        XCTAssertEqual(axis.ticks[1] - axis.ticks[0], 300)
        XCTAssertTrue(axis.ticks.contains(25 * 60))
        XCTAssertTrue(axis.ticks.contains(30 * 60))
        XCTAssertTrue(axis.ticks.contains(35 * 60))
        XCTAssertFalse(axis.ticks.contains(40 * 60))
        XCTAssertEqual(axis.domain.lowerBound, 25 * 60 - 46.8, accuracy: 0.001)
        XCTAssertEqual(axis.domain.upperBound, 38 * 60 + 46.8, accuracy: 0.001)
    }

    func testTimeAxisForSingleValue() {
        let axis = ProgressChartMath.timeAxis(values: [1500])
        XCTAssertLessThanOrEqual(axis.domain.lowerBound, 1490)
        XCTAssertGreaterThanOrEqual(axis.domain.upperBound, 1510)
        XCTAssertLessThanOrEqual(axis.ticks.count, 5)
    }

    func testTrendFitsCollinearPoints() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [
            (date: start, seconds: 1000.0),
            (date: start.addingTimeInterval(86_400), seconds: 1100.0),
            (date: start.addingTimeInterval(2 * 86_400), seconds: 1200.0),
            (date: start.addingTimeInterval(3 * 86_400), seconds: 1300.0),
        ]

        let result = ProgressChartMath.trend(points)
        guard let result else {
            XCTFail("Expected a trend for collinear points")
            return
        }
        XCTAssertEqual(result.slopePerDay, 100, accuracy: 0.0001)
        XCTAssertEqual(result.intercept, 1000, accuracy: 0.0001)
    }

    func testTrendRequiresAtLeastThreePoints() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(ProgressChartMath.trend([
            (date: start, seconds: 1000),
            (date: start.addingTimeInterval(86_400), seconds: 1100),
        ]))
    }

    func testTrendRequiresDistinctDates() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(ProgressChartMath.trend([
            (date: date, seconds: 1000),
            (date: date, seconds: 1100),
            (date: date, seconds: 1200),
        ]))
    }

    func testBestSoFarUsesAllEffortsChronologically() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let points = [
            (date: start.addingTimeInterval(3 * 86_400), seconds: 1100.0),
            (date: start, seconds: 1200.0),
            (date: start.addingTimeInterval(2 * 86_400), seconds: 1250.0),
            (date: start.addingTimeInterval(86_400), seconds: 1150.0),
        ]

        let result = ProgressChartMath.bestSoFar(points)
        XCTAssertEqual(result.map(\.seconds), [1200, 1150, 1100])
        XCTAssertEqual(result.map(\.date), [
            start, start.addingTimeInterval(86_400), start.addingTimeInterval(3 * 86_400),
        ])
    }
}
