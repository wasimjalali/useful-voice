import Foundation

/// A downloadable open-weight Whisper model, run locally by the local engine.
///
/// Descriptors are data, not code paths: adding a model is a catalog entry, so
/// machines with more memory can pick heavier weights and nothing is sized to
/// one particular Mac. The catalog deliberately offers the fp16 weights — the
/// quantized variants are a future catalog entry, not a different feature.
public struct WhisperModel: Identifiable, Hashable, Sendable {
    /// Stable identifier persisted in settings and shown in diagnostics.
    public let id: String
    /// Human-facing name, e.g. "Whisper Large v3 Turbo".
    public let displayName: String
    /// File name in the Hugging Face repo and on disk after download.
    public let fileName: String
    /// Direct download URL (HF `resolve` endpoint on the ggerganov/whisper.cpp repo).
    public let downloadURL: URL
    /// Exact size in bytes the completed download must have.
    public let expectedBytes: Int64
    /// SHA-256 of the file, from the repo's LFS metadata. Verified after download
    /// so a truncated or corrupted file can never be loaded as a model.
    public let sha256: String
    /// Rough parameter count, for display.
    public let parameterCount: String
    /// SPDX-style license identifier of the underlying OpenAI weights.
    public let licenseName: String
    /// Link to the license text.
    public let licenseURL: URL
    /// Link to the upstream model card (provenance).
    public let provenanceURL: URL
    /// Languages the model was trained to transcribe, for display.
    public let languageCount: Int
    /// The model most users should pick first.
    public let isRecommended: Bool
    /// A practical caveat shown under the model name, or nil.
    public let note: String?

    public init(id: String, displayName: String, fileName: String, downloadURL: URL,
                expectedBytes: Int64, sha256: String, parameterCount: String,
                licenseName: String, licenseURL: URL, provenanceURL: URL,
                languageCount: Int, isRecommended: Bool, note: String?) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
        self.parameterCount = parameterCount
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.provenanceURL = provenanceURL
        self.languageCount = languageCount
        self.isRecommended = isRecommended
        self.note = note
    }

    /// On-disk size formatted for display.
    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }
}

/// The models the app can download and run.
///
/// Weights come from the official whisper.cpp model repo
/// (`huggingface.co/ggerganov/whisper.cpp`). The repo ships `.bin` (ggml) files —
/// not `.gguf` — and whisper.cpp loads them natively.
public enum WhisperModelCatalog {
    /// OpenAI `whisper-large-v3-turbo` (809M params, MIT). The default: roughly
    /// 4x faster than large-v3 for a small quality trade-off, and the right size
    /// for 8 GB Macs.
    public static let largeV3Turbo = WhisperModel(
        id: "whisper-large-v3-turbo",
        displayName: "Whisper Large v3 Turbo",
        fileName: "ggml-large-v3-turbo.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
        expectedBytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        parameterCount: "809M",
        licenseName: "MIT",
        licenseURL: URL(string: "https://opensource.org/license/mit")!,
        provenanceURL: URL(string: "https://huggingface.co/openai/whisper-large-v3-turbo")!,
        languageCount: 99,
        isRecommended: true,
        note: nil
    )

    /// OpenAI `whisper-large-v3` (1.54B params, Apache-2.0). Highest accuracy;
    /// noticeably slower and needs about twice the memory of turbo.
    public static let largeV3 = WhisperModel(
        id: "whisper-large-v3",
        displayName: "Whisper Large v3",
        fileName: "ggml-large-v3.bin",
        downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
        expectedBytes: 3_095_033_483,
        sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        parameterCount: "1.54B",
        licenseName: "Apache-2.0",
        licenseURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!,
        provenanceURL: URL(string: "https://huggingface.co/openai/whisper-large-v3")!,
        languageCount: 99,
        isRecommended: false,
        note: "Slower and needs more memory. On 8 GB Macs, prefer Turbo"
    )

    /// Every offered model, in display order (recommended first).
    public static let all: [WhisperModel] = [largeV3Turbo, largeV3]

    /// The model a fresh install should default to.
    public static let `default` = largeV3Turbo

    public static func model(forID id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
