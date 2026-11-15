import XCTest
@testable import AwakeCore

final class StoreTests: XCTestCase {

    func testMarkSeenDeduplicates() {
        let s = MessageStore()
        XCTAssertTrue(s.markSeen("AAAA"))
        XCTAssertFalse(s.markSeen("AAAA"))
        XCTAssertTrue(s.isDuplicate("AAAA"))
        XCTAssertFalse(s.isDuplicate("BBBB"))
    }

    func testCapacityEvictsOldestAndAllowsReplay() {
        let s = MessageStore(capacity: 16)
        for i in 0..<16 { XCTAssertTrue(s.markSeen("M\(i)")) }
        XCTAssertFalse(s.markSeen("M0"), "still inside capacity")
        XCTAssertTrue(s.markSeen("M16"), "new id always accepted")
        XCTAssertTrue(s.markSeen("M0"), "oldest was evicted, so it can be seen again")
    }

    func testBroadcastIsNotQueued() {
        let s = MessageStore()
        s.enqueue(MeshMessage(from: "A", to: "*", body: "hi"))
        XCTAssertEqual(s.pendingCount, 0)
    }

    func testQueuedMessageIsDeliveredOnSubscribe() {
        let s = MessageStore()
        let m = MeshMessage(from: "A", to: "IPH1", body: "missed you")
        s.enqueue(m, at: 1000)
        XCTAssertEqual(s.pendingCount, 1)

        let out = s.pending(for: "IPH1", at: 1001)
        XCTAssertEqual(out, [m])
    }

    func testQueueIsPerDestination() {
        let s = MessageStore()
        s.enqueue(MeshMessage(from: "A", to: "IPH1", body: "for phone"), at: 1000)
        XCTAssertTrue(s.pending(for: "OTHR", at: 1001).isEmpty)
        XCTAssertEqual(s.pending(for: "IPH1", at: 1001).count, 1)
        XCTAssertEqual(s.pendingNodes(), ["IPH1"])
    }

    func testExpiredMessagesAreDropped() {
        let s = MessageStore(ttl: 60)
        s.enqueue(MeshMessage(from: "A", to: "IPH1", body: "stale"), at: 1000)
        XCTAssertTrue(s.pending(for: "IPH1", at: 1200).isEmpty)
    }

    func testRemoveClearsDeliveredMessage() {
        let s = MessageStore()
        let m = MeshMessage(from: "A", to: "IPH1", body: "got it")
        s.enqueue(m, at: 1000)
        s.remove(m.mid, for: "IPH1")
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertTrue(s.pending(for: "IPH1", at: 1000).isEmpty)
    }

    func testEnqueueIsIdempotent() {
        let s = MessageStore()
        let m = MeshMessage(from: "A", to: "IPH1", body: "once")
        s.enqueue(m, at: 1000)
        s.enqueue(m, at: 1000)
        XCTAssertEqual(s.pendingCount, 1)
    }

    func testAttemptsIncrementPerDeliveryAttempt() {
        let s = MessageStore()
        s.enqueue(MeshMessage(from: "A", to: "IPH1", body: "retry"), at: 1000)
        _ = s.pending(for: "IPH1", at: 1000)
        _ = s.pending(for: "IPH1", at: 1000)
        XCTAssertEqual(s.pending(for: "IPH1", at: 1000).count, 1)
    }

    func testDrainAllReturnsOldestFirstAndClears() {
        let s = MessageStore()
        let a = MeshMessage(from: "A", to: "IPH1", body: "first")
        var b = MeshMessage(from: "A", to: "IPH1", body: "second")
        b.ts = a.ts + 5
        s.enqueue(b, at: 1000)
        s.enqueue(a, at: 1000)
        let out = s.drainAll(at: 1000)
        XCTAssertEqual(out.map(\.body), ["first", "second"])
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertTrue(s.drainAll(at: 1000).isEmpty)
    }

    func testPurgeExpiredKeepsFresh() {
        let s = MessageStore(ttl: 100)
        s.enqueue(MeshMessage(from: "A", to: "IPH1", body: "old"), at: 1000)
        s.enqueue(MeshMessage(from: "A", to: "IPH2", body: "new"), at: 1090)
        s.purgeExpired(at: 1105)
        XCTAssertEqual(s.pendingNodes(), ["IPH2"])
    }
}
