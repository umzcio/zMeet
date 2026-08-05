import Foundation

/// Tracks which meetings are processing and which are publishing to the vault.
/// Encodes the app's admission rules in one testable place:
/// - a second PROCESS of the same id is REJECTED (the caller shows nothing);
/// - a second PUBLISH of an id already publishing is DROPPED (content is on
///   disk; a later republish converges the vault);
/// - processing and publishing overlap: the publish outlives the UI's
///   processing state, so the two sets are tracked separately.
///
/// Processing itself has two lifecycles that overlap but don't coincide:
/// - `processingIDs` is the LONG admission lifecycle — held from `beginProcess`
///   until `endProcess`, spanning the background Obsidian publish, so a second
///   process(id:) for the same meeting is rejected the whole time.
/// - `visibleProcessingIDs` is the SHORT UI-visible lifecycle — held from
///   `beginProcess` until `markNotesReady`, which fires once notes are saved
///   and shown, freeing the spinner/icon early while the publish continues in
///   the background under `processingIDs` alone.
public struct ProcessingRegistry: Sendable, Equatable {
    public private(set) var processingIDs: Set<String> = []
    public private(set) var visibleProcessingIDs: Set<String> = []
    public private(set) var publishingIDs: Set<String> = []

    public init() {}

    /// Admit a process run. False = already in flight (caller must not start).
    /// On success, the id is tracked as both admitted and visibly processing.
    public mutating func beginProcess(id: String) -> Bool {
        guard processingIDs.insert(id).inserted else { return false }
        visibleProcessingIDs.insert(id)
        return true
    }

    /// Notes are saved + shown: hide the UI's processing indicator for `id`
    /// while admission (`processingIDs`) stays held until `endProcess`.
    public mutating func markNotesReady(id: String) {
        visibleProcessingIDs.remove(id)
    }

    /// The full process+publish lifecycle for `id` has finished. Removes from
    /// both sets — a no-op if `id` was never begun (or already ended).
    public mutating func endProcess(id: String) {
        processingIDs.remove(id)
        visibleProcessingIDs.remove(id)
    }

    /// Admit a publish. False = already publishing (caller drops).
    public mutating func beginPublish(id: String) -> Bool {
        publishingIDs.insert(id).inserted
    }

    public mutating func endPublish(id: String) {
        publishingIDs.remove(id)
    }

    public func isProcessing(_ id: String) -> Bool { processingIDs.contains(id) }
    public func isVisiblyProcessing(_ id: String) -> Bool { visibleProcessingIDs.contains(id) }
    public var isAnyProcessing: Bool { !processingIDs.isEmpty }
    public var isAnyVisiblyProcessing: Bool { !visibleProcessingIDs.isEmpty }
}
