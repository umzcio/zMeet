import Foundation
import Testing
@testable import ZMeetCore

@Test func detectsVaultsFromObsidianJSON() {
    let json = #"{"vaults":{"id1":{"path":"/Users/z/Personal","ts":1},"id2":{"path":"/Users/z/Work","ts":2}}}"#
    let vaults = ObsidianVaults.parse(jsonData: Data(json.utf8)) { path in path.hasSuffix("Work") || path.hasSuffix("Personal") }
    #expect(vaults.contains(where: { $0.name == "Personal" && $0.path == "/Users/z/Personal" }))
    #expect(vaults.contains(where: { $0.name == "Work" }))
}

@Test func skipsMissingVaultDirs() {
    let json = #"{"vaults":{"id1":{"path":"/gone/Old"}}}"#
    #expect(ObsidianVaults.parse(jsonData: Data(json.utf8)) { _ in false }.isEmpty)
}
