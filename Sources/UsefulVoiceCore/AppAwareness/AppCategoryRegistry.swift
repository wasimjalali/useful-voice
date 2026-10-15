import Foundation

/// Which category an app or web page belongs to.
/// `windows/src/core/apps/appCategoryRegistry.ts` mirrors this file rule for rule.
///
/// Resolution order: the user's override for the app, then the web address (when the
/// delivery layer could read one), then the app's seed, then Other. Everything here is
/// pure: reading the foreground app and the browser address is the caller's job.
public enum AppCategoryRegistry {
    /// The lookup key for an app id: trimmed, lower case, and for a Windows path only the
    /// file name (`C:\Program Files\Slack\slack.exe` becomes `slack.exe`).
    public static func normalizeAppID(_ raw: String) -> String {
        var id = CategoryText.trimWS(raw).lowercased()
        if let slash = id.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            id = String(id[id.index(after: slash)...])
        }
        return id
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
        for prefix in AppCategorySeeds.codingAppPrefixes where id.hasPrefix(prefix.lowercased()) {
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

    private static func isHostChar(_ c: Character) -> Bool {
        guard let v = c.asciiValue else { return false }
        return (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 45 || v == 46
    }

    /// Splits an address into host and path. Accepts `http` and `https` addresses and bare
    /// `host/path` text (a browser address bar often omits the scheme). Returns nil for
    /// anything else: other schemes, empty text, spaces in the host, a non-numeric port.
    public static func parseWebURL(_ raw: String) -> ParsedWebURL? {
        let text = CategoryText.trimWS(raw)
        if text.isEmpty { return nil }
        var rest = Array(text)
        if let r = text.range(of: "://") {
            let scheme = String(text[text.startIndex..<r.lowerBound]).lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            rest = Array(text[r.upperBound...])
        }
        var end = rest.count
        for (i, c) in rest.enumerated() where c == "/" || c == "?" || c == "#" {
            end = i
            break
        }
        var authority = Array(rest[0..<end])
        let remainder = Array(rest[end...])
        var path = ""
        if remainder.first == "/" {
            var pathEnd = remainder.count
            for (i, c) in remainder.enumerated() where c == "?" || c == "#" {
                pathEnd = i
                break
            }
            path = String(remainder[0..<pathEnd]).lowercased()
        }
        if let at = authority.lastIndex(of: "@") { authority = Array(authority[(at + 1)...]) }
        if authority.first == "[" { return nil }
        if let colon = authority.lastIndex(of: ":") {
            for c in authority[(colon + 1)...] {
                guard let v = c.asciiValue, v >= 48, v <= 57 else { return nil }
            }
            authority = Array(authority[0..<colon])
        }
        var host = String(authority).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.isEmpty { return nil }
        for c in host where !isHostChar(c) { return nil }
        return ParsedWebURL(host: host, path: path)
    }

    private static func pathMatches(_ path: String, prefix: String) -> Bool {
        if path == prefix { return true }
        let base = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.hasPrefix(base)
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
