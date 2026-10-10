import AppKit
import SwiftUI

/// Role-named tokens, shared with Useful Brain (`useful-brain/src/app/globals.css`).
///
/// Every color is dynamic: it resolves against the appearance of whatever draws
/// it, so System, Light and Dark need no per-view code. Light values are the
/// original palette, unchanged. Dark values are the Useful brand dark block from
/// the redesign board (`base.css`, the `.uv` dark values). Dark is a re-decision,
/// not an inversion: gray surfaces, and bubbles one step lighter than the stage.
enum Theme {
    // MARK: Dynamic color plumbing

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    private static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// A color that resolves to `light` or `dark` by the drawing appearance.
    static func dynamicNS(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func dynamicNS(light: UInt32, dark: UInt32) -> NSColor {
        dynamicNS(light: srgb(light), dark: srgb(dark))
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    // MARK: Surfaces

    static let canvasNSColor = dynamicNS(light: 0xF8F8F8, dark: 0x0F0F0F)
    static let canvas = Color(nsColor: canvasNSColor)
    static let rail = canvas
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x171717)
    static let sunken = dynamic(light: 0xF0F0F0, dark: 0x2C2C2C)
    static let surfaceSubtle = sunken
    /// A chat bubble and any lifted card: white on the white stage in light, one
    /// step lighter than the stage in dark.
    static let bubble = dynamic(light: 0xFFFFFF, dark: 0x202020)
    /// The selected item inside a segmented control.
    static let segmentOn = dynamic(light: 0xFFFFFF, dark: 0x3A3A3A)

    // MARK: Ink

    static let ink = dynamic(light: 0x171717, dark: 0xEDEDED)
    static let inkMuted = dynamic(light: 0x5C5C5C, dark: 0xA3A3A3)
    /// Decoration only. Never carry information in it.
    static let inkFaint = dynamic(light: 0xA3A3A3, dark: 0x6E6E6E)
    static let muted = inkMuted

    // MARK: Brand and accent

    static let brand = ink
    static let brandStrong = dynamic(light: 0x0A0A0A, dark: 0xFFFFFF)
    static let brandInk = dynamic(light: 0xFAFAFA, dark: 0x141414)

    static let accent = ink
    static let accentStrong = brandStrong
    static let accentSoft = dynamic(light: 0xF0F0F0, dark: 0x262626)
    /// Fixed in both themes: it sits on always-dark surfaces.
    static let accentOnDark = rgb(0xD4, 0xD4, 0xD4)
    static let accentInk = dynamic(light: 0xFFFFFF, dark: 0x141414)

    // MARK: Lines

    static let line = dynamic(light: 0xEBEBEB, dark: 0x262626)
    static let lineStrong = dynamic(light: 0xE0E0E0, dark: 0x333333)
    /// Field borders, off switches and slider tracks: ink-muted blended 72/28 into
    /// the surface, which reaches 3:1 (WCAG 1.4.11). Never use `lineStrong` for these.
    static let controlEdge = dynamic(light: 0x8A8A8A, dark: 0x7C7C7C)
    /// The faint 1px edge on buttons, chips and lifted cards.
    static let edge = Color(nsColor: dynamicNS(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)))
    /// The 1px ring around the app mark on dark canvases (the mark itself is untouched).
    static let tone = Color(nsColor: dynamicNS(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)))
    static let scrim = Color(nsColor: dynamicNS(
        light: srgb(0x171717, alpha: 0.18),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)))

    // MARK: Status

    static let success = dynamic(light: 0x0F6F56, dark: 0x4CC39B)
    static let successSoft = dynamic(light: 0xE4F4EE, dark: 0x13302A)
    static let warning = dynamic(light: 0x8A5300, dark: 0xE3A64A)
    static let warningSoft = dynamic(light: 0xFBF1DE, dark: 0x33260F)
    static let danger = dynamic(light: 0xB23C22, dark: 0xF0795C)
    static let dangerSoft = dynamic(light: 0xFBEAE5, dark: 0x3A1B14)

    // MARK: The dictation pill and toasts (dark in both themes)

    static let hudSurface = dynamic(light: 0x171717, dark: 0x202020)
    static let hudInk = rgb(0xFA, 0xFA, 0xFA)
    /// The app mark's tile: dark in both appearances, like the app icon.
    static let markTile = rgb(0x17, 0x17, 0x17)
    static let hudMark = accentOnDark
    /// The record dot inside the HUD and any other dark surface. In-window record
    /// dots keep `danger`.
    static let hudDanger = rgb(0xF0, 0x79, 0x5C)

    // MARK: AppKit

    /// Overlay scrollbar knob. Soft gray so it sits on the stage and sunken surfaces.
    static let scrollKnobNSColor = dynamicNS(light: 0xD8D8D8, dark: 0x444444)
    static let scrollKnobActiveNSColor = dynamicNS(light: 0xB0B0B0, dark: 0x6E6E6E)

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

// MARK: - Radius

/// The only corner radii the design uses. 1 to 3 pt is allowed for bar and meter
/// geometry only.
enum Radius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
    static let xxl: CGFloat = 24
    static let pill: CGFloat = 999
}

// MARK: - Type scale

/// Seven whole-point sizes, nothing under 11.
enum TypeScale: CGFloat {
    /// Labels and key caps.
    case label = 11
    /// Meta lines and quiet captions.
    case meta = 12
    /// Controls and rows.
    case ui = 13
    /// Body text.
    case body = 14
    /// Titles.
    case title = 15
    /// Figures and the timer.
    case figure = 20
    /// Statements.
    case statement = 28
}

