import Foundation
import Testing
@testable import UsefulVoiceCore

@MainActor
@Suite("Parakeet integrity, pin ordering and delete")
struct ParakeetReviewTests {
    @Test func aTruncatedModelFileNeverReadsAsReady() throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        #expect(ParakeetStorage.isReady(.v2, in: root))

        let weights = ParakeetStorage.modelsDirectory(.v2, in: root)
            .appendingPathComponent(ParakeetStorage.requiredEntries(.v2)[0])
            .appendingPathComponent("weights.bin")
        try Data(repeating: 1, count: 400).write(to: weights)  // was 1000 bytes
        #expect(!ParakeetStorage.isReady(.v2, in: root))
        #expect(ParakeetModelManager(directory: root).state(of: .v2) == .notDownloaded)
    }

    @Test func aMissingRecordedFileOrAnOldStyleMarkerIsNotReady() throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v3, root: root)
        let vocab = ParakeetStorage.modelsDirectory(.v3, in: root)
            .appendingPathComponent(ModelVocab.file)
        try FileManager.default.removeItem(at: vocab)
        #expect(!ParakeetStorage.isReady(.v3, in: root))

        try ParakeetFixtures.installFully(.v2, root: root)
        try Data("v2".utf8).write(
            to: ParakeetStorage.versionDirectory(.v2, in: root)
                .appendingPathComponent(ParakeetStorage.markerName))
        #expect(!ParakeetStorage.isReady(.v2, in: root))
    }

    @Test func theMarkerRecordsEveryFileSize() throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let data = try Data(contentsOf: ParakeetStorage.versionDirectory(.v2, in: root)
            .appendingPathComponent(ParakeetStorage.markerName))
        let marker = try JSONDecoder().decode(ParakeetStorage.Marker.self, from: data)
        #expect(marker.files.count >= 5)
        #expect(marker.files.values.allSatisfy { $0 > 0 })
    }

    @Test func theLatestPinWinsEvenWhenAnOlderOneArrivesLate() async {
        let engine = ParakeetEngine(version: .v2, modelsDirectory: URL(fileURLWithPath: "/nonexistent"),
                                    idleSeconds: 300)
        await engine.setPinned(false, generation: 2)
        await engine.setPinned(true, generation: 1)  // stale
        #expect(await engine.isPinned == false)
        await engine.setPinned(true, generation: 3)
        #expect(await engine.isPinned)
        await engine.setPinned(false, generation: 2)  // stale again
        #expect(await engine.isPinned)
    }

    @Test func manyQuickPinChangesEndWithTheLastValue() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let manager = ParakeetModelManager(directory: root, diagnostics: Diagnostics(directory: nil))
        _ = manager.provider(for: .v2)  // creates the engine
        for i in 0..<50 { manager.pinned = i % 2 == 0 ? .v2 : nil }
        manager.pinned = .v2
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await manager.isPinned(.v2))
        manager.pinned = nil
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await manager.isPinned(.v2) == false)
    }

    @Test func deleteIsImmediateAndLeavesNoTrashBehind() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ParakeetFixtures.installFully(.v2, root: root)
        let manager = ParakeetModelManager(directory: root, diagnostics: Diagnostics(directory: nil))
        try manager.delete(.v2)
        #expect(!FileManager.default.fileExists(
            atPath: ParakeetStorage.versionDirectory(.v2, in: root).path))
        #expect(manager.state(of: .v2) == .notDownloaded)
        let clean: () -> Bool = {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .allSatisfy { !$0.hasPrefix(ParakeetStorage.trashPrefix) }
        }
        let deadline = Date().addingTimeInterval(5)
        while !clean() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(clean())
    }

    @Test func aLeftoverTrashFolderIsSweptAtLaunch() async throws {
        let root = ParakeetFixtures.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("\(ParakeetStorage.trashPrefix)abc", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        _ = ParakeetModelManager(directory: root, diagnostics: Diagnostics(directory: nil))
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: trash.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: trash.path))
    }

    @Test func theGuardAndTheModelShareOneLanguageList() {
        #expect(ParakeetLanguageGuard.v3Languages == ParakeetVersion.v3Languages)
    }
}

private enum ModelVocab {
    static var file: String { ParakeetStorage.requiredEntries(.v3).last! }
}
