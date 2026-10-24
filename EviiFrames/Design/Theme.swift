import SwiftUI

struct EviiTheme: Equatable {
    var isDark: Bool

    var bg: Color { isDark ? Color(hex: 0x0B0B0C) : Color(hex: 0xF3F3F5) }
    var card: Color { isDark ? Color(hex: 0x17181A) : .white }
    var cardRaised: Color { isDark ? Color(hex: 0x232428) : Color(hex: 0xE7E7EB) }
    var text: Color { isDark ? .white : Color(hex: 0x121214) }
    var secondary: Color { isDark ? Color(hex: 0x8E8F94) : Color(hex: 0x6A6B70) }
    var tertiary: Color { isDark ? Color(hex: 0x5E5F64) : Color(hex: 0x8C8D92) }
    var hairline: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06) }
    var lime: Color { Color(hex: 0xC8F06A) }
    var ink: Color { Color(hex: 0x142000) }
    var track: Color { isDark ? Color(hex: 0x2A2B2E) : Color(hex: 0xDCDCE0) }

    static let lime = Color(hex: 0xC8F06A)
}

private struct EviiThemeKey: EnvironmentKey {
    static let defaultValue = EviiTheme(isDark: true)
}

extension EnvironmentValues {
    var evii: EviiTheme {
        get { self[EviiThemeKey.self] }
        set { self[EviiThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
