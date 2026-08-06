import Foundation

/// Render-side admission control for buffer hand-off to a writer queue: a
/// stalled disk must never block the real-time audio thread, so past the cap
/// the INCOMING buffer is dropped (newest-drop — a serial queue can't drop
/// oldest) and counted. Pure value type; the recorder wraps it in a lock.
public struct MixWriteBackpressure: Sendable, Equatable {
    public let capacity: Int
    public private(set) var pending = 0
    public private(set) var dropped = 0
    public init(capacity: Int) { self.capacity = capacity }
    /// Render side: admit one write. False = at capacity; the drop is counted.
    public mutating func admit() -> Bool {
        if pending >= capacity { dropped += 1; return false }
        pending += 1
        return true
    }
    /// Writer side: the admitted write finished (successfully or not).
    public mutating func release() { pending = max(0, pending - 1) }
    /// Render side: an admitted buffer was lost before enqueue (copy failure).
    public mutating func releaseDropping() { release(); dropped += 1 }
    public mutating func reset() { pending = 0; dropped = 0 }
}
