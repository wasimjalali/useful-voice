import Foundation
import Testing
@testable import UsefulVoiceCore

struct CleanupModelPolicyTests {
    private let gib: UInt64 = 1_073_741_824

    @Test func memoryRuleIsEightGibibytes() {
        #expect(!CleanupModelPolicy.memoryAllowsModel(physicalMemoryBytes: 0))
        #expect(!CleanupModelPolicy.memoryAllowsModel(physicalMemoryBytes: 4 * gib))
        #expect(!CleanupModelPolicy.memoryAllowsModel(physicalMemoryBytes: 8 * gib - 1))
        #expect(CleanupModelPolicy.memoryAllowsModel(physicalMemoryBytes: 8 * gib))
        #expect(CleanupModelPolicy.memoryAllowsModel(physicalMemoryBytes: 16 * gib))
    }

    @Test func defaults() {
        #expect(CleanupModelPolicy.defaultDeadline == .milliseconds(1500))
        #expect(CleanupModelPolicy.defaultIdleUnload == .seconds(60))
    }

    @Test func decisionOrderNamesTheFirstReason() {
        func decide(_ flag: Bool, _ installed: Bool, _ ram: UInt64, _ lang: String?) -> CleanupModelPolicy.Decision {
            CleanupModelPolicy.decide(flagOn: flag, modelInstalled: installed, physicalMemoryBytes: ram, language: lang)
        }
        #expect(decide(true, true, 16 * gib, "en") == .run)
        #expect(decide(true, true, 16 * gib, "EN-us") == .run)
        #expect(decide(false, false, 1 * gib, "de") == .skip(.flagOff))
        #expect(decide(true, false, 1 * gib, "de") == .skip(.modelNotDownloaded))
        #expect(decide(true, true, 4 * gib, "de") == .skip(.notEnoughMemory))
        #expect(decide(true, true, 16 * gib, "de") == .skip(.notEnglish))
        #expect(decide(true, true, 16 * gib, nil) == .skip(.notEnglish))
        #expect(decide(true, true, 16 * gib, "english") == .skip(.notEnglish))
    }

    @Test func flagIsOffByDefaultAndReadsEnvironmentThenDefaults() throws {
        let suite = "cleanup-flag-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!CleanupModelFlag.resolve(environment: [:], defaults: defaults))
        #expect(!CleanupModelFlag.resolve(environment: [:], defaults: nil))
        for on in ["1", "true", "TRUE", "yes", "on", " 1 "] {
            #expect(CleanupModelFlag.resolve(environment: ["UV_CLEANUP_MODEL": on], defaults: nil))
        }
        for off in ["0", "", "false", "no", "off", "2", "maybe"] {
            #expect(!CleanupModelFlag.resolve(environment: ["UV_CLEANUP_MODEL": off], defaults: nil))
        }
        defaults.set(true, forKey: CleanupModelFlag.defaultsKey)
        #expect(CleanupModelFlag.resolve(environment: [:], defaults: defaults))
        // The environment wins when it is set, in either direction.
        #expect(!CleanupModelFlag.resolve(environment: ["UV_CLEANUP_MODEL": "0"], defaults: defaults))
    }

    @Test func s1MiniPinsAndPromptFollowTheModelCard() {
        let m = S1MiniModel.model
        #expect(S1MiniModel.revision == "34add00a48a2e5d24e5a4ee5405a99620a3a240c")
        #expect(m.downloadURL.absoluteString
            == "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf")
        #expect(m.sha256 == "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634")
        #expect(m.expectedBytes == 484_219_808)
        #expect(m.fileName == "s1-mini-q4_k_m.gguf")
        #expect(m.displayName == "S1-mini by Superwhisper")
        #expect(S1MiniModel.credit == "S1-mini by Superwhisper")
        #expect(WhisperModelCatalog.model(forID: m.id) == nil)

        let line = "[Styling: semi-formal] [Structure: prose] [Context: general]"
        let prompt = S1MiniModel.prompt(controlLine: line, text: "so um hello")
        #expect(prompt == "<|im_start|>system\n"
            + "You are a text normalizer for speech-to-text transcripts. The input begins with a control line "
            + "specifying the styling, structure, and context settings; clean the transcript to match those "
            + "settings and output only the cleaned text.<|im_end|>\n"
            + "<|im_start|>user\n\(line)\nso um hello<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }
}
