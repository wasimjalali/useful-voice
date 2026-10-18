import Foundation
import Testing
@testable import UsefulVoiceCore

/// A scripted stand-in for the FluidAudio download, so the state machine runs without a network.
private final class FakeDownload: @unchecked Sendable {
    enum Mode { case succeed, fail, hang }
    private let lock = NSLock()
    private var _calls = 0
    private var _sawCancellation = false
    let mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    var calls: Int { lock.withLock { _calls } }
    var sawCancellation: Bool { lock.withLock { _sawCancellation } }

    var downloader: ParakeetDownloader {
        { [self] version, root, progress in
            lock.withLock { _calls += 1 }
            ParakeetFixtures.writeModelFiles(version, root: root)
            progress(0.25)
            switch mode {
            case .succeed:
                progress(1)
            case .fail:
                throw URLError(.notConnectedToInternet)
            case .hang:
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch {
                    lock.withLock { _sawCancellation = true }
                    throw error
                }
            }
        }
    }
}

enum ParakeetFixtures {
    static func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-parakeet-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The files a finished download leaves, without the completion marker.
    static func writeModelFiles(_ version: ParakeetVersion, root: URL) {
        let dir = ParakeetStorage.modelsDirectory(version, in: root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in ParakeetStorage.requiredEntries(version) {
            let url = dir.appendingPathComponent(entry)
            if entry.hasSuffix(".mlmodelc") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try? Data(repeating: 1, count: 1000).write(to: url.appendingPathComponent("weights.bin"))
            } else {
                try? Data(repeating: 2, count: 500).write(to: url)
            }
        }
    }

    static func installFully(_ version: ParakeetVersion, root: URL) throws {
        writeModelFiles(version, root: root)
        try ParakeetStorage.markComplete(version, in: root)
    }

    static func hint(_ code: String) -> TranscriptionHint {
        TranscriptionHint(languagePin: LanguagePin(code: code), dictionaryWords: [])
    }

    /// Half a second of silence; never reaches a model in the tests that use it.
    static func makeWav() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url, sampleRate: 16_000)
        try writer.append(samples: [Int16](repeating: 0, count: 8_000))
        try writer.finish()
        return url
    }
}

@MainActor
private func waitForState(_ manager: ParakeetModelManager, _ version: ParakeetVersion,
                          timeout: Double = 5,
                          until predicate: (ParakeetModelState) -> Bool) async -> ParakeetModelState {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate(manager.state(of: version)) { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return manager.state(of: version)
}

@Suite("Parakeet language gating")
struct ParakeetLanguageTests {
    @Test func v2RefusesAPinnedNonEnglishLanguageWithAClearMessage() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let engine = ParakeetEngine(version: .v2, modelsDirectory: root, idleSeconds: 300)
        let provider = ParakeetProvider(version: .v2, root: root, engine: engine)
        let wav = try ParakeetFixtures.makeWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        do {
            _ = try await provider.transcribe(audio: wav, hint: ParakeetFixtures.hint("de"))
            Issue.record("expected the German pin to be refused")
        } catch ProviderError.engineFailed(let message) {
            #expect(message.contains("only transcribes English"))
        }
    }

    @Test func v3RefusesAPinnedLanguageOutsideItsList() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v3, root: root)
        let engine = ParakeetEngine(version: .v3, modelsDirectory: root, idleSeconds: 300)
        let provider = ParakeetProvider(version: .v3, root: root, engine: engine)
        let wav = try ParakeetFixtures.makeWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        do {
            _ = try await provider.transcribe(audio: wav, hint: ParakeetFixtures.hint("ja"))
            Issue.record("expected the Japanese pin to be refused")
        } catch ProviderError.engineFailed(let message) {
            #expect(message.contains("doesn't cover"))
        }
    }

    @Test func v2AcceptsEnglishVariantsAndTheModes() {
        for code in ["en", "en-US", "en-GB", "auto", "multi"] {
            #expect(ParakeetVersion.v2.languageProblem(for: LanguagePin(code: code)) == nil, "\(code)")
        }
    }

    @Test func v3RefusesLanguagesOutsideItsTwentyFive() {
        for code in ["ja", "zh", "ar", "hi", "ko"] {
            let problem = ParakeetVersion.v3.languageProblem(for: LanguagePin(code: code))
            #expect(problem?.contains("doesn't cover") == true, "\(code)")
        }
    }

    @Test func v3AcceptsEveryOneOfItsTwentyFive() {
        #expect(ParakeetVersion.v3Languages.count == 25)
        for code in ParakeetVersion.v3Languages {
            #expect(ParakeetVersion.v3.languageProblem(for: LanguagePin(rawValue: code)) == nil, "\(code)")
        }
        #expect(ParakeetVersion.v3.languageProblem(for: LanguagePin(rawValue: "de-CH")) == nil)
        #expect(ParakeetVersion.v3.languageProblem(for: .multilingual) == nil)
    }

    @Test func catalogIDsRoundTrip() {
        for version in ParakeetVersion.allCases {
            #expect(ParakeetVersion(catalogID: version.catalogID) == version)
        }
        #expect(ParakeetVersion(catalogID: "whisper:large") == nil)
    }
}

