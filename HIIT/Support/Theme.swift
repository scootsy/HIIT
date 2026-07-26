import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

enum Theme {
    static let accent = Color(hex: 0xFF5F44)
    static let warmup = Color(hex: 0x46A6FF)
    static let work = Color(hex: 0xFF5F44)
    static let recover = Color(hex: 0x3DDC84)
    static let steady = Color(hex: 0xFFB340)
    static let cooldown = Color(hex: 0x7A6FF0)
    static let night = Color(hex: 0x0B1020)

    static func color(for kind: PhaseKind) -> Color {
        switch kind {
        case .warmup: return warmup
        case .work: return work
        case .recover: return recover
        case .steady: return steady
        case .cooldown: return cooldown
        }
    }
}

/// "3:05" — rounds up, for countdowns.
func countdownString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "3:05" — rounds down, for elapsed clocks.
func clockString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}
