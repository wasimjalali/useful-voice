import Foundation
import Testing

@testable import UsefulVoiceCore

@Suite("File protection")
struct FileProtectionTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-protection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = attributes[.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }

    @Test("a directory is restricted to owner-only")
    func restrictsDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Simulate what the process umask produces, which is the actual bug.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        #expect(FileProtection.restrict(directory, isDirectory: true))
        #expect(try permissions(of: directory) == 0o700)
    }

    @Test("a file is restricted to owner-only")
    func restrictsFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(FileProtection.restrict(file, isDirectory: false))
        #expect(try permissions(of: file) == 0o600)
    }

    @Test("no group or other bits remain")
    func removesGroupAndOtherBits() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A permissive starting point, as if umask were 0.
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

        FileProtection.restrict(directory, isDirectory: true)

        let mode = try permissions(of: directory)
        // The assertion that matters is that nobody but the owner can reach it.
        #expect(mode & 0o077 == 0, "group/other bits still set: \(String(mode, radix: 8))")
    }

    @Test("recursion restricts nested files and directories")
    func restrictsRecursively() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let audio = nested.appendingPathComponent("clip.wav")
        let transcript = nested.appendingPathComponent("clip.txt")
        try Data([0x00]).write(to: audio)
        try Data("hello".utf8).write(to: transcript)
        for url in [root, nested] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for url in [audio, transcript] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        FileProtection.restrictRecursively(root)

        #expect(try permissions(of: root) == 0o700)
        #expect(try permissions(of: nested) == 0o700)
        #expect(try permissions(of: audio) == 0o600)
        #expect(try permissions(of: transcript) == 0o600)
    }

    @Test("a missing path is reported, not crashed on")
    func missingPathIsNotFatal() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-does-not-exist-\(UUID().uuidString)")

        // Hardening is an improvement, never a precondition: a path that is not
        // there must not take down launch.
        #expect(FileProtection.restrict(missing) == false)
        FileProtection.restrictRecursively(missing)
    }

    @Test("the modes are exactly owner-only")
    func modesAreOwnerOnly() {
        #expect(FileProtection.fileMode.intValue == 0o600)
        #expect(FileProtection.directoryMode.intValue == 0o700)
    }
}

@Suite("Recordings are stored owner-only")
struct RecordingStoreProtectionTests {
    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    @Test("creating a store restricts its directory")
    func storeDirectoryIsOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try RecordingStore(directory: root)

        // Recorded speech is the most sensitive thing the app writes, so the
        // protection must not depend on the caller remembering to apply it.
        #expect(try permissions(of: root) == 0o700)
    }

    @Test("a written recording is owner-only")
    func recordingFileIsOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(directory: root)

        let url = store.newRecordingURL()
        let writer = try WavWriter(url: url)
        try writer.finish()

        let mode = try permissions(of: url)
        #expect(mode & 0o077 == 0, "recording is reachable by other accounts: \(String(mode, radix: 8))")
    }

    @Test("a saved transcript is owner-only")
    func transcriptFileIsOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-recordings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(directory: root)
        let audio = store.newRecordingURL()

        try store.saveTranscript("this is what the user said", for: audio)

        let sidecar = audio.deletingPathExtension().appendingPathExtension("txt")
        let mode = try permissions(of: sidecar)
        // A transcript is as sensitive as the audio beside it.
        #expect(mode & 0o077 == 0, "transcript is reachable by other accounts: \(String(mode, radix: 8))")
    }
}
