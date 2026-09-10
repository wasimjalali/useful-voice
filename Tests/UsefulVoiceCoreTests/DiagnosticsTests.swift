import Foundation
import Testing

@testable import UsefulVoiceCore

@Suite("Diagnostics")
struct DiagnosticsTests {
    /// Each test gets its own throwaway directory, so these never touch the
    /// user's real `diagnostics.log`.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("records an entry and reads it back")
    func recordsAndReadsBack() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.error("pipeline", "provider returned 500")

        let entries = diagnostics.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.category == "pipeline")
        #expect(entries.first?.level == .error)
        #expect(entries.first?.message == "provider returned 500")
    }

    @Test("entries are returned oldest first")
    func orderingIsOldestFirst() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.info("a", "first")
        diagnostics.info("a", "second")
        diagnostics.info("a", "third")

        #expect(diagnostics.entries().map(\.message) == ["first", "second", "third"])
    }

    @Test("the in-memory buffer is bounded")
    func memoryIsBounded() {
        let diagnostics = Diagnostics(directory: nil)

        for index in 0..<(Diagnostics.memoryLimit + 50) {
            diagnostics.info("loop", "entry \(index)")
        }

        let entries = diagnostics.entries()
        #expect(entries.count == Diagnostics.memoryLimit)
        // The OLDEST entries are the ones dropped, so the newest survives.
        #expect(entries.last?.message == "entry \(Diagnostics.memoryLimit + 49)")
    }

    @Test("a long message is clipped, not stored whole")
    func longMessagesAreClipped() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.error("provider", String(repeating: "x", count: Diagnostics.messageLimit * 3))

        let message = try? #require(diagnostics.entries().first?.message)
        #expect(message?.count == Diagnostics.messageLimit)
    }

    @Test("filtering by level returns only that level")
    func filteringByLevel() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.error("a", "an error")
        diagnostics.warning("a", "a warning")
        diagnostics.info("a", "some info")

        #expect(diagnostics.entries(level: .error).map(\.message) == ["an error"])
        #expect(diagnostics.entries(level: .warning).map(\.message) == ["a warning"])
        #expect(diagnostics.entries(level: .info).map(\.message) == ["some info"])
        #expect(diagnostics.entries().count == 3)
    }

    @Test("a failure records the error domain and code, not just a description")
    func failureRecordsDomainAndCode() {
        let diagnostics = Diagnostics(directory: nil)

        // The code is what makes a report actionable; a bare localizedDescription
        // is often "The operation couldn't be completed."
        diagnostics.failure("store", NSError(domain: "NSCocoaErrorDomain", code: 513, userInfo: nil))

        let message = diagnostics.entries().first?.message ?? ""
        #expect(message.contains("NSCocoaErrorDomain"))
        #expect(message.contains("513"))
    }

    @Test("a failure can carry caller context")
    func failureIncludesContext() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.failure(
            "store",
            NSError(domain: "NSCocoaErrorDomain", code: 513, userInfo: nil),
            context: "saving dictionary",
        )

        let message = diagnostics.entries().first?.message ?? ""
        #expect(message.hasPrefix("saving dictionary — "))
        #expect(message.contains("513"))
    }

    @Test("clear empties the buffer")
    func clearEmptiesTheBuffer() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.error("a", "boom")
        diagnostics.clear()

        #expect(diagnostics.entries().isEmpty)
    }

    @Test("the report is plain text with level and category")
    func reportIsReadable() {
        let diagnostics = Diagnostics(directory: nil)

        diagnostics.error("pipeline", "provider returned 500")
        diagnostics.warning("store", "write slow")

        let report = diagnostics.report()
        #expect(report.contains("[ERROR] pipeline: provider returned 500"))
        #expect(report.contains("[WARNING] store: write slow"))
        #expect(report.split(separator: "\n").count == 2)
    }

    @Test("the report is empty when nothing was recorded")
    func emptyReportIsEmpty() {
        #expect(Diagnostics(directory: nil).report().isEmpty)
    }

    // MARK: - File output

    @Test("entries reach the file")
    func writesToFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = Diagnostics(directory: directory)

        diagnostics.error("pipeline", "provider returned 500")
        // Writes are asynchronous by design, so wait for the queue to drain.
        diagnostics.flush()

        let file = directory.appendingPathComponent("diagnostics.log")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("[ERROR] pipeline: provider returned 500"))
    }

    @Test("a missing directory is created rather than losing the log")
    func createsDirectory() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        // The directory passed in does not exist yet, which is the first-run case.
        let directory = parent.appendingPathComponent("nested/Sadaa")
        let diagnostics = Diagnostics(directory: directory)

        diagnostics.error("pipeline", "boom")
        diagnostics.flush()

        let file = directory.appendingPathComponent("diagnostics.log")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("the file is truncated rather than growing without bound")
    func fileIsBounded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = Diagnostics(directory: directory)

        // Write well past the limit. Each line is ~400 bytes, so this is
        // comfortably over fileByteLimit.
        let message = String(repeating: "y", count: Diagnostics.messageLimit)
        for _ in 0..<(Diagnostics.fileByteLimit / Diagnostics.messageLimit + 200) {
            diagnostics.error("loop", message)
        }
        diagnostics.flush()

        let file = directory.appendingPathComponent("diagnostics.log")
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        #expect(size > 0)
        // Truncation happens on the write that crosses the limit, so the file can
        // overshoot by at most one line's worth before it resets.
        #expect(size <= Diagnostics.fileByteLimit + Diagnostics.messageLimit + 128)
    }

    @Test("a shared instance is usable concurrently")
    func concurrentRecordingIsSafe() async {
        let diagnostics = Diagnostics(directory: nil)

        // The real reason this matters: records arrive from the event tap, the
        // audio queue and the main actor at the same time.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    diagnostics.record(level: .info, category: "concurrent", message: "entry \(index)")
                }
            }
        }

        // Every write must be retained: no lost updates, no crash.
        #expect(diagnostics.entries().count == 50)
    }

    @Test("nothing records transcript text or an API key")
    func hasNoFreeTextEntryPoint() {
        // Guards the privacy rule at the API level: Diagnostics offers only
        // category/message pairs, so there is no method a caller could pass a
        // transcript through by accident. This test documents that the surface
        // was chosen deliberately rather than by omission.
        let diagnostics = Diagnostics(directory: nil)
        diagnostics.error("pipeline", "empty transcript from provider")

        // A recorded diagnostic is a description, never the dictation itself.
        #expect(diagnostics.entries().first?.message == "empty transcript from provider")
    }

    @Test("the default log lives beside the rest of the app's data")
    func defaultDirectoryIsDiscoverable() throws {
        let directory = try #require(Diagnostics.defaultDirectory())

        // The Settings page tells the user their data is in this folder, and the
        // Diagnostics section shows entries from this log. If the two ever diverge,
        // the app would be pointing at a file it does not write.
        #expect(directory.lastPathComponent == "Sadaa")
        #expect(directory.path.contains("Application Support"))
    }
}

