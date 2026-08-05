import Foundation
import Testing
@testable import ZMeetCore

private func tempDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("zmeet-search-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("search.db")
}

@Test func secureDeleteIsOn() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)

    #expect(store.pragmaIntValue("secure_delete") == 1)
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

@Test func searchTitleOnlyMatchStillHighlights() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)
    // The term appears only in the title, not in notes/transcript.
    try store.index(sessionID: "x", title: "Roadmap planning", notes: "agenda", transcript: "general chatter")

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

@Test func reconcileBackfillsMissingAndDropsOrphans() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)

    // Pre-existing orphan that is no longer a current meeting.
    try store.index(sessionID: "orphan", title: "Gone", notes: "", transcript: "stale")

    let docs = [
        SearchIndexDoc(id: "m1", title: "Planning", notePath: "/notes/m1", transcriptPath: "/tx/m1"),
        SearchIndexDoc(id: "m2", title: "Review", notePath: nil, transcriptPath: nil)
    ]
    let files = ["/notes/m1": "budget notes", "/tx/m1": "we talked about hiring"]

    store.reconcile(documents: docs) { path in files[path] }

    #expect(try store.indexedIDs() == ["m1", "m2"])           // orphan dropped, both added
    #expect(store.search("hiring", limit: 10).map(\.sessionID) == ["m1"])
    #expect(store.search("review", limit: 10).map(\.sessionID) == ["m2"])  // title-only doc
}

@Test func rebuildFromFilesReproducesResults() throws {
    let url = tempDBURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try SearchStore(databaseURL: url)

    let docs = [SearchIndexDoc(id: "m1", title: "Sync", notePath: "/n", transcriptPath: "/t")]
    let files = ["/n": "summary", "/t": "roadmap discussion"]
    store.reconcile(documents: docs) { files[$0] }
    let before = store.search("roadmap", limit: 10).map(\.sessionID)

    // Simulate losing the index, then rebuild from the same files.
    try store.removeAll()
    #expect(store.search("roadmap", limit: 10).isEmpty)
    store.reconcile(documents: docs) { files[$0] }

    #expect(store.search("roadmap", limit: 10).map(\.sessionID) == before)
}
