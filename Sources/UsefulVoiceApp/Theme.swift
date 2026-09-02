import AppKit
import SwiftUI

/// Role-named tokens, shared with Useful Brain (`useful-brain/src/app/globals.css`).
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    static let canvas = rgb(0xF8, 0xF8, 0xF8)
    static let rail = canvas
    static let surface = Color.white
    static let sunken = rgb(0xF0, 0xF0, 0xF0)
    static let surfaceSubtle = sunken

    static let ink = rgb(0x17, 0x17, 0x17)
    static let inkMuted = rgb(0x5C, 0x5C, 0x5C)
    static let inkFaint = rgb(0xA3, 0xA3, 0xA3)
    static let muted = inkMuted

    static let brand = ink
    static let brandStrong = rgb(0x0A, 0x0A, 0x0A)
    static let brandInk = rgb(0xFA, 0xFA, 0xFA)

    static let accent = ink
    static let accentStrong = brandStrong
    static let accentSoft = sunken
    static let accentOnDark = rgb(0xD4, 0xD4, 0xD4)
    static let accentInk = Color.white

    static let line = rgb(0xEB, 0xEB, 0xEB)
    static let lineStrong = rgb(0xE0, 0xE0, 0xE0)

    static let success = rgb(0x0F, 0x6F, 0x56)
    static let successSoft = rgb(0xE4, 0xF4, 0xEE)
    static let warning = rgb(0x8A, 0x53, 0x00)
    static let warningSoft = rgb(0xFB, 0xF1, 0xDE)
    static let danger = rgb(0xB2, 0x3C, 0x22)
    static let dangerSoft = rgb(0xFB, 0xEA, 0xE5)

    /// Dark-theme logo on the floating dictation pill.
    static let hudSurface = ink
    static let hudInk = brandInk
    static let hudMark = accentOnDark

    static let canvasNSColor = NSColor(srgbRed: 248 / 255, green: 248 / 255, blue: 248 / 255, alpha: 1)

    // Compatibility aliases while pages finish migrating to role names.
    static let navy = brand
    static let navy800 = brandStrong
    static let gold = accent
    static let gold300 = accentOnDark
    static let cream = surface
    static let creamSurface = surfaceSubtle
    static let sage = success
    static let charcoal = ink
    static let white = surface
    static let focus = accent
    static let red = danger
}
