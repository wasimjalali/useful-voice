import AppKit
import UsefulVoiceCore

/// Applies System, Light or Dark to the whole app through `NSApp.appearance`.
/// Every window, popover and hosting view inherits it, and the dynamic colors in
/// `Theme` resolve against it.
@MainActor
enum Appearance {
    /// `UV_APPEARANCE=light|dark` wins over the saved setting, for offscreen renders
    /// (`UV_SNAPSHOT`) and demos. Nothing is saved.
    static var environmentOverride: AppearanceChoice? {
        switch ProcessInfo.processInfo.environment["UV_APPEARANCE"] {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    static func effective(_ choice: AppearanceChoice) -> AppearanceChoice {
        environmentOverride ?? choice
    }

    /// nil follows the system.
    static func nsAppearance(for choice: AppearanceChoice) -> NSAppearance? {
        switch effective(choice) {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func apply(_ choice: AppearanceChoice) {
        NSApp.appearance = nsAppearance(for: choice)
    }

    /// Applies the saved choice now and again whenever it changes.
    static func install(settings: AppSettings) {
        apply(settings.appearance)
        NotificationCenter.default.addObserver(
            forName: .uvAppearanceDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply(settings.appearance) }
        }
    }
}
