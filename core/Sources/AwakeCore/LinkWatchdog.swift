import Foundation

/// Detects a link that *looks* connected but is actually gone.
///
/// `CBPeripheralManager` only reports a subscriber disappearing when the
/// peripheral unsubscribes cleanly. A phone that sleeps, dies, or walks away
/// simply stops talking, and `subscribers` stays at 1 forever. Without this,
/// the anchor keeps broadcasting into a dead link instead of queueing — which
/// silently defeats store-and-forward in exactly the case it exists for.
public struct LinkWatchdog {

    public private(set) var lastHeard: TimeInterval?
    public let staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 90) {
        self.staleAfter = staleAfter
    }

    public mutating func heard(at t: TimeInterval) {
        lastHeard = t
    }

    /// True only if someone is subscribed *and* has spoken recently.
    public func isLive(now: TimeInterval, subscribers: Int) -> Bool {
        guard subscribers > 0, let last = lastHeard else { return false }
        return now - last <= staleAfter
    }

    public func silence(now: TimeInterval) -> TimeInterval? {
        guard let last = lastHeard else { return nil }
        return max(0, now - last)
    }
}
