import Testing
import UsefulVoiceCore
@testable import UsefulVoiceApp

/// A Retry whose recording has been deleted says so, in those words, on every surface
/// (not "Couldn't start recording").
@MainActor
@Suite("Retry unavailable")
struct RetryUnavailableTests {
    static let message = "The recording for this dictation is gone, so it can't be retried."
    private let error = DictationError(kind: .retryUnavailable, message: RetryUnavailableTests.message)

    @Test func hudSaysIt() {
        let hud = HUDError(error)
        #expect(hud.message == Self.message)
        #expect(hud.fix == nil)
    }

    @Test func announcerSaysIt() {
        #expect(Announcer.message(for: .error(HUDError(error))) == .init(text: Self.message, urgent: true))
    }

    @Test func dockSaysIt() {
        let issue = DockIssue(.error(error), canRetry: false)
        #expect(issue.lead == Self.message)
        #expect(issue.rest == "")
        #expect(issue.fix == nil)
    }

    @Test func bannerSaysItWithNoVerb() {
        let banner = WindowBanner.issueBanner(error)
        #expect(banner?.title == Self.message)
        #expect(banner?.verb == nil)
        #expect(WindowBanner.isPersistent(.retryUnavailable))
    }
}
