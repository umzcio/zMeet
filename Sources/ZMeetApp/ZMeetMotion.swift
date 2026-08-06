import SwiftUI

/// zMeet's motion vocabulary — the SwiftUI twin of PanelAnimator.easeOut.
/// One strong ease-out curve (0.23, 1, 0.32, 1) at four durations. Add
/// entries here; never hand-type a duration or curve at a call site.
enum ZMeetMotion {
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
    /// Press feedback (PressableStyle).
    static var press: Animation { easeOut(0.10) }
    /// Exits: dialogs, menus, crossfade-out.
    static var exit: Animation { easeOut(0.15) }
    /// Entrances: dialogs, menus, content appearing.
    static var enter: Animation { easeOut(0.18) }
    // NSPanel enter/exit (0.22 / 0.16) live in PanelAnimator with the same curve.
}
