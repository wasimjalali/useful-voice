import AppKit
import SwiftUI
import UsefulVoiceCore

/// The pill's colors for one colorway, resolved once per show. `systemDark` is the
/// system's appearance, not the app's own theme: the pill sits over other apps.
struct HUDPalette: Equatable {
    var surface: Color
    var ink: Color
    var dim: Color
    /// The waveform.
    var mark: Color
    /// The record dot.
    var rec: Color
    /// The drawn check.
    var ok: Color
    /// The working dots.
    var dots: Color
    /// The bloom and the aura around the pill.
    var halo: Color
    var edge: Color
    var edgeWidth: CGFloat
    /// Keycap, fix pill and close fill.
    var chip: Color
    var shadow: Color
    var shadowRadius: CGFloat
    var shadowY: CGFloat
    /// A second, tight shadow that gives a white pill its edge on a white page.
    var contactShadow: Color

    static let standard = resolve(.ink, accentHex: AppSettings.defaultHUDAccentHex, systemDark: false)

    static func resolve(_ colorway: HUDColorway, accentHex: String, systemDark dark: Bool) -> HUDPalette {
        // The recording's warm coral: it shows on a white page and a dark one alike.
        let halo = hex(0xF0795C)
        var palette: HUDPalette
        switch colorway {
        case .paper:
            palette = HUDPalette(
                surface: dark ? hex(0xF2F2F2) : hex(0xFFFFFF), ink: hex(0x171717), dim: hex(0x6B6B6B),
                mark: hex(0x5C5C5C), rec: hex(0xC2412A), ok: hex(0x171717), dots: hex(0x171717), halo: halo,
                edge: Color.black.opacity(0.08), edgeWidth: 1, chip: hex(0xEFEFEF),
                shadow: Color.black.opacity(dark ? 0.5 : 0.16), shadowRadius: 11, shadowY: 8,
                contactShadow: Color.black.opacity(dark ? 0 : 0.06))
        case .ink, .signal, .accent:
            palette = HUDPalette(
                surface: dark ? hex(0x202020) : hex(0x171717), ink: hex(0xFAFAFA), dim: hex(0xFAFAFA).opacity(0.62),
                mark: hex(0xD4D4D4), rec: hex(0xF0795C), ok: hex(0xFAFAFA), dots: hex(0xFAFAFA), halo: halo,
                edge: Color.white.opacity(0.14), edgeWidth: dark ? 1 : 0.5, chip: Color.white.opacity(0.14),
                shadow: Color.black.opacity(dark ? 0.55 : 0.3), shadowRadius: 9, shadowY: 6,
                contactShadow: .clear)
        }
        switch colorway {
        case .signal:
            palette.mark = hex(0xF0795C)
            palette.ok = hex(0x4CC39B)
        case .accent:
            let accent = color(hex: accentHex) ?? hex(0xF2A93B)
            palette.mark = accent
            palette.rec = accent
            palette.ok = accent
            palette.dots = accent
            palette.halo = accent
        case .ink, .paper:
            break
        }
        return palette
    }

    /// What the settings say now, against the system's light or dark mode.
    static func current(_ settings: AppSettings) -> HUDPalette {
        resolve(settings.hudColorway, accentHex: settings.hudAccentHex, systemDark: systemIsDark)
    }

    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    static func color(hex raw: String) -> Color? {
        guard let normal = AppSettings.normalizedHex(raw), let value = UInt32(normal.dropFirst(), radix: 16) else {
            return nil
        }
        return hex(value)
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}
