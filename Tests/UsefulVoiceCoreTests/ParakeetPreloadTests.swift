import Foundation
import Testing
@testable import UsefulVoiceCore

/// Counts loads and calls; every load takes a moment, so overlapping callers really overlap.
private final class FakeLoads: @unchecked Sendable {
    private let lock = NSLock()
    private var _loads = 0
    private var _cleanups = 0
    private var _sampleCounts: [Int] = []
    var loads: Int { lock.withLock { _loads } }
    var cleanups: Int { lock.withLock { _cleanups } }
    var sampleCounts: [Int] { lock.withLock { _sampleCounts } }

    var loader: ParakeetSessionLoader {
        { [self] _, _ in
            lock.withLock { _loads += 1 }
            try await Task.sleep(nanoseconds: 200_000_000)
            return Session(owner: self)
        }
    }

    struct Session: ParakeetSession {
        let owner: FakeLoads
        func transcribe(samples: [Float], language: String?) async throws -> String {
            owner.lock.withLock { owner._sampleCounts.append(samples.count) }
            return "ok"
        }
        func cleanup() async { owner.lock.withLock { owner._cleanups += 1 } }
    }
}

private func eventually(_ timeout: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@MainActor
@Suite("Parakeet preload and pinning")
struct ParakeetPreloadTests {
    private func manager(_ root: URL, _ fake: FakeLoads, idle: Double = 300) -> ParakeetModelManager {
        ParakeetModelManager(directory: root, idleSeconds: idle, loader: fake.loader,
                             diagnostics: Diagnostics(directory: nil))
    }

    @Test func preloadDoesNothingForAModelThatIsNotDownloaded() async {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeLoads()
        let manager = manager(root, fake)
        manager.preload(.v2)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(fake.loads == 0)
        #expect(await manager.isLoaded(.v2) == false)
    }

    @Test func preloadLoadsOnceWarmsUpWithASecondOfSilenceAndIsIdempotent() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let fake = FakeLoads()
        let manager = manager(root, fake)
        manager.preload(.v2)
        manager.preload(.v2)
        #expect(await eventually { await manager.isLoaded(.v2) })
        manager.preload(.v2)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(fake.loads == 1)
        #expect(fake.sampleCounts == [16_000])
    }

    @Test func aTranscribeDuringAPreloadWaitsForItInsteadOfLoadingAgain() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let wav = try ParakeetFixtures.makeWav()
        defer { try? FileManager.default.removeItem(at: wav) }
        let fake = FakeLoads()
        let manager = manager(root, fake)
        manager.preload(.v2)
        try await Task.sleep(nanoseconds: 50_000_000)  // the preload's load is in flight
        let transcript = try await manager.provider(for: .v2)
            .transcribe(audio: wav, hint: ParakeetFixtures.hint("en"))
        #expect(transcript.text == "ok")
        #expect(fake.loads == 1)
    }

    @Test func aPreloadFailureDoesNotThrowAndLeavesTheNextDictationFree() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let diagnostics = Diagnostics(directory: nil)
        let manager = ParakeetModelManager(
            directory: root, loader: { _, _ in throw URLError(.cannotLoadFromNetwork) },
            diagnostics: diagnostics)
        manager.preload(.v2)
        #expect(await eventually { !diagnostics.entries().isEmpty })
        #expect(await manager.isLoaded(.v2) == false)
    }

    @Test func aPinnedVersionIsNeverUnloadedForBeingIdle() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let fake = FakeLoads()
        let manager = manager(root, fake, idle: 0.3)
        manager.pinned = .v2
        manager.preload(.v2)
        #expect(await eventually { await manager.isLoaded(.v2) })
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(await manager.isLoaded(.v2))
        #expect(fake.cleanups == 0)
    }

    @Test func anUnpinnedVersionStillUnloadsWhenIdle() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let fake = FakeLoads()
        let manager = manager(root, fake, idle: 0.3)
        manager.preload(.v2)
        #expect(await eventually { await manager.isLoaded(.v2) })
        #expect(await eventually { await manager.isLoaded(.v2) == false })
        #expect(await eventually { fake.cleanups == 1 })
    }

    @Test func unpinningLetsALoadedVersionIdleOut() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let fake = FakeLoads()
        let manager = manager(root, fake, idle: 0.3)
        manager.pinned = .v2
        manager.preload(.v2)
        #expect(await eventually { await manager.isLoaded(.v2) })
        manager.pinned = .v3
        #expect(await eventually { await manager.isLoaded(.v2) == false })
    }

    @Test func aFinishedDownloadPreloadsTheModel() async {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeLoads()
        let manager = ParakeetModelManager(
            directory: root,
            downloader: { version, root, _ in ParakeetFixtures.writeModelFiles(version, root: root) },
            loader: fake.loader, diagnostics: Diagnostics(directory: nil))
        manager.download(.v2)
        #expect(await eventually { await manager.isLoaded(.v2) })
        #expect(fake.loads == 1)
    }
}
