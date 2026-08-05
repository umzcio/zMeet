import Foundation
import Testing
@testable import ZMeetCore

@Test func beginProcessAdmitsTwoDifferentIDs() {
    var registry = ProcessingRegistry()
    let admittedA = registry.beginProcess(id: "a")
    let admittedB = registry.beginProcess(id: "b")
    #expect(admittedA)
    #expect(admittedB)
    #expect(registry.isProcessing("a"))
    #expect(registry.isProcessing("b"))
}

@Test func beginProcessRejectsSameIDTwice() {
    var registry = ProcessingRegistry()
    let first = registry.beginProcess(id: "a")
    let second = registry.beginProcess(id: "a")
    #expect(first)
    #expect(!second)
}

@Test func endProcessReadmitsTheID() {
    var registry = ProcessingRegistry()
    _ = registry.beginProcess(id: "a")
    registry.endProcess(id: "a")
    #expect(!registry.isProcessing("a"))
    let readmitted = registry.beginProcess(id: "a")
    #expect(readmitted)
}

@Test func endProcessOfNeverBegunIDIsNoOp() {
    var registry = ProcessingRegistry()
    registry.endProcess(id: "ghost")
    #expect(!registry.isProcessing("ghost"))
    #expect(!registry.isAnyProcessing)
}

@Test func beginPublishAdmittedWhileProcessing() {
    var registry = ProcessingRegistry()
    _ = registry.beginProcess(id: "a")
    let publishAdmitted = registry.beginPublish(id: "a")
    #expect(publishAdmitted)
    #expect(registry.isProcessing("a"))
}

@Test func secondPublishOfSameIDIsDropped() {
    var registry = ProcessingRegistry()
    let first = registry.beginPublish(id: "a")
    let second = registry.beginPublish(id: "a")
    #expect(first)
    #expect(!second)
}

@Test func endPublishReadmitsTheID() {
    var registry = ProcessingRegistry()
    _ = registry.beginPublish(id: "a")
    registry.endPublish(id: "a")
    let readmitted = registry.beginPublish(id: "a")
    #expect(readmitted)
}

@Test func endPublishOfNeverBegunIDIsNoOp() {
    var registry = ProcessingRegistry()
    registry.endPublish(id: "ghost")
    let admitted = registry.beginPublish(id: "ghost")
    #expect(admitted)
}

// MARK: - Visible/admission split (the notes-ready early release)

@Test func beginProcessMarksVisibleAndAdmitted() {
    var registry = ProcessingRegistry()
    _ = registry.beginProcess(id: "a")
    #expect(registry.isProcessing("a"))
    #expect(registry.isVisiblyProcessing("a"))
    #expect(registry.isAnyVisiblyProcessing)
}

@Test func markNotesReadyHidesSpinnerButKeepsAdmissionHeld() {
    var registry = ProcessingRegistry()
    _ = registry.beginProcess(id: "a")
    registry.markNotesReady(id: "a")
    #expect(!registry.isVisiblyProcessing("a"))
    #expect(!registry.isAnyVisiblyProcessing)
    // Admission is still held — a second process(id:) for "a" must still be
    // rejected while the background publish continues.
    #expect(registry.isProcessing("a"))
    let secondProcess = registry.beginProcess(id: "a")
    #expect(!secondProcess)
}

@Test func endProcessAfterNotesReadyClearsAdmission() {
    var registry = ProcessingRegistry()
    _ = registry.beginProcess(id: "a")
    registry.markNotesReady(id: "a")
    registry.endProcess(id: "a")
    #expect(!registry.isProcessing("a"))
    #expect(!registry.isVisiblyProcessing("a"))
    let readmitted = registry.beginProcess(id: "a")
    #expect(readmitted)
}

@Test func twoConcurrentProcessesEachTrackVisibilityIndependently() {
    var registry = ProcessingRegistry()
    _ = registry.beginProcess(id: "a")
    _ = registry.beginProcess(id: "b")
    registry.markNotesReady(id: "a")
    // "a"'s spinner clears, "b" is still visibly processing.
    #expect(!registry.isVisiblyProcessing("a"))
    #expect(registry.isVisiblyProcessing("b"))
    #expect(registry.isAnyVisiblyProcessing)
    // Both remain admitted until their own endProcess.
    #expect(registry.isProcessing("a"))
    #expect(registry.isProcessing("b"))
}
