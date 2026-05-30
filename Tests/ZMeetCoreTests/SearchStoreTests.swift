import Foundation
import Testing
@testable import ZMeetCore

private func tempDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("zmeet-search-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("search.db")
}

@Test func searchStoreOpensAndStartsEmpty() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try SearchStore(databaseURL: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try store.indexedIDs().isEmpty)
}

@Test func indexAddsRowsTrackedByID() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)

    try store.index(sessionID: "a", title: "Weekly Sync", notes: "roadmap", transcript: "we shipped detection")
    try store.index(sessionID: "b", title: "1:1 with Sam", notes: "feedback", transcript: "pilot users")

    #expect(try store.indexedIDs() == ["a", "b"])

    // Re-indexing the same id replaces, not duplicates.
    try store.index(sessionID: "a", title: "Weekly Sync v2", notes: "x", transcript: "y")
    #expect(try store.indexedIDs() == ["a", "b"])

    try store.removeAll()
    #expect(try store.indexedIDs().isEmpty)
}
