import Foundation

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case delivering
    case error(DictationError)
}

/// The dictation pipeline state machine. Spec section 4 data flow and
/// section 5 error rules. UI-agnostic: state changes surface via callback.
@MainActor
public final class DictationController {
    public private(set) var state: DictationState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((DictationState) -> Void)?
    /// What a dictation ended with. `delivered` fires from the delivery
    /// completion and `cancelled` from `cancel()`, each exactly once and BEFORE
    /// the state returns to `.idle`, so a listener that renders "done" has
    /// already seen the outcome.
    public var onOutcome: ((DictationOutcome) -> Void)?

    private let recorder: AudioRecording
    private let providers: () -> [TranscriptionProvider]
    private let store: RecordingStore
    private let hint: () -> TranscriptionHint
    private(set) var recordingsToKeep: Int
    /// Delivers the final text and calls the completion once delivery has fully
    /// settled (paste verified, clipboard restored, or the copy written). The
    /// controller stays in .delivering until then, so the busy mutex covers the
    /// whole delivery window and a re-entrant tap can't start a new recording
    /// mid-paste. Only the first call of a completion counts.
    private let deliver: (String, DeliveryMode, @escaping (DeliveryReport) -> Void) -> Void
    private let record: (DictationRecord) -> Void
    /// Where a detected-language anomaly is reported. Injected so tests do not append
    /// to the real install's log.
    private let diagnostics: Diagnostics
    private let format: ((String, FormattingContext) async throws -> FormattingResult)?
    private let rawTransform: ((String, FormattingContext) async -> FormattingResult)?
    private let context: () -> FormattingContext
    private let suggestTerms: ([String]) -> Void
    private let formatterUnavailable: () -> Void
    private let now: () -> Date
    private let isSecureInputActive: () -> Bool
    /// The app in front. Read when a hotkey dictation starts (the paste target)
    /// and again at delivery, so text is pasted only where it was dictated for.
    private let frontmostApp: () -> FrontmostApp?
    private var pendingRawMode = false
    /// Where the dictation now in flight was started, and the app it will paste
    /// into. Written once, when recording starts, and never by the stop toggle,
    /// the auto-stop or Esc. The stop path copies them out synchronously, and
    /// retryLast() does not read them at all.
    private var activeSource: DictationSource = .hotkey
    private var activeAppName: String?
    private var activeApp: FrontmostApp?
    /// Identifies the delivery in flight. A completion acts only if it still
    /// holds the current token, so a second call, or a late one from an earlier
    /// dictation, cannot fire an outcome or end the next dictation's delivery.
    private var deliveryToken = 0
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
                deliver: @escaping (String, DeliveryMode, @escaping (DeliveryReport) -> Void) -> Void,
                record: @escaping (DictationRecord) -> Void = { _ in },
                diagnostics: Diagnostics = .shared,
                format: ((String, FormattingContext) async throws -> FormattingResult)? = nil,
                rawTransform: ((String, FormattingContext) async -> FormattingResult)? = nil,
                context: @escaping () -> FormattingContext = {
                    FormattingContext(appBundleID: nil, dictionaryWords: [],
                                      language: .auto)
                },
                suggestTerms: @escaping ([String]) -> Void = { _ in },
                formatterUnavailable: @escaping () -> Void = {},
                now: @escaping () -> Date = { Date() },
                isSecureInputActive: @escaping () -> Bool = { false },
                frontmostApp: @escaping () -> FrontmostApp? = { nil }) {
        self.recorder = recorder
        self.providers = providers
        self.store = store
        self.hint = hint
        self.recordingsToKeep = recordingsToKeep
        self.deliver = deliver
        self.record = record
        self.diagnostics = diagnostics
        self.format = format
        self.rawTransform = rawTransform
        self.context = context
        self.suggestTerms = suggestTerms
        self.formatterUnavailable = formatterUnavailable
        self.now = now
        self.isSecureInputActive = isSecureInputActive
        self.frontmostApp = frontmostApp
        // The recorder calls this on the main thread and only for its live
        // session (see AudioRecording.onAutoStop), so it acts at once: no extra
        // hop in which a stale call could end the NEXT recording. The state check
        // covers a call that lands after a manual stop already advanced the state.
        self.recorder.onAutoStop = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording else { return }
                self.toggle()
            }
        }
    }

    /// Tap of the hotkey or the window's mic button: start when idle, stop+process
    /// when recording. Ignored while a previous dictation is still processing.
    ///
    /// `source` matters only when this call STARTS a recording: it is kept for
    /// that dictation (a window start is copied, a hotkey start is pasted). A
    /// stop toggle ignores it, whichever source sends it.
    public func toggle(rawMode: Bool = false, source: DictationSource = .hotkey) {
        switch state {
        case .idle, .error:
            startRecording(source: source)
        case .recording:
            pendingRawMode = rawMode
            let mode: DeliveryMode = activeSource == .window ? .copy : .paste
            let appName = activeAppName
            let startApp = activeApp
            state = .transcribing   // synchronous: a racing toggle now sees .transcribing and is ignored
            processingTask = Task { await stopAndProcess(mode: mode, appName: appName, startApp: startApp) }
        case .transcribing, .delivering:
            break // busy; ignore to avoid double-processing
        }
    }

    /// Test helper / programmatic variant that awaits the processing.
    public func toggleAndWait() async {
        toggle()
        await processingTask?.value
    }

    /// Test helper: awaits whatever processing is in flight.
    func awaitProcessing() async {
        await processingTask?.value
    }

    /// Re-runs the provider chain on the audio retained from the last failure.
    /// Spec section 5: one-click retry, no re-recording. Ignored when busy or
    /// when there is nothing to retry. The result is always saved and copied, never
    /// pasted: it belongs to an old recording, whatever started it.
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
                          presetContext: savedContext, mode: .copy, appName: nil)
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
        onOutcome?(.cancelled)
        state = .idle
    }

    /// Forgets the retained audio of the last failed dictation (its recording was
    /// deleted), so Retry is no longer offered. Ignored while a dictation is in
    /// flight, which owns that audio.
    public func discardRetainedAudio() {
        switch state {
        case .recording, .transcribing, .delivering: return
        case .idle, .error: break
        }
        lastFailedAudio = nil
        lastFailedContext = nil
    }

    public func updateRecordingSettings(silenceTimeout: TimeInterval, recordingsToKeep: Int) {
        recorder.updateSilenceTimeout(silenceTimeout)
        self.recordingsToKeep = recordingsToKeep
    }

    private func startRecording(source: DictationSource) {
        // A password field is focused: refuse rather than record and paste into
        // it. Spec section 5. IsSecureEventInputEnabled is injected from the app.
        guard !isSecureInputActive() else {
            state = .error(DictationError(
                kind: .secureField,
                message: "Secure field active. Dictation is off here."))
            return
        }
        let url = store.newRecordingURL()
        do {
            try recorder.start(to: url)
            recordingStartedAt = now()
            // Captured now, for this dictation only. Only a hotkey dictation
            // pastes, so only it needs the app it will paste into.
            activeSource = source
            let front = source == .hotkey ? frontmostApp() : nil
            activeApp = front
            activeAppName = front?.name
            state = .recording
        } catch {
            state = .error(DictationError.startFailure(error))
        }
    }

    private func stopAndProcess(mode: DeliveryMode, appName: String?,
                                 startApp: FrontmostApp?) async {
        let audioURL: URL
        do {
            audioURL = try recorder.stop()
        } catch {
            // The raw intent dies with this dictation: a stale flag would be
            // consumed by retryLast(), the one path that reaches process()
            // without a fresh toggle(rawMode:) write.
            pendingRawMode = false
            state = .error(DictationError(
                kind: .stopFailed,
                message: "Couldn't stop recording: \(error.localizedDescription)"))
            return
        }
        // The user was silent the whole time: never transcribe it. A silent clip
        // makes Whisper echo its prompt bias (the whole dictionary) back as a
        // fake transcript, which then gets formatted, pasted and left on the
        // clipboard. Discard here so nothing is uploaded, billed or delivered.
        guard recorder.didCaptureSpeech else {
            pendingRawMode = false   // the raw intent dies with this dictation
            try? store.prune(keep: recordingsToKeep)
            state = .error(Self.noSpeech)
            return
        }
        // Wall-clock recording length, used as the duration when the provider
        // response omits one.
        let measuredDuration = recordingStartedAt.map { max(0, now().timeIntervalSince($0)) }
        await process(audioURL: audioURL, measuredDuration: measuredDuration,
                      mode: mode, appName: appName, startApp: startApp)
    }

    private static let noSpeech = DictationError(
        kind: .noSpeech, message: "No speech detected.")

    /// Transcribes, formats, records, and delivers a recorded audio file. Shared
    /// by the normal stop path and retryLast(). state is already .transcribing.
    /// The formatting context is captured up front, while the user is still in
    /// the app they dictated into; a retry reuses the context captured when the
    /// failed dictation was recorded (presetContext).
    private func process(audioURL: URL, measuredDuration: Double?,
                         presetContext: FormattingContext? = nil,
                         mode deliveryMode: DeliveryMode,
                         appName: String?,
                         startApp: FrontmostApp? = nil) async {
        // Raw mode is consumed exactly once, at the top: a failed or empty
        // transcript used to leave the flag set and leak raw mode into the next
        // dictation.
        let rawMode = pendingRawMode
        pendingRawMode = false

        let formattingContext = presetContext ?? context()
        // One hint for the whole chain: `hint()` reads live settings, so
        // calling it per provider could hand each provider a different request
        // if the pin changed mid-chain. On retry the FormattingContext captured
        // at record time carries both the pin and the bias list, so the request
        // is re-sent verbatim — a retry must ask for what the original
        // dictation asked, not whatever is pinned now (the same "format for
        // the app the user dictated into" invariant as presetContext).
        let capturedHint = presetContext.map {
            TranscriptionHint(languagePin: $0.language,
                              dictionaryWords: $0.dictionaryWords)
        } ?? hint()
        let chain = providers()
        guard !chain.isEmpty else {
            state = .error(DictationError(
                kind: .noProvider,
                message: "No transcription provider configured. Open Settings.",
                fix: .openEngineSettings))
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
            state = .error(DictationError(
                kind: .tooShort, message: "Recording was too short."))
            return
        }

        var transcript: Transcript?
        var usedProvider: String?
        var lastError: Error?
        for provider in chain {
            do {
                transcript = try await provider.transcribe(audio: audioURL,
                                                            hint: capturedHint)
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
            // Retry is offered only where it can help (see DictationError.fix);
            // the audio is retained for every failure, so canRetry stays true.
            let kind = DictationError.kind(forTranscriptionFailure: lastError)
            state = .error(DictationError(
                kind: kind,
                message: "Transcription failed: \(detail)",
                fix: DictationError.fix(forTranscriptionFailure: kind)))
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
            state = .error(Self.noSpeech)
            return
        }

        // What Deepgram detected decides the processing language — validated
        // through the catalogue so a returned `de-CH` keeps its region while
        // `de-DE` scopes as `de`. History stores the raw code, trimmed and
        // stripped to tag characters so a malformed value cannot forge a
        // shareable log line or a strange history row: an unknown detection is
        // processed as `auto` (permissive rather than wrong-language) but
        // recorded as reported, and is never sent back to the provider.
        let rawDetected = transcript.sanitizedDetectedLanguage
        let effectivePin = rawDetected.map { LanguagePin(detectedCode: $0) }
            ?? formattingContext.language
        // App identity, snippets, replacement rules and dictionary context stay
        // the values captured at recording time; only the language is resolved.
        let effectiveContext = FormattingContext(
            appBundleID: formattingContext.appBundleID,
            dictionaryWords: formattingContext.dictionaryWords,
            language: effectivePin,
            snippets: formattingContext.snippets,
            replacementRules: formattingContext.replacementRules)

        // Raw transcript to the sidecar BEFORE formatting (never-lose).
        try? store.saveTranscript(transcript.text, for: audioURL)

        var finalText = transcript.text
        var mode: FormattingMode = .raw
        var replacementRuleIDs: [UUID] = []
        var memoryHitIDs: [UUID] = []
        var snippetIDs: [UUID] = []
        if rawMode {
            if let rawTransform {
                let result = await rawTransform(transcript.text, effectiveContext)
                finalText = result.text
                mode = .raw
                replacementRuleIDs = result.replacementRuleIDs
                memoryHitIDs = result.memoryHitIDs
                snippetIDs = result.snippetIDs
            }
        } else if let format {
            do {
                let result = try await format(transcript.text, effectiveContext)
                finalText = result.text
                mode = result.mode
                replacementRuleIDs = result.replacementRuleIDs
                memoryHitIDs = result.memoryHitIDs
                snippetIDs = result.snippetIDs
                if !result.newTerms.isEmpty { suggestTerms(result.newTerms) }
            } catch {
                formatterUnavailable()   // keep raw finalText; mode stays .raw
                if let rawTransform {
                    let result = await rawTransform(transcript.text, effectiveContext)
                    finalText = result.text
                    replacementRuleIDs = result.replacementRuleIDs
                    memoryHitIDs = result.memoryHitIDs
                    snippetIDs = result.snippetIDs
                }
            }
        }

        // The Nova-3 fallback check is Deepgram-specific: a local engine's
        // codes (whisper's "yue") are not Deepgram detections.
        if usedProvider != LocalWhisperProvider.providerName {
            recordDetectedLanguageCheck(rawDetected)
        }

        record(DictationRecord(
            text: finalText,
            createdAt: now(),
            // The raw detected code when present, else the requested pin (which
            // may itself be "auto"): history records what was reported, never a
            // re-resolved value.
            language: rawDetected ?? formattingContext.language.rawValue,
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
        //
        // The token is taken before deliver() runs because a completion may fire
        // synchronously. A completion acts once: the outcome is published first,
        // then the state returns to .idle.
        deliveryToken += 1
        let token = deliveryToken
        let words = DictationOutcome.wordCount(of: finalText)
        // A hotkey dictation pastes only into the app it started in. If the user
        // has since moved (or stopped it from Useful Voice's own window after
        // starting elsewhere), the paste would land in the wrong place, so deliver
        // by copy and say so. Started and still in Useful Voice (a note) pastes.
        var deliverMode = deliveryMode
        var pasteRedirected = false
        if deliverMode == .paste, let now = frontmostApp(),
           now.id != startApp?.id {
            deliverMode = .copy
            pasteRedirected = true
        }
        deliver(finalText, deliverMode) { [weak self] report in
            guard let self, self.state == .delivering,
                  self.deliveryToken == token else { return }
            self.deliveryToken += 1
            switch report {
            case .success(let result):
                let reported: DeliveryResult =
                    pasteRedirected && result == .copied ? .copiedNotPasted : result
                self.onOutcome?(.delivered(words: words, mode: reported, appName: appName))
                self.state = .idle
            case .failure:
                self.state = .error(DictationError(
                    kind: .deliveryFailed,
                    message: "Couldn't copy the text. It's saved in Useful Voice."))
            }
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
        case .outOfCredits:
            return "Your Deepgram account is out of credits. Add credits, then try again."
        case .badResponse: return "unreadable provider response"
        case .notConfigured(let what): return what
        case .timedOut: return "timed out"
        case .transport(let urlError): return urlError.localizedDescription
        case .engineFailed(let detail): return detail
        }
    }

    /// Record when the provider left Nova-3 to transcribe, which silently disables the
    /// personal dictionary.
    ///
    /// `keyterm` is documented as "Only compatible with Nova-3", and Deepgram falls
    /// back down a model chain when a requested or detected language is unavailable on
    /// the requested model. Detection is restricted to languages Nova-3 speaks
    /// natively, so this should be unreachable — which is exactly why it is worth
    /// reporting if it ever happens. The alternative symptom is a transcript where the
    /// user's own terminology is misspelled, and that reads as a dictionary bug rather
    /// than a model one, so nobody would look here.
    ///
    /// Deliberately a log line rather than an alert: it may be a single unusual
    /// utterance, and interrupting dictation to say so would be worse than the problem.
    private func recordDetectedLanguageCheck(_ detected: String?) {
        guard let detected, !detected.isEmpty else { return }
        guard !DeepgramLanguageCatalog.detectionStayedOnNova3(detected) else { return }
        diagnostics.record(
            level: .warning,
            category: "dictation",
            message: "detected language '\(detected)' is outside Nova-3, so the provider "
                + "fell back to a lower model and dictionary terms were not applied"
        )
    }
}
