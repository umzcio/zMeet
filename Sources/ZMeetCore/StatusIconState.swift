/// Which state the menu-bar icon shows. The priority rule lives in Core so it's
/// tested — and so the status item can resolve it from freshly emitted values
/// instead of reading AppState mid-update (see StatusItemController).
public enum StatusIconState: Equatable, Sendable {
    case idle, meetingDetected, recording, processing

    /// recording > meetingDetected > processing > idle. A live meeting you're not
    /// recording is actionable and time-sensitive, so it outranks background
    /// processing.
    public static func resolve(isRecording: Bool, meetingDetected: Bool, isProcessing: Bool) -> StatusIconState {
        if isRecording { return .recording }
        if meetingDetected { return .meetingDetected }
        if isProcessing { return .processing }
        return .idle
    }
}
