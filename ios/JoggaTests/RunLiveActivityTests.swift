import XCTest
@testable import Jogga

final class RunLiveActivityTests: XCTestCase {
    func testShouldUpdateThrottle() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(RunLiveActivity.shouldUpdate(lastSent: nil, now: now, force: false))
        XCTAssertFalse(RunLiveActivity.shouldUpdate(
            lastSent: now.addingTimeInterval(-2), now: now, force: false
        ))
        XCTAssertTrue(RunLiveActivity.shouldUpdate(
            lastSent: now.addingTimeInterval(-6), now: now, force: false
        ))
        XCTAssertTrue(RunLiveActivity.shouldUpdate(
            lastSent: now, now: now, force: true
        ))
    }

    func testContentStateFormatting() {
        let state = RunActivityAttributes.ContentState(
            timerStart: .now,
            pausedElapsed: 3661,
            distanceM: 5020,
            paceSPerKm: 324,
            splitKm: 2,
            splitPaceSPerKm: 324
        )
        XCTAssertEqual(state.distanceText, "5.02")
        XCTAssertEqual(state.paceText, "5:24")
        XCTAssertEqual(state.splitPaceText, "5:24")
        XCTAssertEqual(state.pausedText, "1:01:01")
    }

    func testUnknownPaceFormatting() {
        let state = RunActivityAttributes.ContentState(
            timerStart: .now,
            pausedElapsed: nil,
            distanceM: 0,
            paceSPerKm: 0,
            splitKm: 1,
            splitPaceSPerKm: 0
        )
        XCTAssertEqual(state.paceText, "–:––")
        XCTAssertEqual(state.splitPaceText, "–:––")
    }

    func testSplitPaceUsesCurrentSplitAfter50Meters() {
        let lastSplit = Run.Split(distanceM: 1000, movingS: 360, gainM: 0, lossM: 0)
        XCTAssertEqual(
            RunLiveActivity.splitPace(
                currentDistance: 500, currentTime: 150, lastSplit: lastSplit
            ),
            300,
            accuracy: 0.001
        )
    }

    func testSplitPaceFallsBackToLastCompletedSplitBelow50Meters() {
        let lastSplit = Run.Split(distanceM: 1000, movingS: 330, gainM: 0, lossM: 0)
        XCTAssertEqual(
            RunLiveActivity.splitPace(
                currentDistance: 49, currentTime: 20, lastSplit: lastSplit
            ),
            330,
            accuracy: 0.001
        )
    }

    func testSplitPaceIsUnknownWithoutCurrentOrCompletedSplit() {
        XCTAssertEqual(
            RunLiveActivity.splitPace(
                currentDistance: 49, currentTime: 20, lastSplit: nil
            ),
            0
        )
    }
}
