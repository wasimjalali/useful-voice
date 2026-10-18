import Foundation

/// NVIDIA Parakeet TDT 0.6B, run on this Mac. v2 is English only, v3 speaks 25 European languages.
public enum ParakeetVersion: String, CaseIterable, Sendable {
    case v2
    case v3

    /// The id the model catalog and the saved voice-model setting use.
    public var catalogID: String { "parakeet:\(rawValue)" }

    public init?(catalogID: String) {
        guard catalogID.hasPrefix("parakeet:") else { return nil }
        self.init(rawValue: String(catalogID.dropFirst("parakeet:".count)))
    }
}

public enum ParakeetModelState: Equatable, Sendable {
    case notDownloaded
    /// `progress` runs 0...1 when the download reports it, nil while it can't.
    case downloading(progress: Double?)
    case ready(sizeBytes: Int64?)
    case failed(String)
}

/// Downloads, deletes and runs the Parakeet models.
///
/// CONTRACT STUB: the Settings UI and provider selection are written against this API while
/// the FluidAudio implementation is built separately. Keep these signatures.
@MainActor
public final class ParakeetModelManager: ObservableObject {
    @Published public private(set) var states: [ParakeetVersion: ParakeetModelState]

    public init() {
        states = Dictionary(uniqueKeysWithValues: ParakeetVersion.allCases.map { ($0, .notDownloaded) })
    }

    public func state(of version: ParakeetVersion) -> ParakeetModelState {
        states[version] ?? .notDownloaded
    }

    /// The version kept loaded in memory (the selected voice model), nil when none is.
    public var pinned: ParakeetVersion?

    /// Loads `version` ahead of the first dictation. A no-op when it is loaded or not downloaded.
    public func preload(_ version: ParakeetVersion) {}

    public func download(_ version: ParakeetVersion) {}

    public func cancelDownload(_ version: ParakeetVersion) {}

    public func delete(_ version: ParakeetVersion) throws {}

    /// A provider for `version`. When the model isn't ready its `transcribe` throws
    /// `ProviderError.notConfigured` with a message that says to download it in Settings.
    public func provider(for version: ParakeetVersion) -> TranscriptionProvider {
        UnavailableProvider(
            name: "Parakeet (local)",
            message: "Parakeet is not downloaded. Download it in Settings to use it.")
    }
}
