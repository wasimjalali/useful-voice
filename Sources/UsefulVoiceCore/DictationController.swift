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
        didSet {
            // The target (with its window title and page address) is for the dictation
            // in flight only: once it settles, it is dropped.
            switch state {
            case .idle, .error: activeTarget = nil; activePress = nil; endCleanupModelDictation()
            case .recording, .transcribing, .delivering: break
            }
            onStateChange?(state)
        }
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
    /// Used only when `focusTarget` is not given.
    private let frontmostApp: () -> FrontmostApp?
    /// What has focus now, in full (app, process, window, element, browser URL).
    /// Read at the hotkey press to lock the target, and at delivery to check it.
    private let focusTarget: (() -> DeliveryTarget?)?
    /// Whether the target's process still exists.
    private let isTargetRunning: (DeliveryTarget) -> Bool
    /// Brings the target app, window and element back to the front. Returns
    /// whether the app reports it came forward; the controller then checks the
    /// focus again itself, so a reported success is never trusted on its own.
    private let reactivate: (DeliveryTarget) async -> Bool
    /// The apps the user switched to typing. Read at delivery, so text with a line
    /// break for one of them is copied without locking on (or reactivating) the
    /// target first.
    private let typeOutApps: () -> [String]
    /// The user's app-aware formatting choices. Read once at the hotkey press, so one
    /// dictation uses one consistent set even if Settings change while it runs.
    private let appFormatting: () -> AppFormattingSettings
    /// The text just before the caret in the target's focused field (at most
    /// `TextBeforeCursor.limit` characters), nil when it can't be read. Started at the
    /// press and never awaited there: the press path does not wait for it. The app layer
    /// caps its own read time.
    private let textBeforeCursor: (DeliveryTarget) async -> String?
    /// Presses the send key after a dictation landed. Only called after the controller
    /// checked the delivery and the target.
    private let sendKey: (SendKeyChord) -> Void
    /// This app's own id. A hotkey pressed while it is in front is a window dictation:
    /// copied, never pasted into our own window.
    private let ownAppID: String?
    /// Whether an editable, non-secure text field of this app has focus (a note, the
    /// first-run practice pad). Read at the press when Useful Voice itself is in front.
    private let ownFieldIsEditable: () -> Bool
    /// "Auto-format transcript". Read at the press. Cleanup rules and category formatting
    /// run only while it is on.
    private let autoFormat: () -> Bool
    /// The hidden local cleanup model (S1-mini), nil unless the hidden flag is on. With nil
    /// this controller behaves exactly as before.
    private let cleanupModel: LocalCleanupModel?
    /// The gates the model step checks, read at the press and again at the cleanup step.
    private let cleanupGates: () -> CleanupPipeline.Gates
    /// True between the press that preloaded the model and the dictation settling, so
    /// `end` is sent once per `begin` on every path (stop, cancel, error, delivery).
    private var cleanupDictationOpen = false
    /// Orders `begin` and `end`, which run as tasks, so an `end` can never overtake its `begin`.
    private var cleanupLifecycle: Task<Void, Never>?
    private var pendingRawMode = false
    /// Where the dictation now in flight was started, and the app it will paste
    /// into. Written once, when recording starts, and never by the stop toggle,
    /// the auto-stop or Esc. The stop path copies them out synchronously, and
    /// retryLast() does not read them at all.
    private var activeSource: DictationSource = .hotkey
    private var activeAppName: String?
    private var activeTarget: DeliveryTarget?
    /// What was decided at the press of the dictation in flight: the category of the
    /// target, the settings in force and the (memory only) read of the text before the
    /// caret. Dropped once the dictation settles.
    private var activePress: PressCapture?
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
    /// The press capture of that dictation, without the text before the caret (a retry
    /// is copied, so there is no caret to continue from).
    private var lastFailedPress: PressCapture?

    /// Everything decided at the hotkey press for app-aware formatting. The category is
    /// resolved from the captured target, never from what is in front after transcription.
    private struct PressCapture {
        let settings: AppFormattingSettings
        let category: AppCategory
        /// The target's app id; nil for a window dictation and for a dictation into this
        /// app's own field.
        let appID: String?
        /// "Auto-format transcript" at the press.
        let autoFormat: Bool
        /// A dictation into one of this app's own fields, or a window dictation: no app
        /// context at all (no app, category, caret read or category formatting).
        let inOwnApp: Bool
        let cursorRead: Task<String?, Never>?

        func withoutCursorRead() -> PressCapture {
            PressCapture(settings: settings, category: category, appID: appID,
                         autoFormat: autoFormat, inOwnApp: inOwnApp, cursorRead: nil)
        }
    }

    /// True when a failed dictation can be retried on its retained audio.
    public var canRetry: Bool { lastFailedAudio != nil }

    /// The target locked at the hotkey press of the dictation now in flight, nil
    /// for a window dictation and once the dictation has settled (idle or error):
    /// its window title and page address are held for that dictation only. The app
    /// layer reads it while formatting and delivering, so both use the app the
    /// user dictated into, not whatever is in front by then.
    public var deliveryTarget: DeliveryTarget? { activeTarget }

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
                frontmostApp: @escaping () -> FrontmostApp? = { nil },
                focusTarget: (() -> DeliveryTarget?)? = nil,
                isTargetRunning: @escaping (DeliveryTarget) -> Bool = { _ in true },
                reactivate: @escaping (DeliveryTarget) async -> Bool = { _ in false },
                typeOutApps: @escaping () -> [String] = { [] },
                appFormatting: @escaping () -> AppFormattingSettings = { AppFormattingSettings(enabled: false) },
                textBeforeCursor: @escaping (DeliveryTarget) async -> String? = { _ in nil },
                sendKey: @escaping (SendKeyChord) -> Void = { _ in },
                ownAppID: String? = nil,
                ownFieldIsEditable: @escaping () -> Bool = { false },
                autoFormat: @escaping () -> Bool = { false },
                cleanupModel: LocalCleanupModel? = nil,
                cleanupGates: @escaping () -> CleanupPipeline.Gates = { CleanupPipeline.Gates.current() }) {
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
        self.focusTarget = focusTarget
        self.isTargetRunning = isTargetRunning
        self.reactivate = reactivate
        self.typeOutApps = typeOutApps
        self.appFormatting = appFormatting
        self.textBeforeCursor = textBeforeCursor
        self.sendKey = sendKey
        self.ownAppID = ownAppID
        self.ownFieldIsEditable = ownFieldIsEditable
        self.autoFormat = autoFormat
        self.cleanupModel = cleanupModel
        self.cleanupGates = cleanupGates
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
            let target = activeTarget
            let press = activePress
            state = .transcribing   // synchronous: a racing toggle now sees .transcribing and is ignored
            processingTask = Task { await stopAndProcess(mode: mode, appName: appName, target: target, press: press) }
        case .transcribing, .delivering:
            break // busy; ignore to avoid double-processing
        }
    }

    /// Test helper / programmatic variant that awaits the processing.
    public func toggleAndWait() async {
        toggle()
        await processingTask?.value
    }

    /// Test helper: awaits the queued begin/end calls to the cleanup model.
    func awaitCleanupLifecycle() async {
        await cleanupLifecycle?.value
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
        let savedPress = lastFailedPress
        processingTask = Task {
            await process(audioURL: url, measuredDuration: nil,
                          presetContext: savedContext, mode: .copy, appName: nil, press: savedPress)
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
        lastFailedPress = nil
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
            // pastes, so only it needs the target it will paste into: the app,
            // window and element in front at the press, locked until delivery.
            var target = source == .hotkey ? currentFocus() : nil
            var effectiveSource = source
            // The hotkey pressed with Useful Voice itself in front pastes into our own
            // focused field when it is an editable one (a note, the first-run practice
            // pad). With none focused it is a window dictation: copied, never pasted into
            // our own window. A window dictation has no app context, so no category
            // formatting (cleanup and the user's own rules still run).
            let inOwnApp = isOwnApp(target)
            if inOwnApp, !ownFieldIsEditable() {
                target = nil
                effectiveSource = .window
            }
            activeSource = effectiveSource
            activeTarget = target
            activeAppName = target?.appName
            activePress = capturePress(for: target, inOwnApp: inOwnApp || effectiveSource == .window)
            state = .recording
            beginCleanupModelDictation()
        } catch {
            state = .error(DictationError.startFailure(error))
        }
    }

    /// Preloads the cleanup model while the person is still talking, when the hidden flag is
    /// on, Auto-format transcript is on and the gates pass. A pinned language other than English skips it (the model only runs
    /// for English, so loading it would be wasted); auto assumes English until the transcript
    /// says otherwise, and that run-time language check still applies. Fire and forget: nothing here waits for the load, and a failed load only means the model step
    /// falls back to the rules text later.
    private func beginCleanupModelDictation() {
        // Without Auto-format transcript the cleanup step never runs, so there is nothing to load for.
        guard let model = cleanupModel, !cleanupDictationOpen, autoFormat() else { return }
        let gates = cleanupGates()
        let pin = hint().languagePin
        guard case .run = CleanupModelPolicy.decide(
            flagOn: gates.flagOn, modelInstalled: gates.modelInstalled,
            physicalMemoryBytes: gates.physicalMemoryBytes,
            language: pin == .auto ? "en" : pin.rawValue) else { return }
        cleanupDictationOpen = true
        let previous = cleanupLifecycle
        cleanupLifecycle = Task { await previous?.value; await model.begin() }
    }

    /// Tells the model the dictation settled (idle or error), once per preload, whatever the path.
    private func endCleanupModelDictation() {
        guard let model = cleanupModel, cleanupDictationOpen else { return }
        cleanupDictationOpen = false
        let previous = cleanupLifecycle
        cleanupLifecycle = Task { await previous?.value; await model.end() }
    }

    /// The cleanup step of the formatted path. Without the hidden model it is the rules and
    /// nothing else; with it, the pipeline (rules, then the model behind its gates, deadline
    /// and guard). Either way an empty result keeps the transcript, so nothing is lost.
    private func cleanedTranscript(_ text: String, language: String, press: PressCapture) async -> String {
        let cleaned: String
        if let cleanupModel {
            // Own app, or "Format for the app" off: no category and no stored style reach the model.
            let appContext = !press.inOwnApp && press.settings.enabled
            let result = await CleanupPipeline.run(
                raw: text, language: language,
                category: appContext ? press.category.rawValue : nil,
                style: appContext ? press.settings.requestedStyle(for: press.category) : nil,
                gates: cleanupGates(), model: cleanupModel)
            cleaned = result.text
        } else {
            cleaned = CleanupRules.apply(to: text, language: language)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : cleaned
    }

    /// Resolves the category of the target and starts reading the text before the caret.
    /// Cheap and non-blocking: the read runs as a task and is awaited only when the
    /// transcript is ready, long after the press.
    private func capturePress(for target: DeliveryTarget?, inOwnApp: Bool) -> PressCapture {
        let settings = appFormatting()
        let autoOn = self.autoFormat()
        let category: AppCategory = inOwnApp ? .other
            : settings.category(forAppID: target?.appID, url: target?.browserURL)
        var read: Task<String?, Never>?
        // The read is only useful to category formatting, so it runs under the same gate.
        if settings.enabled, autoOn, !inOwnApp, let target {
            let reader = textBeforeCursor
            read = Task { await reader(target) }
        }
        return PressCapture(settings: settings, category: category,
                            appID: inOwnApp ? nil : target?.appID, autoFormat: autoOn, inOwnApp: inOwnApp,
                            cursorRead: read)
    }

    private func isOwnApp(_ target: DeliveryTarget?) -> Bool {
        guard let own = ownAppID?.lowercased(), let id = target?.appID?.lowercased() else { return false }
        return id == own
    }

    private func stopAndProcess(mode: DeliveryMode, appName: String?,
                                 target: DeliveryTarget?, press: PressCapture?) async {
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
                      mode: mode, appName: appName, target: target, press: press)
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
                         target: DeliveryTarget? = nil,
                         press: PressCapture? = nil) async {
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
            lastFailedPress = press?.withoutCursorRead()
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
        lastFailedPress = nil

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
        } else {
            // The formatted path, in order: the transcript (Deepgram applied the transcript
            // style), cleanup rules, category formatting, then the user's dictionary fixes,
            // replacement rules and snippets inside `format`, so a user's own rule always
            // has the last word. Both steps run only while "Auto-format transcript" is on,
            // and anything unsure keeps the text.
            var pipelineText = transcript.text
            if let press, press.autoFormat {
                // Cleanup rules (#48): fillers and stutters, English only. An empty result
                // would lose the dictation, so the transcript is kept instead. With the hidden
                // flag on, the local model runs after the rules, behind its gates.
                pipelineText = await cleanedTranscript(pipelineText, language: effectivePin.rawValue, press: press)
            }
            if let press, press.autoFormat, press.settings.enabled, !press.inOwnApp {
                let plan = AppFormattingPlan(
                    category: press.category,
                    style: press.settings.requestedStyle(for: press.category),
                    userName: press.settings.userName,
                    textBeforeCursor: await boundedCursorRead(press.cursorRead))
                pipelineText = plan.apply(to: pipelineText, dictionaryWords: effectiveContext.dictionaryWords)
            }
            let categoryChangedText = pipelineText != transcript.text
            if let format {
                do {
                    let result = try await format(pipelineText, effectiveContext)
                    finalText = result.text
                    mode = result.mode
                    replacementRuleIDs = result.replacementRuleIDs
                    memoryHitIDs = result.memoryHitIDs
                    snippetIDs = result.snippetIDs
                    if !result.newTerms.isEmpty { suggestTerms(result.newTerms) }
                    // History shows "formatted" when cleanup or the category formatter changed the text.
                    if categoryChangedText { mode = .formatted }
                } catch {
                    // The formatter failed: deliver the transcript as it came, without
                    // the category formatting.
                    formatterUnavailable()   // keep raw finalText; mode stays .raw
                    if let rawTransform {
                        let result = await rawTransform(transcript.text, effectiveContext)
                        finalText = result.text
                        replacementRuleIDs = result.replacementRuleIDs
                        memoryHitIDs = result.memoryHitIDs
                        snippetIDs = result.snippetIDs
                    }
                }
            } else {
                finalText = pipelineText
                if categoryChangedText { mode = .formatted }
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
            audioPath: audioURL.path,
            appID: press?.appID,
            category: press?.appID == nil ? nil : press?.category.rawValue))

        state = .delivering
        try? store.prune(keep: recordingsToKeep)
        // A hotkey dictation pastes only into the target locked at the press. If
        // focus has moved (the user clicked into another composer, or stopped from
        // Useful Voice's own window), the target is brought back first; if that
        // does not work, or the target is gone, the text is copied and the user is
        // told, rather than pasted into the wrong place. Started and still in an
        // editable field of Useful Voice (a note, the practice pad) pastes; with no
        // such field focused the press was a window dictation and only copies.
        var deliverMode = deliveryMode
        var pasteRedirected = false
        var lineBreaksCopied = false
        if deliverMode == .paste,
           InsertionMethod.method(forAppID: target?.appID, typeOutApps: typeOutApps(),
                                  text: finalText) == .copyOnly {
            // An app that types, and text with a line break: copied only, decided
            // before the lock so the target is never brought forward just to copy.
            deliverMode = .copy
            lineBreaksCopied = true
        } else if deliverMode == .paste, !(await lockOnTarget(target)) {
            deliverMode = .copy
            pasteRedirected = true
        }
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
        // Auto-send: only after a paste or typed delivery that landed in the target locked
        // at the press (never a copy, a redirect, a retry or a window dictation).
        let pastes = deliverMode == .paste
        let sendChord: SendKeyChord? = {
            guard pastes, let press, press.appID != nil, let target, target.isIdentified else { return nil }
            return press.settings.autoSendKey(for: press.category).chord(for: .macOS)
        }()
        deliver(finalText, deliverMode) { [weak self] report in
            guard let self, self.state == .delivering,
                  self.deliveryToken == token else { return }
            self.deliveryToken += 1
            switch report {
            case .success(let result):
                let reported: DeliveryResult =
                    lineBreaksCopied && result == .copied ? .copiedHasLineBreaks
                    : pasteRedirected && result == .copied ? .copiedAppChanged : result
                if result == .pasted, let sendChord, let target { self.pressSendKey(sendChord, target: target) }
                self.onOutcome?(.delivered(words: words, mode: reported, appName: appName))
                self.state = .idle
            case .failure:
                self.state = .error(DictationError(
                    kind: .deliveryFailed,
                    message: "Couldn't copy the text. It's saved in Useful Voice."))
            }
        }
    }

    /// How long the transcript waits for the text-before-cursor read, which started at the
    /// press and is normally long finished. The app layer caps its own read at 150 ms; this
    /// only keeps a stuck reader from holding up a dictation.
    static let cursorReadWait: TimeInterval = 0.3

    private func boundedCursorRead(_ read: Task<String?, Never>?) async -> String? {
        guard let read else { return nil }
        return await TextBeforeCursor.bounded(seconds: Self.cursorReadWait, read)
    }

    /// Presses the send key, if the target is still the one locked at the press and no
    /// password field has taken focus. Otherwise nothing is pressed.
    private func pressSendKey(_ chord: SendKeyChord, target: DeliveryTarget) {
        guard !isSecureInputActive(), TargetLock.matches(target, currentFocus()) else { return }
        sendKey(chord)
    }

    /// What has focus now: the full target when the app layer reads one, else
    /// just the frontmost app.
    private func currentFocus() -> DeliveryTarget? {
        if let focusTarget { return focusTarget() }
        return frontmostApp().map(DeliveryTarget.init(app:))
    }

    /// Runs the target lock (see `TargetLock`): true when the text may be
    /// inserted, with the target in front; false when it must only be copied.
    private func lockOnTarget(_ target: DeliveryTarget?) async -> Bool {
        let running = target.map(isTargetRunning) ?? false
        var decision = TargetLock.check(target: target, current: currentFocus(), targetRunning: running)
        if decision == .reactivate, let target {
            let reactivated = await reactivate(target)
            decision = TargetLock.recheck(target: target, current: currentFocus(), reactivated: reactivated)
        }
        switch decision {
        case .insert:
            return true
        case .reactivate:
            return false   // unreachable: recheck never asks again
        case .copyOnly(let reason):
            diagnostics.record(level: .info, category: "delivery",
                               message: "target not reachable (\(reason)); copied instead of pasting")
            return false
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
