import Foundation
import Testing
@testable import UsefulVoiceCore

/// E2E: exercises the real whisper.cpp engine against a real downloaded model
/// and real speech synthesized with `say` at test time. The suite is disabled
/// (reported as skipped, not passed) on machines without the model, so the
/// rest of the suite stays hermetic.
@Suite("Local whisper end-to-end (requires downloaded model)",
       .enabled(if: e2eModelIsInstalled()))
struct LocalWhisperE2ETests {
    static let model = WhisperModelCatalog.largeV3Turbo

    private var store: LocalModelStore { LocalModelStore() }

    init() {
        // Same residency workaround the app sets in main.swift: without it the
        // test process aborts at exit within 3 minutes of a transcription.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 0)
    }

    /// Synthesizes a 16 kHz mono 16-bit WAV of `sentence` into a fresh temp dir.
    private func makeFixture(_ sentence: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-whisper-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", sentence]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0, "say failed to synthesize the fixture")
        return wav
    }

    @Test(.timeLimit(.minutes(5)))
    func transcribesRealSpeechWithAPinnedLanguage() async throws {
        let wav = try makeFixture("Hello, this is a test of local dictation on this Mac.")
        let partials = LockedPartials()
        let provider = LocalWhisperProvider(
            model: Self.model, engine: WhisperCppEngine(), store: store,
            onPartialResult: { text in partials.append(text) })

        let transcript = try await provider.transcribe(
            audio: wav,
            hint: TranscriptionHint(languagePin: LanguagePin(code: "en"), dictionaryWords: []))

        #expect(!transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(transcript.text.lowercased().contains("hello"))
        #expect(!partials.values.isEmpty)
    }

    /// Regression for the empty-transcript bug: Auto used to set
    /// `detect_language`, which in whisper.cpp means "detect and stop".
    @Test(.timeLimit(.minutes(5)))
    func autoPinTranscribesAndReportsTheDetectedLanguage() async throws {
        let wav = try makeFixture("Hello, this is a test of local dictation on this Mac.")
        let provider = LocalWhisperProvider(
            model: Self.model, engine: WhisperCppEngine(), store: store)

        let transcript = try await provider.transcribe(
            audio: wav,
            hint: TranscriptionHint(languagePin: .auto, dictionaryWords: []))

        #expect(!transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(transcript.text.lowercased().contains("hello"))
        #expect(transcript.detectedLanguage == "en")
    }
}

private func e2eModelIsInstalled() -> Bool {
    LocalModelStore().availability(of: WhisperModelCatalog.largeV3Turbo) == .usable
}

/// Sendable scratch space for the @Sendable segment callback.
private final class LockedPartials: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }
}