@MainActor
@Suite("Parakeet model manager")
struct ParakeetManagerTests {
    @Test func aModelThatIsNotDownloadedFailsWithTheSettingsMessage() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ParakeetModelManager(directory: root)
        let wav = try ParakeetFixtures.makeWav()
        defer { try? FileManager.default.removeItem(at: wav) }

        for version in ParakeetVersion.allCases {
            do {
                _ = try await manager.provider(for: version)
                    .transcribe(audio: wav, hint: ParakeetFixtures.hint("auto"))
                Issue.record("expected notConfigured for \(version)")
            } catch ProviderError.notConfigured(let message) {
                #expect(message.contains("Download it in Settings"))
            }
        }
    }

    @Test func everythingStartsNotDownloadedOnAnEmptyFolder() {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ParakeetModelManager(directory: root)
        for version in ParakeetVersion.allCases {
            #expect(manager.state(of: version) == .notDownloaded)
        }
    }

    @Test func aHalfFinishedDownloadFromAnEarlierLaunchIsNotReady() throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Every file is there but the completion marker is not: the app was quit before the end.
        ParakeetFixtures.writeModelFiles(.v2, root: root)
        // v3 has the marker but lost a model folder.
        try ParakeetFixtures.installFully(.v3, root: root)
        let victim = ParakeetStorage.modelsDirectory(.v3, in: root)
            .appendingPathComponent(ParakeetStorage.requiredEntries(.v3)[0])
        try FileManager.default.removeItem(at: victim)

        let manager = ParakeetModelManager(directory: root)
        #expect(manager.state(of: .v2) == .notDownloaded)
        #expect(manager.state(of: .v3) == .notDownloaded)
    }

    @Test func aFullyDownloadedModelIsReadyAtLaunchWithItsSize() throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let manager = ParakeetModelManager(directory: root)
        guard case .ready(let size) = manager.state(of: .v2) else {
            Issue.record("expected ready, got \(manager.state(of: .v2))")
            return
        }
        #expect((size ?? 0) > 1000)
        #expect(manager.state(of: .v3) == .notDownloaded)
    }

    @Test func downloadingEndsReady() async {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeDownload(.succeed)
        let manager = ParakeetModelManager(directory: root, downloader: fake.downloader)
        manager.download(.v2)
        #expect(manager.state(of: .v2) == .downloading(progress: nil))
        let end = await waitForState(manager, .v2) { if case .ready = $0 { return true } else { return false } }
        guard case .ready = end else { Issue.record("got \(end)"); return }
        #expect(fake.calls == 1)
        #expect(ParakeetStorage.isReady(.v2, in: root))
    }

    @Test func aFailedDownloadReportsAReadableReasonAndIsNotReady() async {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ParakeetModelManager(directory: root, downloader: FakeDownload(.fail).downloader)
        manager.download(.v3)
        let end = await waitForState(manager, .v3) { if case .failed = $0 { return true } else { return false } }
        guard case .failed(let message) = end else { Issue.record("got \(end)"); return }
        #expect(message.contains("No internet"))
        #expect(!ParakeetStorage.isReady(.v3, in: root))
        // Trying again is allowed from a failure.
        manager.download(.v3)
        #expect(manager.state(of: .v3) == .downloading(progress: nil))
    }

    @Test func cancellingStopsTheDownloadAndLeavesNothingReady() async {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeDownload(.hang)
        let manager = ParakeetModelManager(directory: root, downloader: fake.downloader)
        manager.download(.v2)
        _ = await waitForState(manager, .v2) { $0 == .downloading(progress: 0.25) }
        manager.cancelDownload(.v2)
        #expect(manager.state(of: .v2) == .notDownloaded)
        let deadline = Date().addingTimeInterval(5)
        while !fake.sawCancellation && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(fake.sawCancellation)
        // The cancelled task finishing late must not bring the state back.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.state(of: .v2) == .notDownloaded)
        #expect(!ParakeetStorage.isReady(.v2, in: root))
        // A fresh manager (the next launch) agrees.
        #expect(ParakeetModelManager(directory: root).state(of: .v2) == .notDownloaded)
    }

    @Test func startingADownloadTwiceRunsItOnce() async {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeDownload(.hang)
        let manager = ParakeetModelManager(directory: root, downloader: fake.downloader)
        manager.download(.v2)
        manager.download(.v2)
        _ = await waitForState(manager, .v2) { $0 == .downloading(progress: 0.25) }
        #expect(fake.calls == 1)
        manager.cancelDownload(.v2)
    }

    @Test func deletingRemovesTheFilesAndTheNextProviderCallPointsToSettings() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        try ParakeetFixtures.installFully(.v3, root: root)
        let manager = ParakeetModelManager(directory: root)
        let provider = manager.provider(for: .v2)

        try manager.delete(.v2)
        #expect(manager.state(of: .v2) == .notDownloaded)
        #expect(!FileManager.default.fileExists(
            atPath: ParakeetStorage.versionDirectory(.v2, in: root).path))
        // The other version is untouched.
        guard case .ready = manager.state(of: .v3) else { Issue.record("v3 should stay ready"); return }

        let wav = try ParakeetFixtures.makeWav()
        defer { try? FileManager.default.removeItem(at: wav) }
        do {
            _ = try await provider.transcribe(audio: wav, hint: ParakeetFixtures.hint("auto"))
            Issue.record("expected notConfigured after delete")
        } catch ProviderError.notConfigured(let message) {
            #expect(message.contains("Settings"))
        }
        // Deleting again is fine.
        try manager.delete(.v2)
    }

    @Test func deletingDuringADownloadCancelsItAndClearsTheFolder() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeDownload(.hang)
        let manager = ParakeetModelManager(directory: root, downloader: fake.downloader)
        manager.download(.v3)
        _ = await waitForState(manager, .v3) { $0 == .downloading(progress: 0.25) }
        try manager.delete(.v3)
        #expect(manager.state(of: .v3) == .notDownloaded)
        #expect(!FileManager.default.fileExists(
            atPath: ParakeetStorage.versionDirectory(.v3, in: root).path))
    }

    @Test func aCorruptRecordingFailsWithAReadableMessage() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let manager = ParakeetModelManager(directory: root)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).wav")
        try Data("not a wav".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        do {
            _ = try await manager.provider(for: .v2).transcribe(audio: bad, hint: ParakeetFixtures.hint("auto"))
            Issue.record("expected engineFailed")
        } catch ProviderError.engineFailed(let message) {
            #expect(message.contains("Could not read the recording"))
        }
    }
}

