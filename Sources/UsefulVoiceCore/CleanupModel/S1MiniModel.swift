import Foundation

/// S1-mini by Superwhisper (Apache 2.0 plus one term: it must always be credited as
/// "S1-mini" by "Superwhisper", with that exact capitalisation). A Qwen3-0.6B fine-tune that
/// resolves self-corrections and formats numbers, dates and emails.
/// `windows/src/core/formatting/s1MiniModel.ts` mirrors the pins and the prompt.
///
/// The weights are pinned to one Hugging Face revision and one SHA-256, and download through
/// the existing `ModelDownloader` into the same directory as the Whisper weights. The
/// descriptor is a `WhisperModel` only because that is the downloader's descriptor type; it
/// is not in `WhisperModelCatalog`, so no picker lists it.
public enum S1MiniModel {
    public static let credit = "S1-mini by Superwhisper"

    /// superwhisper/s1-mini-GGUF, the commit the model card and the eval were read at.
    public static let revision = "34add00a48a2e5d24e5a4ee5405a99620a3a240c"

    public static let model = WhisperModel(
        id: "s1-mini-q4_k_m",
        displayName: credit,
        fileName: "s1-mini-q4_k_m.gguf",
        downloadURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/\(revision)/s1-mini-q4_k_m.gguf")!,
        expectedBytes: 484_219_808,
        sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
        parameterCount: "0.6B",
        licenseName: "Apache-2.0 with an additional naming term",
        licenseURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/blob/\(revision)/LICENSE")!,
        provenanceURL: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/tree/\(revision)")!,
        languageCount: 1,
        isRecommended: false,
        note: "English only"
    )

    /// The raw prompt the model card documents for runtimes that do not apply the embedded
    /// chat template. The assistant turn opens with an empty think block (two newlines
    /// inside it, two after), which is what `enable_thinking: false` renders: S1-mini was
    /// trained with thinking off. The system prompt is `CleanupControlLine.systemPrompt`,
    /// verbatim; the user message is the control line, a newline and the transcript.
    public static func prompt(controlLine: String, text: String) -> String {
        "<|im_start|>system\n\(CleanupControlLine.systemPrompt)<|im_end|>\n"
            + "<|im_start|>user\n\(controlLine)\n\(text)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// The control-line style for the user's chosen app style, for `CleanupControlLine`:
    /// Formal is formal, Casual is semi-casual and Very casual is casual. No choice (nil)
    /// leaves the card's default, semi-formal. The eval found that picking casual by app
    /// category alone hurt restraint, so only an explicit choice moves off the default.
    public static func controlStyle(for style: FormattingStyle?) -> String? {
        switch style {
        case .formal: return "formal"
        case .casual: return "semi-casual"
        case .veryCasual: return "casual"
        case nil: return nil
        }
    }
}
