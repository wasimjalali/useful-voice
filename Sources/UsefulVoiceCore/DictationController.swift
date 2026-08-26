import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case delivering
    case error(String)
}

/// The dictation pipeline state machine. Spec section 4 data flow and
/// section 5 error rules. UI-agnostic: state changes surface via callback.
@MainActor
public final class DictationController {
    public private(set) var state: DictationState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((DictationState) -> Void)?

    private let recorder: AudioRecording
    private let providers: () -> [TranscriptionProvider]
    private let store: RecordingStore
    private let hint: () -> TranscriptionHint
    private(set) var recordingsToKeep: Int
    /// Delivers the final text and calls the completion once delivery has fully
    /// settled (paste verified, clipboard restored). The controller stays in
    /// .delivering until then, so the busy mutex covers the whole delivery
    /// window and a re-entrant tap can't start a new recording mid-paste.
    private let deliver: (String, @escaping () -> Void) -> Void
    private let record: (DictationRecord) -> Void
    private let format: ((String, FormattingContext) async throws -> FormattingResult)?
    private let rawTransform: ((String, FormattingContext) async -> FormattingResult)?
    private let context: () -> FormattingContext
    private let suggestTerms: ([String]) -> Void
    private let formatterUnavailable: () -> Void
    private let now: () -> Date
    private let isSecureInputActive: () -> Bool
    private var pendingRawMode = false
    private var processingTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    /// Audio from the last dictation whose providers all failed. Spec section 5:
    /// the recording is kept so the user can retry without re-recording.
    private var lastFailedAudio: URL?
    /// Formatting context captured when that dictation was recorded. Retry must
    /// format for the app the user dictated into, not for whatever is frontmost
    /// when they click Retry (usually Useful Voice itself).
    private var lastFailedContext: FormattingContext?

    /// True when a failed dictation can be retried on its retained audio.
    public var canRetry: Bool { lastFailedAudio != nil }

    public init(recorder: AudioRecording,
                providers: @escaping () -> [TranscriptionProvider],
                store: RecordingStore,
                hint: @escaping () -> TranscriptionHint,
                recordingsToKeep: Int,
                deliver: @escaping (String, @escaping () -> Void) -> Void,
                record: @escaping (DictationRecord) -> Void = { _ in },
                format: ((String, FormattingContext) async throws -> FormattingResult)? = nil,
                rawTransform: ((String, FormattingContext) async -> FormattingResult)? = nil,
                context: @escaping () -> FormattingContext = {
                    FormattingContext(appBundleID: nil, dictionaryWords: [],
                                      language: .auto)
                },
                suggestTerms: @escaping ([String]) -> Void = { _ in },
                formatterUnavailable: @escaping () -> Void = {},
                now: @escaping () -> Date = { Date() },
                isSecureInputActive: @escaping () -> Bool = { false }) {
        self.recorder = recorder
        self.providers = providers
        self.store = store
        self.hint = hint
        self.recordingsToKeep = recordingsToKeep
        self.deliver = deliver
        self.record = record
        self.format = format
        self.rawTransform = rawTransform
        self.context = context
        self.suggestTerms = suggestTerms
        self.formatterUnavailable = formatterUnavailable
        self.now = now
        self.isSecureInputActive = isSecureInputActive
        self.recorder.onAutoStop = { [weak self] in
            DispatchQueue.main.async {
                // Only the recording we own may be auto-stopped. A late auto-stop
                // dispatched after a manual stop already advanced the state must
                // not toggle (worst case, start a fresh recording from .idle).
                guard self?.state == .recording else { return }
                self?.toggle()
            }
        }
    }

    /// Tap of the hotkey: start when idle, stop+process when recording.
    /// Ignored while a previous dictation is still processing.
    public func toggle(rawMode: Bool = false) {
        switch state {
        case .idle, .error:
            startRecording()
        case .recording:
            pendingRawMode = rawMode
            state = .transcribing   // synchronous: a racing toggle now sees .transcribing and is ignored
            processingTask = Task { await stopAndProcess() }
        case .transcribing, .delivering:
            break // busy; ignore to avoid double-processing
        }
    }

