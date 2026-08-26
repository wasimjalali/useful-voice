import SwiftUI

/// Role-based light palette for the Useful Voice desktop app.
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
    static let surface = Color.white
    static let surfaceSubtle = rgb(0xF8, 0xF6, 0xF0)
    static let brand = rgb(0x10, 0x2A, 0x43)
    static let brandStrong = rgb(0x07, 0x1B, 0x2D)
    static let accent = rgb(0xC4, 0x9A, 0x46)
    static let ink = rgb(0x13, 0x22, 0x38)
    static let muted = rgb(0x66, 0x70, 0x85)
    static let line = rgb(0xE5, 0xE7, 0xEB)
    static let danger = rgb(0xB4, 0x23, 0x18)
    static let success = rgb(0x2F, 0x6B, 0x4F)
    static let warning = rgb(0x9A, 0x67, 0x16)

    // Compatibility aliases while pages migrate to role names.
    static let navy = brand
    static let navy800 = brandStrong
    static let gold = accent
    static let gold300 = accent.opacity(0.55)
    static let cream = surface
    static let creamSurface = surfaceSubtle
    static let sage = success
    static let charcoal = ink
    static let white = surface
    static let focus = accent
    static let red = danger
}
