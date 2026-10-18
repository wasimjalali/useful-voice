import Foundation
import Testing
import UsefulVoiceCore
@testable import UsefulVoiceApp

/// The AI formatting list never claims formatting is on while the formatter can't read its key.
@MainActor
@Suite("Models view model")
struct ModelsViewModelTests {
    private func make() -> ModelsViewModel {
        let suite = "uv-mvm-\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.formatterModelID = "gemini:gemini-3.8-flash"
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uv-mvm-\(UUID().uuidString)")
        let whisper = LocalModelManager(settings: settings, store: LocalModelStore(directory: scratch))
        let model = ModelsViewModel(settings: settings, whisper: whisper,
                                    parakeet: ParakeetModelManager())
        model.applyPreview(.sample)   // Gemini key stored, formatter set
        return model
    }

    @Test func aKeyThatIsStoredButNotLoadedYetMeansFormattingIsNotOn() {
        let model = make()
        model.keyReadable = { _ in false }
        #expect(model.formatterID == "gemini:gemini-3.8-flash")
        #expect(model.effectiveFormatterID == nil)
        let gemini = ModelCatalog.languageModel(id: "gemini:gemini-3.8-flash")!
        #expect(!model.isSelected(gemini, kind: .formatter))
    }

    @Test func onceTheKeyIsReadableTheFormatterIsOn() {
        let model = make()
        model.keyReadable = { _ in false }
        #expect(model.effectiveFormatterID == nil)
        model.keyReadable = { $0 == .gemini }
        #expect(model.effectiveFormatterID == "gemini:gemini-3.8-flash")
        let gemini = ModelCatalog.languageModel(id: "gemini:gemini-3.8-flash")!
        #expect(model.isSelected(gemini, kind: .formatter))
    }

    @Test func aMissingKeyIsNeverReportedOn() {
        let model = make()
        model.applyPreview(.noKeys)
        #expect(model.effectiveFormatterID == nil)
    }
}
