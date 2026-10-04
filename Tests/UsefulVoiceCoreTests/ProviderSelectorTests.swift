import Foundation
import Testing
@testable import UsefulVoiceCore

@Suite("Provider selection")
struct ProviderSelectorTests {
    private let turbo = WhisperModelCatalog.largeV3Turbo

    @Test func deepgramWithKeyResolvesToDeepgram() {
        #expect(ProviderSelector.resolve(
            engine: .deepgram, deepgramKeyAvailable: true,
            localModel: turbo, localModelAvailability: .missing) == .deepgram)
    }

    @Test func deepgramWithoutKeyNeedsKey() {
        #expect(ProviderSelector.resolve(
            engine: .deepgram, deepgramKeyAvailable: false,
            localModel: turbo, localModelAvailability: .usable) == .needsDeepgramKey)
    }

    @Test func localWithUsableModelResolvesToLocal() {
        #expect(ProviderSelector.resolve(
            engine: .whisperLocal, deepgramKeyAvailable: true,
            localModel: turbo, localModelAvailability: .usable) == .local(turbo))
    }

    /// The important privacy invariant: with local selected, a missing model
    /// must NOT fall back to Deepgram even though a key is present — choosing
    /// local is choosing that no audio leaves the machine.
    @Test func localWithMissingModelNeverFallsBackToCloud() {
        #expect(ProviderSelector.resolve(
            engine: .whisperLocal, deepgramKeyAvailable: true,
            localModel: turbo, localModelAvailability: .missing)
                == .needsModelDownload(turbo))
    }

    @Test func localWithInvalidModelReportsReason() {
        #expect(ProviderSelector.resolve(
            engine: .whisperLocal, deepgramKeyAvailable: false,
            localModel: turbo, localModelAvailability: .invalid("bad header"))
                == .modelInvalid(turbo, reason: "bad header"))
    }

    @Test func usablePlansProduceNoUnavailableMessage() {
        #expect(ProviderSelector.unavailableMessage(for: .deepgram) == nil)
        #expect(ProviderSelector.unavailableMessage(for: .local(turbo)) == nil)
    }

    @Test func unusablePlansProduceActionableMessages() {
        #expect(ProviderSelector.unavailableMessage(for: .needsDeepgramKey)?
            .contains("API key") == true)
        #expect(ProviderSelector.unavailableMessage(for: .needsModelDownload(turbo))?
            .contains("not downloaded") == true)
        #expect(ProviderSelector.unavailableMessage(for: .modelInvalid(turbo, reason: "bad header"))?
            .contains("bad header") == true)
    }

    @Test func unavailableProviderThrowsNotConfigured() async {
        let provider = UnavailableProvider(name: "Whisper (local)", message: "download it first")
        do {
            _ = try await provider.transcribe(
                audio: URL(fileURLWithPath: "/tmp/none.wav"),
                hint: TranscriptionHint(languagePin: .auto, dictionaryWords: []))
            Issue.record("expected a throw")
        } catch let error as ProviderError {
            guard case .notConfigured(let message) = error else {
                Issue.record("expected notConfigured, got \(error)")
                return
            }
            #expect(message == "download it first")
        } catch {
            Issue.record("expected ProviderError, got \(error)")
        }
    }

    @Test func engineSettingsDefaultToDeepgramAndTurbo() {
        let suite = "provider-selector-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.transcriptionEngine == .deepgram)
        #expect(settings.localModelID == WhisperModelCatalog.largeV3Turbo.id)
    }

    @Test func engineSettingsRoundTripAndRejectUnknownValues() {
        let suite = "provider-selector-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionEngine = .whisperLocal
        #expect(settings.transcriptionEngine == .whisperLocal)
        settings.localModelID = WhisperModelCatalog.largeV3.id
        #expect(settings.localModelID == WhisperModelCatalog.largeV3.id)
        // An unrecognised stored value resolves to the recommended model rather
        // than naming a model that cannot be found.
        settings.localModelID = "whisper-fictional-v9"
        #expect(settings.localModelID == WhisperModelCatalog.largeV3Turbo.id)
    }

    @Test func languagePinMapsToWhisperCodes() {
        #expect(LocalWhisperProvider.whisperLanguageCode(for: .auto) == nil)
        #expect(LocalWhisperProvider.whisperLanguageCode(for: .multilingual) == nil)
        #expect(LocalWhisperProvider.whisperLanguageCode(for: .en) == "en")
        #expect(LocalWhisperProvider.whisperLanguageCode(for: .de) == "de")
        #expect(LocalWhisperProvider.whisperLanguageCode(for: LanguagePin(code: "fa")) == "fa")
        #expect(LocalWhisperProvider.whisperLanguageCode(for: LanguagePin(code: "de-CH")) == "de")
        #expect(LocalWhisperProvider.whisperLanguageCode(for: LanguagePin(code: "zh-HK")) == "yue")
        #expect(LocalWhisperProvider.whisperLanguageCode(for: LanguagePin(code: "zh-TW")) == "zh")
    }
}
