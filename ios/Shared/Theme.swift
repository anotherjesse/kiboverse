import SwiftUI

/// Kibo brand palette, shared by the iOS and watchOS targets. The coral
/// matches the app icon's coral; ink is the dark backdrop for immersive
/// talk mode.
extension Color {
    static let kiboCoral = Color(red: 0.94, green: 0.34, blue: 0.29)
    static let kiboInk = Color(red: 0.10, green: 0.12, blue: 0.18)

    // Constellation palette (watch redesign spec): brighter/dimmer coral for
    // unseen vs historical marks, neutral grays for seen thoughts and thread
    // lines, amber for needs-attention states (never red unless destructive).
    static let kiboCoralBright = Color(red: 1.0, green: 0.478, blue: 0.431)
    static let kiboCoralDim = Color(red: 0.549, green: 0.212, blue: 0.192)
    static let kiboSeenThought = Color(red: 0.431, green: 0.431, blue: 0.447)
    static let kiboLineSubtle = Color(red: 0.204, green: 0.204, blue: 0.220)
    static let kiboAmber = Color(red: 1.0, green: 0.690, blue: 0.0)
    static let kiboWhite = Color(red: 0.973, green: 0.969, blue: 0.961)
}
