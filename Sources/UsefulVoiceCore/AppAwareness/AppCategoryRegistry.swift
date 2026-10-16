import Foundation

/// Which category an app or web page belongs to.
/// `windows/src/core/apps/appCategoryRegistry.ts` mirrors this file rule for rule.
///
/// Resolution order: the user's override for the app, then the web address (when the
/// delivery layer could read one), then the app's seed, then Other. Everything here is
/// pure: reading the foreground app and the browser address is the caller's job.
public enum AppCategoryRegistry {
    /// The lookup key for an app id: trimmed, lower case (A-Z only, so the Kelvin sign U+212A
    /// cannot pose as "k"), and for a Windows path only the file name
    /// (`C:\Program Files\Slack\slack.exe` becomes `slack.exe`).
    public static func normalizeAppID(_ raw: String) -> String {
        let id = Array(CategoryText.asciiLower(CategoryText.trimWS(raw)).unicodeScalars)
        var start = 0
        for (i, u) in id.enumerated() where u == "/" || u == "\\" { start = i + 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: id[start...])
        return String(out)
    }

    private static let seedMap: [String: AppCategory] = {
        var map: [String: AppCategory] = [:]
        for seed in AppCategorySeeds.appSeeds {
            for id in seed.ids { map[normalizeAppID(id)] = seed.category }
        }
        return map
    }()

    private static let browserSet: Set<String> = Set(
        (AppCategorySeeds.browserBundleIDs + AppCategorySeeds.browserExecutables).map(normalizeAppID))

    /// The seeded category for an app id (bundle id or executable name), or nil.
    public static func seededCategory(for appID: String) -> AppCategory? {
        let id = normalizeAppID(appID)
        if id.isEmpty { return nil }
        if let exact = seedMap[id] { return exact }
        for prefix in AppCategorySeeds.codingAppPrefixes where id.unicodeScalars.starts(with: prefix.unicodeScalars) {
            return .coding
        }
        return nil
    }

    /// Whether the app is a web browser, whose category comes from the page address.
    public static func isBrowser(_ appID: String) -> Bool {
        browserSet.contains(normalizeAppID(appID))
    }

    public struct ParsedWebURL: Equatable, Sendable {
        /// Lower case, no `www.`, no port, no trailing dot.
        public let host: String
        /// Lower case, starts with `/` or is empty. No query or fragment.
        public let path: String
    }

    private static func isAsciiLetter(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 97 && u.value <= 122) || (u.value >= 65 && u.value <= 90)
    }

    private static func isDigitScalar(_ u: Unicode.Scalar) -> Bool { u.value >= 48 && u.value <= 57 }

    private static func isSchemeChar(_ u: Unicode.Scalar) -> Bool {
        isAsciiLetter(u) || isDigitScalar(u) || u == "+" || u == "-" || u == "."
    }

    private static func isHostChar(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 97 && u.value <= 122) || isDigitScalar(u) || u == "-" || u == "."
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// Splits an address into host and path. Accepts `http` and `https` addresses and bare
    /// `host/path` text (a browser address bar often omits the scheme). Returns nil for
    /// anything else: other schemes, empty text, spaces in the host, a non-numeric port.
    ///
    /// Works on Unicode scalars (TypeScript works on code points) so both agree on odd input.
    /// A backslash ends the host like a slash does, as browsers read it:
    /// `https://evil.com\@mail.google.com/` is evil.com.
    public static func parseWebURL(_ raw: String) -> ParsedWebURL? {
        let text = Array(CategoryText.trimWS(raw).unicodeScalars)
        if text.isEmpty { return nil }
        var start = 0
        // A scheme counts only at the very start: letters, digits, "+", "-", "." then "://".
        if isAsciiLetter(text[0]) {
            var i = 0
            while i < text.count && isSchemeChar(text[i]) { i += 1 }
            if i + 2 < text.count, text[i] == ":", text[i + 1] == "/", text[i + 2] == "/" {
                let scheme = CategoryText.asciiLower(string(text[0..<i]))
                guard scheme == "http" || scheme == "https" else { return nil }
                start = i + 3
            }
        }
        let rest = Array(text[start...])
        var end = rest.count
        for (i, u) in rest.enumerated() where u == "/" || u == "\\" || u == "?" || u == "#" {
            end = i
            break
        }
        var authority = Array(rest[0..<end])
        let remainder = Array(rest[end...])
        var path = ""
        if remainder.first == "/" || remainder.first == "\\" {
            var pathEnd = remainder.count
            for (i, u) in remainder.enumerated() where u == "?" || u == "#" {
                pathEnd = i
                break
            }
            let slashed = remainder[0..<pathEnd].map { $0 == "\\" ? Unicode.Scalar("/") : $0 }
            path = CategoryText.asciiLower(string(slashed[...]))
        }
        if let at = authority.lastIndex(of: "@") { authority = Array(authority[(at + 1)...]) }
        if authority.first == "[" { return nil }
        if let colon = authority.lastIndex(of: ":") {
            for u in authority[(colon + 1)...] where !isDigitScalar(u) { return nil }
            authority = Array(authority[0..<colon])
        }
        var host = CategoryText.asciiLower(string(authority[...]))
        for u in host.unicodeScalars where !isHostChar(u) { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.isEmpty { return nil }
        return ParsedWebURL(host: host, path: path)
    }

    /// Compares Unicode scalars, as the TypeScript side compares code points. `hasPrefix` would
    /// compare Characters, so a combining mark after the slash ("/code/\u{301}x") would not match.
    private static func pathMatches(_ path: String, prefix: String) -> Bool {
        if path.unicodeScalars.elementsEqual(prefix.unicodeScalars) { return true }
        let base = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.unicodeScalars.starts(with: base.unicodeScalars)
    }

    /// The category for a web address, or nil when no rule matches or the text is not an address.
    public static func category(forURL raw: String) -> AppCategory? {
        guard let parsed = parseWebURL(raw) else { return nil }
        for rule in AppCategorySeeds.urlRules {
            let hostMatches = parsed.host == rule.host
                || (rule.subdomains && parsed.host.hasSuffix("." + rule.host))
            if !hostMatches { continue }
            if let prefix = rule.pathPrefix, !pathMatches(parsed.path, prefix: prefix) { continue }
            return rule.category
        }
        return nil
    }

    /// Override, then web address, then app seed, then Other. Never fails on bad input.
    /// - Parameters:
    ///   - appID: macOS bundle id or Windows executable name (a full path is fine).
    ///   - url: the browser address, when the delivery layer could read it.
    ///   - overrides: the user's per-app choices, keyed by app id. Keys match case-insensitively.
    public static func resolve(appID: String?, url: String?,
                               overrides: [String: AppCategory] = [:]) -> AppCategory {
        if let appID, !overrides.isEmpty {
            let key = normalizeAppID(appID)
            if !key.isEmpty {
                // Sorted so two keys that differ only in case always resolve the same way.
                for overrideKey in overrides.keys.sorted() where normalizeAppID(overrideKey) == key {
                    if let category = overrides[overrideKey] { return category }
                }
            }
        }
        if let url, let fromURL = category(forURL: url) { return fromURL }
        if let appID, let seeded = seededCategory(for: appID) { return seeded }
        return .other
    }
}
