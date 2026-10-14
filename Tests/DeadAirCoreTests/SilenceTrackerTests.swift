import XCTest
@testable import DeadAirCore

final class SilenceTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func feed(_ tracker: inout SilenceTracker, peak: Float?, from: TimeInterval, to: TimeInterval) {
        for tick in Int((from * 10).rounded())...Int((to * 10).rounded()) {
            tracker.record(peak: peak, at: at(Double(tick) / 10))
        }
    }

    func testLiveSignalStaysLive() {
        var tracker = SilenceTracker(startedAt: t0, silenceFloor: 0)
        feed(&tracker, peak: 0.001, from: 0.1, to: 10)
        XCTAssertEqual(tracker.health(at: at(10)), .live)
    }

    func testDigitalSilenceGoesDeadAfterGrace() {
        var tracker = SilenceTracker(startedAt: t0, silenceFloor: 0, deadAfter: 1.5)
        feed(&tracker, peak: 0.01, from: 0.1, to: 2)
        feed(&tracker, peak: 0, from: 2.1, to: 3.5)
        XCTAssertEqual(tracker.health(at: at(3.5)), .live, "still inside grace period")
        feed(&tracker, peak: 0, from: 3.6, to: 4)
        XCTAssertEqual(tracker.health(at: at(4)), .dead(reason: .silence, since: at(2.1)))
    }

    func testRecoveryClearsSilence() {
        var tracker = SilenceTracker(startedAt: t0, silenceFloor: 0)
        feed(&tracker, peak: 0, from: 0.1, to: 5)
        XCTAssertTrue(tracker.health(at: at(5)).isDead)
        tracker.record(peak: 0.2, at: at(5.1))
        XCTAssertEqual(tracker.health(at: at(5.1)), .live)
    }

    func testThresholdTreatsQuietNoiseAsSilence() {
        let floor = Level.linear(fromDB: -100)
        var tracker = SilenceTracker(startedAt: t0, silenceFloor: floor)
        feed(&tracker, peak: Level.linear(fromDB: -120), from: 0.1, to: 3)
        XCTAssertTrue(tracker.health(at: at(3)).isDead)

        var live = SilenceTracker(startedAt: t0, silenceFloor: floor)
        feed(&live, peak: Level.linear(fromDB: -75), from: 0.1, to: 3)
        XCTAssertEqual(live.health(at: at(3)), .live)
    }

    func testNoBuffersMeansStalled() {
        var tracker = SilenceTracker(startedAt: t0, silenceFloor: 0, stallAfter: 2)
        feed(&tracker, peak: 0.1, from: 0.1, to: 1)
        feed(&tracker, peak: nil, from: 1.1, to: 3.5)
        XCTAssertEqual(tracker.health(at: at(3.5)), .dead(reason: .noData, since: at(1)))
    }

    func testNeverStartedIsStalled() {
        let tracker = SilenceTracker(startedAt: t0, silenceFloor: 0, stallAfter: 2)
        XCTAssertEqual(tracker.health(at: at(1)), .live)
        XCTAssertEqual(tracker.health(at: at(2)), .dead(reason: .noData, since: t0))
    }

    func testDisconnectIsImmediateAndResetRecovers() {
        var tracker = SilenceTracker(startedAt: t0, silenceFloor: 0)
        feed(&tracker, peak: 0.1, from: 0.1, to: 1)
        tracker.markDisconnected(at: at(1.2))
        tracker.markDisconnected(at: at(2))
        XCTAssertEqual(tracker.health(at: at(1.2)), .dead(reason: .disconnected, since: at(1.2)))
        tracker.reset(at: at(5))
        tracker.record(peak: 0.1, at: at(5.1))
        XCTAssertEqual(tracker.health(at: at(5.1)), .live)
    }

    func testFormatting() {
        XCTAssertEqual(formatDuration(12.9), "0:12")
        XCTAssertEqual(formatDuration(65), "1:05")
        XCTAssertEqual(formatDuration(3723), "1:02:03")
        XCTAssertEqual(Level.linear(fromDB: Level.exactSilenceDB), 0)
        XCTAssertEqual(Level.decibels(fromLinear: 0.1), -20, accuracy: 0.001)
    }
}
