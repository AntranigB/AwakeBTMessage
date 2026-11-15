import XCTest
@testable import AwakeCore

final class LinkWatchdogTests: XCTestCase {

    func testNoSubscribersIsNeverLive() {
        var w = LinkWatchdog(staleAfter: 90)
        w.heard(at: 1000)
        XCTAssertFalse(w.isLive(now: 1001, subscribers: 0))
    }

    func testNeverHeardIsNotLiveEvenWithSubscriber() {
        let w = LinkWatchdog(staleAfter: 90)
        XCTAssertFalse(w.isLive(now: 1000, subscribers: 1))
    }

    func testRecentTrafficIsLive() {
        var w = LinkWatchdog(staleAfter: 90)
        w.heard(at: 1000)
        XCTAssertTrue(w.isLive(now: 1000, subscribers: 1))
        XCTAssertTrue(w.isLive(now: 1090, subscribers: 1))
    }

    func testSilenceBeyondThresholdIsStale() {
        var w = LinkWatchdog(staleAfter: 90)
        w.heard(at: 1000)
        XCTAssertFalse(w.isLive(now: 1091, subscribers: 1),
                       "subscriber count is stale; the phone is gone")
    }

    func testFreshTrafficRevivesTheLink() {
        var w = LinkWatchdog(staleAfter: 90)
        w.heard(at: 1000)
        XCTAssertFalse(w.isLive(now: 2000, subscribers: 1))
        w.heard(at: 2000)
        XCTAssertTrue(w.isLive(now: 2001, subscribers: 1))
    }

    func testSilenceReportsElapsed() {
        var w = LinkWatchdog(staleAfter: 90)
        w.heard(at: 1000)
        XCTAssertEqual(w.silence(now: 1042)!, 42, accuracy: 0.001)
        XCTAssertNil(LinkWatchdog().silence(now: 10))
    }
}
