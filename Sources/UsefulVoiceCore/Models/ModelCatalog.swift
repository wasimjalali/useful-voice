import Foundation

/// One model the Settings > Models page offers.
public struct ModelEntry: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case cloud, local }

    /// `<provider>:<model>`, the value saved in settings.
    public let id: String
    public let name: String
    /// deepgram, elevenlabs, nvidia, openai, gemini or anthropic.
    public let provider: String
    /// The model string the provider's API takes.
    public let apiModel: String
    public let kind: Kind
    /// A small chip next to the name ("EN", "NEW"), or nil.
    public let badge: String?
    /// Relative 1-5 ratings for dictation, not benchmarks.
    public let speed: Int
    public let accuracy: Int

    public var isLocal: Bool { kind == .local }

    /// The key this model needs, nil for local models.
    public var keyProvider: KeyProvider? {
        kind == .cloud ? KeyProvider(catalogProvider: provider) : nil
    }

    /// Short provider mark for the monogram tile. No vendor logos.
    public var monogram: String {
        switch provider {
        case "deepgram": return "D"
        case "elevenlabs": return "11"
        case "nvidia": return "N"
        case "openai": return "W"
        case "gemini": return "G"
        case "anthropic": return "A"
        default: return String(provider.prefix(1)).uppercased()
        }
    }

    public var providerName: String {
        switch provider {
        case "deepgram": return "Deepgram"
        case "elevenlabs": return "ElevenLabs"
        case "nvidia": return "NVIDIA"
        case "openai": return "OpenAI"
        case "gemini": return "Gemini"
        case "anthropic": return "Anthropic"
        default: return provider
        }
    }
}

/// The macOS model list. `Tests/Fixtures/models/catalog.json` is the shared source
/// of truth; a test checks this file against it so the platforms can't drift.
public enum ModelCatalog {
    public static let voice: [ModelEntry] = [
        ModelEntry(id: "deepgram:nova-3", name: "Nova-3", provider: "deepgram", apiModel: "nova-3",
                   kind: .cloud, badge: nil, speed: 5, accuracy: 4),
        ModelEntry(id: "deepgram:nova-3-medical", name: "Nova-3 Medical", provider: "deepgram",
                   apiModel: "nova-3-medical", kind: .cloud, badge: "EN", speed: 5, accuracy: 4),
        ModelEntry(id: "elevenlabs:scribe_v2", name: "Scribe v2", provider: "elevenlabs",
                   apiModel: "scribe_v2", kind: .cloud, badge: nil, speed: 3, accuracy: 5),
        ModelEntry(id: "gemini-audio:gemini-3.8-flash", name: "Gemini 3.8 Flash", provider: "gemini",
                   apiModel: "gemini-3.8-flash", kind: .cloud, badge: "NEW", speed: 3, accuracy: 5),
        ModelEntry(id: "parakeet:v2", name: "Parakeet", provider: "nvidia",
                   apiModel: "parakeet-tdt-0.6b-v2", kind: .local, badge: "EN", speed: 5, accuracy: 4),
        ModelEntry(id: "parakeet:v3", name: "Parakeet Multilingual", provider: "nvidia",
                   apiModel: "parakeet-tdt-0.6b-v3", kind: .local, badge: nil, speed: 5, accuracy: 4),
        ModelEntry(id: "whisper:large-v3-turbo", name: "Whisper Large v3 Turbo", provider: "openai",
                   apiModel: "large-v3-turbo", kind: .local, badge: nil, speed: 3, accuracy: 4),
        ModelEntry(id: "whisper:large-v3", name: "Whisper Large v3", provider: "openai",
                   apiModel: "large-v3", kind: .local, badge: nil, speed: 2, accuracy: 4),
    ]

    public static let language: [ModelEntry] = [
        ModelEntry(id: "gemini:gemini-3.8-flash", name: "Gemini 3.8 Flash", provider: "gemini",
                   apiModel: "gemini-3.8-flash", kind: .cloud, badge: "NEW", speed: 4, accuracy: 5),
        ModelEntry(id: "anthropic:claude-haiku-5-5", name: "Claude Haiku 5.5", provider: "anthropic",
                   apiModel: "claude-haiku-5-5", kind: .cloud, badge: "NEW", speed: 4, accuracy: 5),
        ModelEntry(id: "anthropic:claude-sonnet-5-5", name: "Claude Sonnet 5.5", provider: "anthropic",
                   apiModel: "claude-sonnet-5-5", kind: .cloud, badge: "NEW", speed: 3, accuracy: 5),
    ]

    public static let defaultVoiceID = "deepgram:nova-3"

    public static func voiceModel(id: String) -> ModelEntry? { voice.first { $0.id == id } }
    public static func languageModel(id: String) -> ModelEntry? { language.first { $0.id == id } }

    /// The voice model id for a Whisper catalog model (`whisper-large-v3-turbo`
    /// becomes `whisper:large-v3-turbo`).
    public static func voiceID(forWhisper model: WhisperModel) -> String {
        "whisper:" + model.id.replacingOccurrences(of: "whisper-", with: "", options: .anchored)
    }

    /// The local Whisper model a voice id names.
    public static func whisperModel(forVoiceID id: String) -> WhisperModel? {
        guard id.hasPrefix("whisper:") else { return nil }
        let suffix = String(id.dropFirst("whisper:".count))
        return WhisperModelCatalog.model(forID: "whisper-" + suffix)
    }
}
