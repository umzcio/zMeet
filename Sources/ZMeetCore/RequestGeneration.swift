import Foundation

/// Tags async requests so only the latest one's result is applied — an older
/// request that finishes late (e.g. against a since-corrected address) is dropped.
public struct RequestGeneration: Sendable, Equatable {
    public private(set) var current = 0

    public init() {}

    /// Starts a new request and returns its token.
    public mutating func begin() -> Int {
        current += 1
        return current
    }

    public func isCurrent(_ token: Int) -> Bool { token == current }
}
