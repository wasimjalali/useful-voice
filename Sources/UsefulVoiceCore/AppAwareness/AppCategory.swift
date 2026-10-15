import Foundation

/// App categories, per-category writing styles and the optional auto-send key.
///
/// Pure data and mappings only. Nothing here reads the foreground app, a settings
/// file or the screen: the wiring layer feeds these functions and stores their results.
/// `windows/src/core/apps/appCategory.ts` mirrors this file rule for rule.
public enum AppCategory: String, CaseIterable, Codable, Sendable {
    case email
    case workChat
    case personalChat
    case coding
    case docsNotes
    case other

    /// The label Settings shows.
    public var displayName: String {
        switch self {
        case .email: return "Email"
        case .workChat: return "Work chat"
        case .personalChat: return "Personal chat"
        case .coding: return "Coding"
        case .docsNotes: return "Docs and notes"
        case .other: return "Other"
        }
    }

    /// Email, Docs and notes and Other default to Formal; both chat categories to Casual.
    /// Coding has no style (its rules ignore it); Formal is the neutral value for it.
    public var defaultStyle: FormattingStyle {
        switch self {
        case .workChat, .personalChat: return .casual
        case .email, .coding, .docsNotes, .other: return .formal
        }
    }

    /// The styles Settings may offer. Very casual is Personal chat only.
    public var allowedStyles: [FormattingStyle] {
        self == .personalChat ? [.formal, .casual, .veryCasual] : [.formal, .casual]
    }
}

public enum FormattingStyle: String, CaseIterable, Codable, Sendable {
    case formal
    case casual
    case veryCasual

    /// The style that actually applies: the requested one (or the category default when
    /// none is set), with Very casual falling back to Casual outside Personal chat.
    public static func effective(requested: FormattingStyle?, category: AppCategory) -> FormattingStyle {
        let style = requested ?? category.defaultStyle
        if style == .veryCasual && category != .personalChat { return .casual }
        return style
    }
}

public enum AppPlatform: String, CaseIterable, Codable, Sendable {
    case macOS
    case windows
}

/// The Return key plus modifiers to post after a paste. Always the Return key.
public struct SendKeyChord: Equatable, Sendable {
    public let shift: Bool
    public let command: Bool
    public let control: Bool

    public init(shift: Bool = false, command: Bool = false, control: Bool = false) {
        self.shift = shift
        self.command = command
        self.control = control
    }
}

/// Optional per-app key to send after a paste. `off` is the default.
public enum AutoSendKey: String, CaseIterable, Codable, Sendable {
    case off
    case `return`
    case shiftReturn
    case modReturn

    /// The key to send, or nil for none. "Cmd/Ctrl+Return" is Command on macOS and
    /// Control on Windows.
    public func chord(for platform: AppPlatform) -> SendKeyChord? {
        switch self {
        case .off: return nil
        case .return: return SendKeyChord()
        case .shiftReturn: return SendKeyChord(shift: true)
        case .modReturn:
            return platform == .macOS ? SendKeyChord(command: true) : SendKeyChord(control: true)
        }
    }
}

/// The user's per-app category choices, keyed by app id (bundle id or executable name).
///
/// Decodes leniently so a settings file never fails to load because of it: a null or
/// malformed value is no overrides, and an entry whose category is unknown (written by a
/// newer or older app version) is dropped. Settings that stored nothing at all decode with
/// `container.decodeAppCategoryOverrides(forKey:)`, which gives no overrides for a missing key.
public struct AppCategoryOverrides: Equatable, Sendable, Codable {
    public var byApp: [String: AppCategory]

    public init(_ byApp: [String: AppCategory] = [:]) { self.byApp = byApp }

    private struct Entry: Decodable {
        let category: AppCategory?
        init(from decoder: Decoder) throws {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            category = raw.flatMap { AppCategory(rawValue: $0) }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try? container.decode([String: Entry].self)
        var result: [String: AppCategory] = [:]
        for (key, entry) in entries ?? [:] {
            if let category = entry.category { result[key] = category }
        }
        byApp = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(byApp)
    }
}

extension KeyedDecodingContainer {
    /// The stored overrides, or none when the key is missing (a settings file from before
    /// overrides existed) or holds something unreadable.
    public func decodeAppCategoryOverrides(forKey key: Key) -> AppCategoryOverrides {
        (try? decodeIfPresent(AppCategoryOverrides.self, forKey: key)) ?? AppCategoryOverrides()
    }
}