/// Opt-in: downloads the real v2 model (a few hundred MB), then transcribes speech made by `say`.
/// Run with `UV_PARAKEET_E2E=1 make test`.
@Suite("Parakeet end-to-end (UV_PARAKEET_E2E=1, downloads the real model)",
       .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["UV_PARAKEET_E2E"] == "1"))
struct ParakeetE2ETests {
    private func say(_ sentence: String) throws -> URL {
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-e2e-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", wav.path, "--data-format=LEI16@16000", sentence]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "say failed")
        return wav
    }

    @MainActor
    @Test(.timeLimit(.minutes(30)))
    func downloadsV2AndTranscribesRealSpeech() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = try say("Hello, this is a test of local dictation on this Mac.")
        defer { try? FileManager.default.removeItem(at: wav) }

        let manager = ParakeetModelManager(directory: root, idleSeconds: 2)
        let downloadStart = Date()
        manager.download(.v2)
        var seen: [Double?] = []
        let state = await waitForState(manager, .v2, timeout: 1500) { state in
            if case .downloading(let p) = state, seen.last != .some(p) { seen.append(p) }
            if case .ready = state { return true }
            if case .failed = state { return true }
            return false
        }
        let downloadSeconds = Date().timeIntervalSince(downloadStart)
        guard case .ready(let size) = state else { Issue.record("download ended as \(state)"); return }
        print("PARAKEET_E2E download seconds=\(downloadSeconds) bytes=\(size ?? -1) progress=\(seen)")

        // A relaunch sees the same thing on disk.
        guard case .ready = ParakeetModelManager(directory: root).state(of: .v2) else {
            Issue.record("a fresh manager should see v2 ready"); return
        }

        let provider = manager.provider(for: .v2)
        let hint = ParakeetFixtures.hint("en")
        let coldStart = Date()
        let cold = try await provider.transcribe(audio: wav, hint: hint)
        let coldSeconds = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let warm = try await provider.transcribe(audio: wav, hint: hint)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        print("PARAKEET_E2E cold seconds=\(coldSeconds) warm seconds=\(warmSeconds) text=\(warm.text)")

        for transcript in [cold, warm] {
            let text = transcript.text.lowercased()
            for word in ["hello", "test", "local dictation", "mac"] {
                #expect(text.contains(word), "missing '\(word)' in '\(transcript.text)'")
            }
        }
        #expect(await manager.isLoaded(.v2))

        // Idle unload (2 s here, 5 minutes in the app).
        try await Task.sleep(nanoseconds: 3_500_000_000)
        #expect(await manager.isLoaded(.v2) == false)

        // Delete frees the files.
        try manager.delete(.v2)
        #expect(manager.state(of: .v2) == .notDownloaded)
    }
}
