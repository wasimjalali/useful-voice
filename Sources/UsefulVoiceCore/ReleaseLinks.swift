import Foundation

/// Links into the public releases repo, github.com/wasimjalali/useful-voice-releases.
///
/// The repos do not exist yet, so every link stays hidden while `releasesRepoLive`
/// is false. Flip it in the PR that publishes the repos, not before: a row that opens
/// a 404 is worse than no row.
public enum ReleaseLinks {
    public static let releasesRepoLive = false

    public struct Link: Equatable, Sendable {
        public let title: String
        public let url: URL
    }

    /// `live` defaults to the switch; tests pass it to check both states.
    public static func reportBug(live: Bool = releasesRepoLive) -> URL? {
        live ? URL(string: "https://github.com/wasimjalali/useful-voice-releases/issues/new") : nil
    }

    public static func whatsNew(live: Bool = releasesRepoLive) -> URL? {
        live ? URL(string: "https://github.com/wasimjalali/useful-voice-releases/releases") : nil
    }

    public static func privacy(live: Bool = releasesRepoLive) -> URL? {
        live ? URL(string: "https://voice.usefulbuild.com/privacy") : nil
    }

    /// The Settings rows, in order. Empty while the switch is off.
    public static func links(live: Bool = releasesRepoLive) -> [Link] {
        [("Report a bug", reportBug(live: live)),
         ("What's new", whatsNew(live: live)),
         ("Privacy", privacy(live: live))]
            .compactMap { title, url in url.map { Link(title: title, url: $0) } }
    }
}
