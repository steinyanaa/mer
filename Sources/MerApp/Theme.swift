import SwiftUI
import AppKit

/// 海 — airy sea palette: milky white-blue base, sky / seafoam / deep-water haze, one aqua accent.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    // accent: shallow-sea aqua
    static let accentNS = dynamic(light: 0x3CB9CC, dark: 0x7EDCE6)
    static let accentDeepNS = dynamic(light: 0x14829A, dark: 0x9BE7EE)   // for small text on light backgrounds
    static let accent = Color(nsColor: accentNS)
    static let accentDeep = Color(nsColor: accentDeepNS)

    // sea haze: sky, seafoam, pale sand, deep water
    static let sky = Color(nsColor: dynamic(light: 0xBFE3F5, dark: 0x2F5E86))
    static let mint = Color(nsColor: dynamic(light: 0xC6EFE6, dark: 0x1F6B66))
    static let sand = Color(nsColor: dynamic(light: 0xF6EBDD, dark: 0x5A4F45))
    static let deep = Color(nsColor: dynamic(light: 0xBBD3F0, dark: 0x2A3F7A))
    static let base = Color(nsColor: dynamic(light: 0xF4F9FB, dark: 0x0E151C))

    // wheel glass tints
    static let discTintNS = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.22, darkAlpha: 0.04)
    static let coreTintNS = dynamic(light: 0x3CB9CC, dark: 0x7EDCE6, lightAlpha: 0.22, darkAlpha: 0.18)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
