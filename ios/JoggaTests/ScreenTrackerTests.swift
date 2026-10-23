import XCTest
@testable import Jogga

@MainActor
final class ScreenTrackerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var outputs: [ScreenTrackerOutput] = []
    private var tracker: ScreenTracker!

    override func setUp() {
        super.setUp()
        outputs = []
        tracker = ScreenTracker(now: { [self] in now }) { [self] in outputs.append($0) }
    }

    private func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    func testEnterEmitsScreen() {
        tracker.enter(.run)
        XCTAssertEqual(outputs, [.screen(.run)])
    }

    func testEnterBClosesA() {
        tracker.enter(.run)
        advance(5)
        tracker.enter(.progress)
        XCTAssertEqual(outputs, [.screen(.run), .time(.run, seconds: 5), .screen(.progress)])
    }

    func testLeaveTopResumesUnderlying() {
        tracker.enter(.run)
        advance(5)
        let tokenB = tracker.enter(.progress)
        advance(3)
        tracker.leave(tokenB)
        XCTAssertEqual(outputs, [
            .screen(.run), .time(.run, seconds: 5), .screen(.progress),
            .time(.progress, seconds: 3), .screen(.run),
        ])
    }

    func testLeaveMiddleEmitsNothing() {
        let tokenA = tracker.enter(.run)
        advance(5)
        tracker.enter(.progress)
        outputs = []
        tracker.leave(tokenA)
        XCTAssertEqual(outputs, [])
    }

    func testTabSwitchNewAppearsFirst() {
        let tokenA = tracker.enter(.run)
        advance(5)
        tracker.enter(.progress)
        tracker.leave(tokenA)
        XCTAssertEqual(outputs, [.screen(.run), .time(.run, seconds: 5), .screen(.progress)])
    }

    func testTabSwitchOldDisappearsFirst() {
        let tokenA = tracker.enter(.run)
        advance(5)
        tracker.leave(tokenA)
        tracker.enter(.progress)
        XCTAssertEqual(outputs, [.screen(.run), .time(.run, seconds: 5), .screen(.progress)])
    }

    func testBackgroundForeground() {
        tracker.enter(.run)
        advance(5)
        tracker.appBackgrounded()
        XCTAssertEqual(outputs, [.screen(.run), .time(.run, seconds: 5)])
        outputs = []
        // enter/leave while backgrounded update the stack only.
        let tokenB = tracker.enter(.activeRun)
        tracker.leave(tokenB)
        tracker.enter(.settings)
        XCTAssertEqual(outputs, [])
        tracker.appForegrounded()
        XCTAssertEqual(outputs, [.screen(.settings)])
    }

    func testShortSegmentEmitsNoTime() {
        tracker.enter(.run)
        advance(0.4)
        tracker.enter(.progress)
        XCTAssertEqual(outputs, [.screen(.run), .screen(.progress)])
    }

    func testUnknownTokenIsNoOp() {
        tracker.enter(.run)
        outputs = []
        tracker.leave(UUID())
        XCTAssertEqual(outputs, [])
    }

    func testLeaveToEmptyStackEmitsTimeOnly() {
        let token = tracker.enter(.run)
        advance(5)
        tracker.leave(token)
        XCTAssertEqual(outputs, [.screen(.run), .time(.run, seconds: 5)])
    }
}
