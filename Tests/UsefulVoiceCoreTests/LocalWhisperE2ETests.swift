import Foundation
import Testing
@testable import UsefulVoiceCore

/// Temporary E2E smoke: exercises the real whisper.cpp engine against a real
/// downloaded model and real synthesized speech. Skips cleanly when the model
/// or the fixture WAV is absent so the suite stays hermetic on other machines.
@Suite("Local whisper end-to-end (requires downloaded model)")
struct LocalWhisperE2ETests {
    private var store: LocalModelStore { LocalModelStore() }
    private var model: WhisperModel { WhisperModelCatalog.largeV3Turbo }

    private var wavURL: URL {
        URL(fileURLWithPath: "/tmp/uv-hello.wav")
    }

    @Test(.timeLimit(.minutes(5)))
    func transcribesRealSpeechOnDevice() async throws {
        guard store.availability(of: model) == .usable else {
            return // model not downloaded on this machine — nothing to test
        }
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            return
        }

        let engine = WhisperCppEngine()
        let provider = LocalWhisperProvider(model: model, engine: engine, store: store)
        let partials = LockedPartials()
        provider.onPartialResult = { text in partials.append(text) }

        let transcript = try await provider.transcribe(
            audio: wavURL,
            hint: TranscriptionHint(languagePin: LanguagePin(code: "en"), dictionaryWords: []))

        #expect(!transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(transcript.text.lowercased().contains("hello"))
        #expect(!partials.values.isEmpty)
    }
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
