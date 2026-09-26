import Testing
@testable import ZMeetCore

/// Every combination of the three inputs. Recording outranks everything; a live
/// meeting you're not recording outranks background processing.
@Test func statusIconTruthTable() {
    typealias Row = (recording: Bool, detected: Bool, processing: Bool, expected: StatusIconState)
    let rows: [Row] = [
        (false, false, false, .idle),
        (false, false, true,  .processing),
        (false, true,  false, .meetingDetected),
        (false, true,  true,  .meetingDetected),   // detected outranks processing
        (true,  false, false, .recording),
        (true,  false, true,  .recording),
        (true,  true,  false, .recording),
        (true,  true,  true,  .recording),         // recording outranks everything
    ]
    for row in rows {
        let resolved = StatusIconState.resolve(
            isRecording: row.recording, meetingDetected: row.detected, isProcessing: row.processing)
        #expect(resolved == row.expected,
                "recording=\(row.recording) detected=\(row.detected) processing=\(row.processing)")
    }
}
