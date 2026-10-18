import Testing
import UsefulVoiceCore
@testable import UsefulVoiceApp

/// The HUD names the provider that failed and shows a model's own setup message.
@MainActor
@Suite("Model errors in the HUD")
struct ModelErrorsTests {
    @Test func aKeyErrorNamesItsProvider() {
        let eleven = DictationError(kind: .keyRejected, message: "", provider: "ElevenLabs")
        #expect(HUDError(eleven).message == "ElevenLabs key rejected")
        let gemini = DictationError(kind: .outOfCredits, message: "", provider: "Gemini")
        #expect(HUDError(gemini).message == "Gemini out of credits")
        // Unknown provider keeps the old Deepgram wording.
        #expect(HUDError(DictationError(kind: .keyRejected, message: "")).message == "Deepgram key rejected")
    }

    @Test func aSpecificSetupMessageReplacesTheGenericOne() {
        let refused = DictationError(
            kind: .noProvider, message: "Transcription failed: x", fix: .openEngineSettings,
            provider: "Parakeet (local)", specific: "Parakeet only speaks English.")
        #expect(HUDError(refused).message == "Parakeet only speaks English.")
        let nothing = DictationError(kind: .noProvider, message: "No transcription provider configured.")
        #expect(HUDError(nothing).message == "No engine set up")
    }

    @Test func aParakeetFailureSaysParakeet() {
        let failed = DictationError(kind: .engineFailed, message: "", provider: "Parakeet (local)")
        #expect(HUDError(failed).message == "Parakeet failed")
        #expect(HUDError(DictationError(kind: .providerFailed, message: "", provider: "Deepgram")).message == "Transcription failed")
    }
}
