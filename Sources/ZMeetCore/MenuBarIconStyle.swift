/// How the menu-bar icon is drawn for each state — Zach's design (2026-09-26):
/// his mic-with-z-badge artwork, plain when idle, the z turned green while
/// recording, and a small green dot when a meeting is detected but not recorded.
public enum MenuBarIconStyle: Equatable, Sendable {
    /// The plain icon, following the menu bar's light/dark appearance.
    case plain
    /// Plain, plus a small green dot in the icon's empty top-right corner.
    case plainWithDot
    /// The icon with its z filled green.
    case greenZ

    public static func style(for state: StatusIconState) -> MenuBarIconStyle {
        switch state {
        case .idle: .plain
        case .meetingDetected: .plainWithDot
        case .recording: .greenZ
        // Processing runs in the background; the menu shows "Processing…" and the
        // "Notes ready" banner announces completion, so the icon stays plain.
        case .processing: .plain
        }
    }
}
