import XCTest
@testable import HyprMac

// MainThreadStallTrackerTests pin when the hang watchdog reports: nothing
// under the threshold, one report at the threshold, then at 4x steps while
// main stays silent, and the full length once the ping comes back.

final class MainThreadStallTrackerTests: XCTestCase {

    func testFastPongReportsNothing() {
        var tracker = MainThreadStallTracker(threshold: 0.5)
        XCTAssertTrue(tracker.tick(at: 10).sendPing)
        XCTAssertNil(tracker.pong(at: 10.1))
        XCTAssertTrue(tracker.tick(at: 10.25).sendPing)
    }

    func testOnePingInFlightAtATime() {
        var tracker = MainThreadStallTracker(threshold: 0.5)
        XCTAssertTrue(tracker.tick(at: 0).sendPing)
        let next = tracker.tick(at: 0.25)
        XCTAssertFalse(next.sendPing)
        XCTAssertNil(next.blocked)
    }

    func testLongStallReportsAtThresholdThenFourTimesLonger() {
        var tracker = MainThreadStallTracker(threshold: 0.5)
        _ = tracker.tick(at: 0)
        XCTAssertNil(tracker.tick(at: 0.25).blocked)
        XCTAssertEqual(tracker.tick(at: 0.5).blocked, 0.5)
        XCTAssertNil(tracker.tick(at: 1.0).blocked)
        XCTAssertEqual(tracker.tick(at: 2.0).blocked, 2.0)
        XCTAssertNil(tracker.tick(at: 7.0).blocked)
        XCTAssertEqual(tracker.tick(at: 8.0).blocked, 8.0)
        XCTAssertEqual(tracker.pong(at: 9.0), 9.0)
    }

    func testReportScheduleResetsAfterRecovery() {
        var tracker = MainThreadStallTracker(threshold: 0.5)
        _ = tracker.tick(at: 0)
        XCTAssertEqual(tracker.tick(at: 2.0).blocked, 2.0)
        XCTAssertEqual(tracker.pong(at: 2.1), 2.1)
        _ = tracker.tick(at: 3)
        XCTAssertEqual(tracker.tick(at: 3.5).blocked, 0.5)
    }

    func testPongWithoutPingIsIgnored() {
        var tracker = MainThreadStallTracker(threshold: 0.5)
        XCTAssertNil(tracker.pong(at: 5))
    }
}
