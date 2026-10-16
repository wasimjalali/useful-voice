import Foundation

/// What the user chose for app-aware formatting: the on/off switch, a style and an
/// auto-send key per category, the name for email sign-offs and the per-app category
/// overrides.
///
/// Stored as one JSON value (see `AppSettings.appFormatting`). Every key is optional and
/// decodes leniently, so a settings store from before this existed loads as the defaults,
/// and a value written by a newer or older build never fails the whole load: an unknown
/// category, style or key is dropped, a wrong type reads as not set.
/// `windows/src/core/settings` mirrors the same keys and rules.
public struct AppFormattingSettings: Codable, Equatable, Sendable {
    /// The longest name kept. A sign-off name is a name, not a paragraph.
    public static let maxNameLength = 60

    /// "Format for the app". On by default.
    public var enabled: Bool
    /// The name an email sign-off may carry. Empty means no name is added.
    public var userName: String
    /// The styles the user picked, keyed by `AppCategory.rawValue`. A category not listed
    /// uses its default. Read through `requestedStyle(for:)`, which drops a style the
    /// category does not allow.
    public var styles: [String: FormattingStyle]
    /// Auto-send keys, keyed by `AppCategory.rawValue`. Missing means off. Read through
    /// `autoSendKey(for:)`, which is always off where it is not offered.
    public var autoSend: [String: AutoSendKey]
    /// The user's per-app category choices.
    public var overrides: AppCategoryOverrides

    public init(enabled: Bool = true,
                userName: String = "",
                styles: [String: FormattingStyle] = [:],
                autoSend: [String: AutoSendKey] = [:],
                overrides: AppCategoryOverrides = AppCategoryOverrides()) {
        self.enabled = enabled
        self.userName = userName
        self.styles = styles
        self.autoSend = autoSend
        self.overrides = overrides
    }

    /// The default for a fresh install and for a store with nothing saved.
    public static let standard = AppFormattingSettings()

    private enum CodingKeys: String, CodingKey {
        case enabled, userName, styles, autoSend, overrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        userName = Self.cleaned(name: (try? container.decodeIfPresent(String.self, forKey: .userName)) ?? "")
        styles = Self.lenientMap(container, .styles)
        autoSend = Self.lenientMap(container, .autoSend)
        overrides = container.decodeAppCategoryOverrides(forKey: .overrides)
    }

    /// A map keyed by category whose values are read one by one, so one unknown value
    /// does not drop the rest.
    private static func lenientMap<Value: RawRepresentable>(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [String: Value] where Value.RawValue == String {
        guard let raw = try? container.decodeIfPresent([String: String].self, forKey: key) else { return [:] }
        var result: [String: Value] = [:]
        for (name, value) in raw {
            if AppCategory(rawValue: name) != nil, let parsed = Value(rawValue: value) { result[name] = parsed }
        }
        return result
    }

    // MARK: - Name

    /// The name as it is used: trimmed, line breaks turned into spaces, cut to `maxNameLength`.
    public static func cleaned(name: String) -> String {
        let flat = name.unicodeScalars.map { CharacterSet.newlines.contains($0) ? " " : String($0) }.joined()
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxNameLength))
    }

    // MARK: - Style

    /// The style the user picked for a category, or nil to use its default. A stored style
    /// the category does not allow (Very casual outside Personal chat) is ignored.
    public func requestedStyle(for category: AppCategory) -> FormattingStyle? {
        guard let style = styles[category.rawValue], category.allowedStyles.contains(style) else { return nil }
        return style
    }

    /// The style that applies to a category.
    public func style(for category: AppCategory) -> FormattingStyle {
        FormattingStyle.effective(requested: requestedStyle(for: category), category: category)
    }

    public mutating func setStyle(_ style: FormattingStyle, for category: AppCategory) {
        if style == category.defaultStyle || !category.allowedStyles.contains(style) {
            styles[category.rawValue] = nil
        } else {
            styles[category.rawValue] = style
        }
    }

    // MARK: - Auto-send

    /// Auto-send is not offered for Email, or for Docs and notes: a Return there only
    /// adds a line.
    public static func offersAutoSend(_ category: AppCategory) -> Bool {
        category != .email && category != .docsNotes
    }

    /// The key to press after a dictation lands in this category. Off by default and
    /// always off where it is not offered.
    public func autoSendKey(for category: AppCategory) -> AutoSendKey {
        guard Self.offersAutoSend(category) else { return .off }
        return autoSend[category.rawValue] ?? .off
    }

    public mutating func setAutoSend(_ key: AutoSendKey, for category: AppCategory) {
        autoSend[category.rawValue] = (key == .off || !Self.offersAutoSend(category)) ? nil : key
    }

    // MARK: - Category

    /// The category of a dictation target: the user's override for the app, then the page
    /// address, then the app's seed, then Other. No app (a window dictation) is Other.
    public func category(forAppID appID: String?, url: String?) -> AppCategory {
        AppCategoryRegistry.resolve(appID: appID, url: url, overrides: overrides.byApp)
    }

    /// Sets or clears the user's category for one app. Choosing what the app would be
    /// without an override clears it, so the list stays to real choices.
    public mutating func setCategory(_ category: AppCategory, forAppID appID: String) {
        let key = AppCategoryRegistry.normalizeAppID(appID)
        guard !key.isEmpty else { return }
        overrides.byApp = overrides.byApp.filter { AppCategoryRegistry.normalizeAppID($0.key) != key }
        let seeded = AppCategoryRegistry.resolve(appID: appID, url: nil)
        if category != seeded { overrides.byApp[appID] = category }
    }

    /// Forgets every per-app category choice.
    public mutating func resetOverrides() {
        overrides = AppCategoryOverrides()
    }
}

/// The apps the person dictated into, newest first, for the Settings list of apps that can
/// be given a category. Read from History's app field.
public enum SeenApps {
    public static func ids(in records: [DictationRecord], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for record in records.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard let id = record.appID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  !AppCategoryRegistry.isBrowser(id),
                  seen.insert(AppCategoryRegistry.normalizeAppID(id)).inserted else { continue }
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }
}
