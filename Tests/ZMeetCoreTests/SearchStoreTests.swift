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
