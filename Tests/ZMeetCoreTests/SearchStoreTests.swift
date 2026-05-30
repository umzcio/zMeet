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

@Test func searchFindsTranscriptTermAndRanksTitleHigher() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)

    try store.index(sessionID: "title", title: "Roadmap planning", notes: "", transcript: "unrelated chatter")
    try store.index(sessionID: "body", title: "Standup", notes: "", transcript: "we discussed the roadmap at length")

    let hits = store.search("roadmap", limit: 10)
    let ids = hits.map(\.sessionID)
    #expect(Set(ids) == ["title", "body"])
    // Title match outranks transcript-only match.
    #expect(ids.first == "title")
}

@Test func searchIsCaseInsensitiveMultiTermAndPrefix() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)

    try store.index(sessionID: "x", title: "Weekly Product Sync", notes: "", transcript: "shipped the meeting detector")
    try store.index(sessionID: "y", title: "Budget", notes: "", transcript: "numbers only")

    #expect(store.search("WEEKLY", limit: 10).map(\.sessionID) == ["x"])          // case
    #expect(store.search("weekly product", limit: 10).map(\.sessionID) == ["x"])  // AND
    #expect(store.search("weekly budget", limit: 10).isEmpty)                     // AND excludes
    #expect(store.search("meet", limit: 10).map(\.sessionID) == ["x"])           // prefix -> "meeting"
}

@Test func searchSnippetHighlightsMatch() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)
    try store.index(sessionID: "x", title: "Sync", notes: "", transcript: "we discussed the roadmap today")

    let hit = try #require(store.search("roadmap", limit: 1).first)
    #expect(hit.snippet.contains(SearchStore.highlightStart))
    #expect(hit.snippet.lowercased().contains("roadmap"))
}

@Test func searchEmptyOrPunctuationOnlyReturnsNothing() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)
    try store.index(sessionID: "x", title: "Sync", notes: "", transcript: "content")

    #expect(store.search("   ", limit: 10).isEmpty)
    #expect(store.search("!!!", limit: 10).isEmpty)
}

@Test func removeDropsFromResults() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)
    try store.index(sessionID: "x", title: "Roadmap", notes: "", transcript: "")
    #expect(!store.search("roadmap", limit: 10).isEmpty)
    try store.remove(sessionID: "x")
    #expect(store.search("roadmap", limit: 10).isEmpty)
}