extension Font {
    static func uv(_ scale: TypeScale, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scale.rawValue, weight: weight)
    }
}

// MARK: - Shadows

/// Light shadows are a faint ink; dark ones are black at higher strength. SwiftUI
/// has no spread, so the board's long soft drops are approximated with a larger
/// offset and a smaller radius.
struct ThemeShadow: ViewModifier {
    struct Layer {
        let lightAlpha: CGFloat
        let darkAlpha: CGFloat
        let radius: CGFloat
        let y: CGFloat
    }

    let layers: [Layer]

    private func color(_ layer: Layer) -> Color {
        Color(nsColor: Theme.dynamicNS(
            light: NSColor(srgbRed: 23 / 255, green: 23 / 255, blue: 23 / 255, alpha: layer.lightAlpha),
            dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: layer.darkAlpha)))
    }

    func body(content: Content) -> some View {
        layers.reduce(AnyView(content)) { view, layer in
            AnyView(view.shadow(color: color(layer), radius: layer.radius, x: 0, y: layer.y))
        }
    }

    static let none = ThemeShadow(layers: [])
    static let segment = ThemeShadow(layers: [Layer(lightAlpha: 0.10, darkAlpha: 0.3, radius: 1, y: 1)])
    static let small = ThemeShadow(layers: [Layer(lightAlpha: 0.04, darkAlpha: 0.3, radius: 1, y: 1)])
    static let lift = ThemeShadow(layers: [
        Layer(lightAlpha: 0.04, darkAlpha: 0.3, radius: 0.5, y: 0.5),
        Layer(lightAlpha: 0.08, darkAlpha: 0.35, radius: 8, y: 3),
    ])
    static let card = ThemeShadow(layers: [
        Layer(lightAlpha: 0.03, darkAlpha: 0.3, radius: 0, y: 1),
        Layer(lightAlpha: 0.10, darkAlpha: 0.5, radius: 16, y: 12),
    ])
    static let raise = ThemeShadow(layers: [
        Layer(lightAlpha: 0.04, darkAlpha: 0.3, radius: 0, y: 1),
        Layer(lightAlpha: 0.12, darkAlpha: 0.55, radius: 18, y: 12),
    ])
    static let pop = ThemeShadow(layers: [
        Layer(lightAlpha: 0.18, darkAlpha: 0.6, radius: 22, y: 14),
    ])
}

extension View {
    func themeShadow(_ shadow: ThemeShadow) -> some View {
        modifier(shadow)
    }
}

// MARK: - Motion

/// Motion tokens. The brand system specifies one easing curve for everything:
/// `cubic-bezier(0.22, 1, 0.36, 1)`, 120 to 300 ms, entrances as a small rise.
enum BrandMotion {
    static func easeOut(duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Exits use the ease-in half of the curve, so a leaving element accelerates away.
    static func easeIn(duration: Double) -> Animation {
        .timingCurve(0.64, 0, 0.78, 0, duration: duration)
    }

    /// Hover and selection changes on controls. Short, so the pointer feels
    /// connected to the highlight rather than waiting for it.
    static let control = easeOut(duration: 0.15)

    /// The dock and HUD state morph: inner content cross-fades, width eases with it.
    static let morphDuration: Double = 0.2
    static let morph = easeOut(duration: morphDuration)

    /// Bubble insert and popover or page entrance: an 8 pt rise and fade.
    static let riseDuration: Double = 0.26
    static let rise = easeOut(duration: riseDuration)

    /// HUD and toast enter (rise 8 pt) and exit (sink 6 pt, ease-in).
    static let hudEnterDuration: Double = 0.22
    static let hudExitDuration: Double = 0.16
    static let hudEnter = easeOut(duration: hudEnterDuration)
    static let hudExit = easeIn(duration: hudExitDuration)

    /// The outgoing page's recession. The curve is front-loaded, so this is
    /// already mostly over by ~60 ms; it exists to clear the stage, not to be
    /// watched.
    static let pageExitDuration: Double = 0.12
    static let pageExit = easeOut(duration: pageExitDuration)

    /// The incoming page's rise. Longer than the exit on purpose: the arrival is
    /// the half the eye reads as motion, and sequencing the two avoids the
    /// double-exposed ghost a same-length cross-fade produces on dense pages.
    static let page = easeOut(duration: riseDuration)

    /// True when the person asked the system to reduce motion. For code outside a
    /// view (timers, controllers). Views read `accessibilityReduceMotion` instead.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The animation to run, or nil under Reduce Motion, where every transition
    /// becomes an instant swap.
    static func resolved(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension View {
    /// `animation(_:value:)` that is an instant swap under Reduce Motion.
    func brandAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(BrandAnimationModifier(animation: animation, value: value))
    }
}

private struct BrandAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// A small rise on the way in and a sink on the way out, as the toast and HUD do.
/// Under Reduce Motion it is a plain fade.
struct RiseTransitionModifier: ViewModifier {
    let opacity: Double
    let offset: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).offset(y: offset)
    }
}

extension AnyTransition {
    static func brandRise(enter: CGFloat = 8, exit: CGFloat = 6) -> AnyTransition {
        let reduce = BrandMotion.reduceMotion
        return .asymmetric(
            insertion: .modifier(active: RiseTransitionModifier(opacity: 0, offset: reduce ? 0 : enter),
                                 identity: RiseTransitionModifier(opacity: 1, offset: 0)),
            removal: .modifier(active: RiseTransitionModifier(opacity: 0, offset: reduce ? 0 : exit),
                               identity: RiseTransitionModifier(opacity: 1, offset: 0)))
    }
}