    /// Test helper / programmatic variant that awaits the processing.
    public func toggleAndWait() async {
        toggle()
        await processingTask?.value
    }

    /// Re-runs the provider chain on the audio retained from the last failure.
    /// Spec section 5: one-click retry, no re-recording. Ignored when busy or
    /// when there is nothing to retry.
    public func retryLast() {
        guard let url = lastFailedAudio else { return }
        switch state {
        case .recording, .transcribing, .delivering: return
        case .idle, .error: break
        }
        state = .transcribing
        let savedContext = lastFailedContext
        processingTask = Task {
            await process(audioURL: url, measuredDuration: nil,
                          presetContext: savedContext)
        }
    }

    /// Test helper that awaits the retry.
    public func retryLastAndWait() async {
        retryLast()
        await processingTask?.value
    }

    public func cancel() {
        guard state == .recording else { return }
        recorder.cancel()
        state = .idle
    }

    public func updateRecordingSettings(silenceTimeout: TimeInterval, recordingsToKeep: Int) {
        recorder.updateSilenceTimeout(silenceTimeout)
        self.recordingsToKeep = recordingsToKeep
    }

    private func startRecording() {
        // A password field is focused: refuse rather than record and paste into
        // it. Spec section 5. IsSecureEventInputEnabled is injected from the app.
        guard !isSecureInputActive() else {
            state = .error("Secure field active. Dictation is off here.")
            return
        }
        let url = store.newRecordingURL()
        do {
            try recorder.start(to: url)
            recordingStartedAt = now()
            state = .recording
        } catch {
            state = .error("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func stopAndProcess() async {
        let audioURL: URL
        do {
            audioURL = try recorder.stop()
        } catch {
            state = .error("Couldn't stop recording: \(error.localizedDescription)")
            return
        }
        // The user was silent the whole time: never transcribe it. A silent clip
        // makes Whisper echo its prompt bias (the whole dictionary) back as a
        // fake transcript, which then gets formatted, pasted and left on the
        // clipboard. Discard here so nothing is uploaded, billed or delivered.
        guard recorder.didCaptureSpeech else {
            try? store.prune(keep: recordingsToKeep)
            state = .error("No speech detected.")
            return
        }
        // Wall-clock recording length, used as the duration when the provider
        // response omits one.
        let measuredDuration = recordingStartedAt.map { max(0, now().timeIntervalSince($0)) }
        await process(audioURL: audioURL, measuredDuration: measuredDuration)
    }

    /// Transcribes, formats, records, and delivers a recorded audio file. Shared
    /// by the normal stop path and retryLast(). state is already .transcribing.
    /// The formatting context is captured up front, while the user is still in
    /// the app they dictated into; a retry reuses the context captured when the
    /// failed dictation was recorded (presetContext).
    private func process(audioURL: URL, measuredDuration: Double?,
                         presetContext: FormattingContext? = nil) async {
        let formattingContext = presetContext ?? context()
        let chain = providers()
        guard !chain.isEmpty else {
            state = .error("No transcription provider configured. Open Settings.")
            return
        }

        // A header-only or near-empty WAV (an instant tap, a denied mic, a capture
        // race) is rejected by the provider with a 400 that reads as a mysterious
        // provider error. Catch it before the upload and the bill, and say so
        // plainly. 16kHz mono 16-bit: ~100ms of audio is 3200 bytes on top of the
        // 44-byte header.
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let audioBytes = (attrs?[.size] as? Int) ?? 0
        guard audioBytes >= 44 + 3200 else {
            try? store.prune(keep: recordingsToKeep)
            state = .error("Recording was too short.")
            return
        }

        var transcript: Transcript?
        var usedProvider: String?
        var lastError: Error?
        for provider in chain {
            do {
                transcript = try await provider.transcribe(audio: audioURL,
                                                            hint: hint())
                usedProvider = provider.name
                break
            } catch {
                lastError = error
            }
        }

        guard let transcript else {
            // Keep the audio (and its context) so the user can retry without
            // re-recording.
            lastFailedAudio = audioURL
            lastFailedContext = formattingContext
            let detail = (lastError as? ProviderError).map(Self.describe)
                ?? lastError?.localizedDescription ?? "unknown error"
            state = .error("Transcription failed: \(detail)")
            return
        }
        // Transcription succeeded: any earlier failure is resolved.
        lastFailedAudio = nil
        lastFailedContext = nil

        // No speech in the whole recording: discard with a notice. Nothing is
        // formatted, recorded, or delivered (an empty deliver would also wipe the
        // clipboard). Spec section 5. The STT call was already billed by the API.
        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? store.prune(keep: recordingsToKeep)
            state = .error("No speech detected.")
            return
        }

        // Raw transcript to the sidecar BEFORE formatting (never-lose).
        try? store.saveTranscript(transcript.text, for: audioURL)

        var finalText = transcript.text
        var mode: FormattingMode = .raw
        var replacementRuleIDs: [UUID] = []
        var memoryHitIDs: [UUID] = []
        var snippetIDs: [UUID] = []
        if pendingRawMode {
            if let rawTransform {
                let result = await rawTransform(transcript.text, formattingContext)
                finalText = result.text
                mode = .raw
                replacementRuleIDs = result.replacementRuleIDs
                memoryHitIDs = result.memoryHitIDs
                snippetIDs = result.snippetIDs
            }
        } else if let format {
            do {
                let result = try await format(transcript.text, formattingContext)
                finalText = result.text
                mode = result.mode
                replacementRuleIDs = result.replacementRuleIDs
                memoryHitIDs = result.memoryHitIDs
                snippetIDs = result.snippetIDs
                if !result.newTerms.isEmpty { suggestTerms(result.newTerms) }
            } catch {
                formatterUnavailable()   // keep raw finalText; mode stays .raw
                if let rawTransform {
                    let result = await rawTransform(transcript.text, formattingContext)
                    finalText = result.text
                    replacementRuleIDs = result.replacementRuleIDs
                    memoryHitIDs = result.memoryHitIDs
                    snippetIDs = result.snippetIDs
                }
            }
        }
        pendingRawMode = false

        record(DictationRecord(
            text: finalText,
            createdAt: now(),
            language: transcript.detectedLanguage,
            provider: usedProvider ?? "unknown",
            durationSeconds: transcript.durationSeconds ?? measuredDuration,
            mode: mode,
            rawText: transcript.text,
            memoryHitIDs: memoryHitIDs.isEmpty ? nil : memoryHitIDs,
            replacementRuleIDs: replacementRuleIDs.isEmpty ? nil : replacementRuleIDs,
            snippetIDs: snippetIDs.isEmpty ? nil : snippetIDs,
            audioPath: audioURL.path))

        state = .delivering
        try? store.prune(keep: recordingsToKeep)
        // Hold .delivering until delivery actually settles; the busy mutex then
        // spans the whole paste/verify/restore window instead of dropping to
        // .idle the instant the synthetic paste is posted.
        deliver(finalText) { [weak self] in
            guard let self else { return }
            self.state = .idle
        }
    }

    private static func describe(_ error: ProviderError) -> String {
        switch error {
        case .http(let status, let body):
            // Surface the provider's own error text so a genuine failure (e.g.
            // 429 insufficient_quota, 400 "audio file is too short") is
            // distinguishable from an opaque "HTTP 400". Without this, every
            // cause collapsed to the same message and couldn't be diagnosed.
            let detail = ProviderHealthCheck.sanitize(
                body.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(200)
            return detail.isEmpty ? "HTTP \(status) from provider"
                                  : "HTTP \(status): \(detail)"
        case .badResponse: return "unreadable provider response"
        case .notConfigured(let what): return what
        case .timedOut: return "timed out"
        case .transport(let urlError): return urlError.localizedDescription
        }
    }
}