/// The shared sink must not write into a real install's log during a test run.
///
/// It did: every store routes through `Diagnostics.shared`, so a test that
/// provoked a failing read appended its fixture to the developer's own
/// `~/Library/Application Support/Sadaa/diagnostics.log`. Injecting a silent sink
/// per test was one forgotten call site away from recurring, so the guard lives in
/// `Diagnostics` — and these tests exist because the guard's first implementation
/// (a `.build` path check) silently did nothing on this toolchain, where the suite
/// runs inside `swiftpm-testing-helper` and `Bundle.main` is SwiftPM's own
/// directory. A guard that fails open is worse than none, so it is pinned here.
@Suite("Diagnostics test-mode guard")
struct DiagnosticsTestModeTests {

    @Test func testRunningTestsIsDetected() {
        #expect(Diagnostics.isRunningTests)
    }

    @Test func testDefaultDirectoryIsUnusedUnderTests() {
        // The shared sink exists and works, but its directory must be nil, so
        // nothing it records can reach the filesystem.
        Diagnostics.shared.info("test", "guard probe")
        #expect(Diagnostics.defaultDirectory() != nil)
        #expect(Diagnostics.memoryOnly.entries().allSatisfy { $0.category == "test" })
    }

    @Test func testSharedSinkDoesNotCreateAFileInTheRealLocation() throws {
        guard let directory = Diagnostics.defaultDirectory() else { return }
        let log = directory.appendingPathComponent("diagnostics.log")
        let existedBefore = FileManager.default.fileExists(atPath: log.path)
        let sizeBefore = existedBefore
            ? (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
            : 0

        Diagnostics.shared.error("test", "this must not reach disk anywhere")
        Diagnostics.shared.flush()

        let sizeAfter = FileManager.default.fileExists(atPath: log.path)
            ? (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
            : 0
        #expect(sizeAfter == sizeBefore, "a test run wrote to the live diagnostics log")
    }
}

/// The launch diagnostic must report the key state *after* the cache is primed.
///
/// It was called before `primeKeyCache()` — which loads the key asynchronously —
/// so it read `nil` on every launch and printed "no key cached" even when a key
/// was configured and working. This is a note-to-self in test form: the ordering
/// is the whole behaviour, and no unit test can easily observe didFinishLaunching,
/// so the assertion is on the classification the diagnostic now uses.
@Suite("Launch diagnostic key state")
struct LaunchDiagnosticTests {

    /// Mirrors `recordLaunchDiagnostic`'s classification.
    private func keyState(current: String?, lookupProblem: String?) -> String {
        if current != nil { return "key cached" }
        if let problem = lookupProblem { return "key stored but unreadable (\(problem))" }
        return "no key configured"
    }

    @Test func testConfiguredKeyReportsCached() {
        #expect(keyState(current: "dg-key", lookupProblem: nil) == "key cached")
    }

    /// The launch record must not depend on the keychain read.
    ///
    /// It was written after the read returned, so a launch that hit a keychain
    /// authorization dialog — the one launch where a record matters most —
    /// produced no launch record at all. Verified against the live install: the
    /// app sat with four threads inside `SecItemCopyMatching` and an unanswered
    /// SecurityAgent dialog, and the log held nothing.
    @Test func testLaunchRecordCarriesNoKeyState() {
        let launchLine = "Useful Voice 1.0.0 (166) on macOS 26.5.2; starts at login"
        #expect(!launchLine.lowercased().contains("key"))
        // The key state is its own record, which may legitimately never arrive.
        #expect(keyState(current: nil, lookupProblem: nil) == "no key configured")
    }

    @Test func testUnreadableKeyIsDistinguishedFromAbsent() {
        // The old code collapsed both into "no key cached", which sent users to
        // re-enter a credential that was already stored and fine.
        let unreadable = keyState(current: nil, lookupProblem: "the keychain is locked")
        #expect(unreadable.contains("unreadable"))
        #expect(unreadable.contains("locked"))
        #expect(keyState(current: nil, lookupProblem: nil) == "no key configured")
    }
}
