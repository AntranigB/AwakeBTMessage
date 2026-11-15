import Foundation

/// Deduplication + store-and-forward queue.
///
/// The anchor keeps a message for a node that is out of range and hands it over
/// the moment that node subscribes. That is what turns a chat demo into a
/// messaging service: absence stops being loss.
public final class MessageStore {

    public struct Entry: Equatable {
        public let message: MeshMessage
        public let queuedAt: TimeInterval
        public var attempts: Int
    }

    private var seenOrder: [String] = []
    private var seen: Set<String> = []
    private var queues: [String: [Entry]] = [:]

    public let capacity: Int
    public let ttl: TimeInterval

    public init(capacity: Int = 1024, ttl: TimeInterval = 24 * 3600) {
        self.capacity = max(16, capacity)
        self.ttl = ttl
    }

    // MARK: Dedupe

    /// Returns true the first time a message id is seen.
    @discardableResult
    public func markSeen(_ mid: String) -> Bool {
        if seen.contains(mid) { return false }
        seen.insert(mid)
        seenOrder.append(mid)
        while seenOrder.count > capacity {
            let old = seenOrder.removeFirst()
            seen.remove(old)
        }
        return true
    }

    public func isDuplicate(_ mid: String) -> Bool { seen.contains(mid) }

    // MARK: Store and forward

    public func enqueue(_ m: MeshMessage,
                        at now: TimeInterval = Date().timeIntervalSince1970) {
        let dest = m.to
        guard dest != "*" else { return }          // broadcasts are not queued
        var q = queues[dest] ?? []
        if q.contains(where: { $0.message.mid == m.mid }) { return }
        q.append(Entry(message: m, queuedAt: now, attempts: 0))
        queues[dest] = q
    }

    /// Everything still deliverable for `node`, oldest first. Expired entries
    /// are dropped, and each returned entry counts as an attempt.
    public func pending(for node: String,
                        at now: TimeInterval = Date().timeIntervalSince1970) -> [MeshMessage] {
        guard var q = queues[node] else { return [] }
        q.removeAll { now - $0.queuedAt > ttl }
        for i in q.indices { q[i].attempts += 1 }
        queues[node] = q
        return q.map(\.message)
    }

    public func remove(_ mid: String, for node: String) {
        guard var q = queues[node] else { return }
        q.removeAll { $0.message.mid == mid }
        if q.isEmpty { queues.removeValue(forKey: node) } else { queues[node] = q }
    }

    public var pendingCount: Int { queues.values.reduce(0) { $0 + $1.count } }

    public func pendingNodes() -> [String] { Array(queues.keys).sorted() }

    /// Everything queued, oldest first, clearing the queues. Used when a node
    /// reconnects and the anchor hands over what accumulated while it was away.
    public func drainAll(at now: TimeInterval = Date().timeIntervalSince1970) -> [MeshMessage] {
        purgeExpired(at: now)
        let all = queues.values.flatMap { $0.map(\.message) }.sorted { $0.ts < $1.ts }
        queues.removeAll()
        return all
    }

    public func purgeExpired(at now: TimeInterval = Date().timeIntervalSince1970) {
        for (node, q) in queues {
            let kept = q.filter { now - $0.queuedAt <= ttl }
            if kept.isEmpty { queues.removeValue(forKey: node) } else { queues[node] = kept }
        }
    }
}
