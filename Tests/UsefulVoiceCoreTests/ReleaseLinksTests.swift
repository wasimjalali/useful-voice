import Foundation
import Testing
@testable import UsefulVoiceCore

/// The failure to guard against: a link to a repo that does not exist yet shipping
/// in a build. So the off state is checked first and hardest.
@Suite("Release links")
struct ReleaseLinksTests {
    @Test func shipsOffUntilTheReposExist() {
        #expect(ReleaseLinks.releasesRepoLive == false)
        #expect(ReleaseLinks.links().isEmpty)
    }

    @Test func offHidesEveryLink() {
        #expect(ReleaseLinks.reportBug(live: false) == nil)
        #expect(ReleaseLinks.whatsNew(live: false) == nil)
        #expect(ReleaseLinks.privacy(live: false) == nil)
        #expect(ReleaseLinks.links(live: false).isEmpty)
    }

    @Test func onShowsThreeHttpsLinksInOrder() {
        let links = ReleaseLinks.links(live: true)
        #expect(links.map(\.title) == ["Report a bug", "What's new", "Privacy"])
        #expect(links.allSatisfy { $0.url.scheme == "https" })
    }

    @Test func onPointsAtTheReleasesRepoAndPrivacyPage() {
        #expect(ReleaseLinks.reportBug(live: true)?.absoluteString
            == "https://github.com/wasimjalali/useful-voice-releases/issues/new")
        #expect(ReleaseLinks.whatsNew(live: true)?.absoluteString
            == "https://github.com/wasimjalali/useful-voice-releases/releases")
        #expect(ReleaseLinks.privacy(live: true)?.absoluteString
            == "https://voice.usefulbuild.com/privacy")
    }
}
