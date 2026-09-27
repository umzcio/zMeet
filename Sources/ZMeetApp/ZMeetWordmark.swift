import AppKit
import SwiftUI

/// The zMeet wordmark: the brand "z" mark followed by "Meet". One view so the
/// Settings sidebar, Library rail, menu popover, and onboarding stay identical.
struct ZMeetWordmark: View {
    /// Height of the "z" mark; the gap to "Meet" scales with it.
    let markHeight: CGFloat
    let meetFont: Font

    var body: some View {
        HStack(spacing: markHeight * 0.2) {
            ZMark(height: markHeight)
            Text("Meet").font(meetFont)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("zMeet")
    }
}

/// The brand "z" mark (assets/brand/ZMark*.png, copied into the bundle by
/// build-app.sh). Falls back to a script "z" when the asset is missing, e.g. a
/// bare `swift run` with no app bundle.
struct ZMark: View {
    let height: CGFloat

    @MainActor private static let image = Bundle.main.image(forResource: "ZMark")

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        } else {
            Text("z")
                .font(.custom("Dancing Script", size: height * 1.1))
                .foregroundStyle(ZMeetPalette.mint)
        }
    }
}
