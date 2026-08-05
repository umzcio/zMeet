import SwiftUI
import AppKit

/// The app's single source of color truth. Canonical values are the Library
/// window's (the primary surface); Settings previously used slightly different
/// bg/card shades and now adopts these.
enum ZMeetPalette {
    /// Brand mint (#2EE08A).
    static let mint = Color(red: 0.180, green: 0.878, blue: 0.541)
    static let mintNS = NSColor(red: 0.180, green: 0.878, blue: 0.541, alpha: 1)

    static let light = Color(red: 0.918, green: 0.953, blue: 0.933)
    static let body = Color(red: 0.776, green: 0.839, blue: 0.804)
    static let muted = Color(red: 0.541, green: 0.608, blue: 0.573)
    static let faint = Color(red: 0.365, green: 0.420, blue: 0.388)
    static let bg = Color(red: 0.055, green: 0.071, blue: 0.067)
    static let rail = Color(red: 0.043, green: 0.059, blue: 0.055)
    static let card = Color(red: 0.090, green: 0.110, blue: 0.102)
    static let hover = Color(red: 0.106, green: 0.129, blue: 0.118)
    static let hairline = Color.white.opacity(0.06)

    /// Dialog scaffold card background (previously hard-coded in DialogComponents).
    static let dialogCard = Color(red: 0.105, green: 0.124, blue: 0.116)
}
