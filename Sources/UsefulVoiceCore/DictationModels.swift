import Foundation

/// Where a dictation was started. Captured when recording STARTS and kept for
/// that dictation: the stop toggle (from any source), the auto-stop and Esc
/// never change it. A window start is saved and copied, a hotkey start pastes
/// into the app that was frontmost.
public enum DictationSource: Sendable, Equatable {
    case hotkey
    case window
}

/// What delivery should do with the final text.
public enum DeliveryMode: Sendable, Equatable {
    /// Insert into the focused app (paste, with the clipboard as the fallback).
    case paste
    /// Put it on the clipboard and never paste.
    case copy
}

/// How delivery actually ended.
public enum DeliveryResult: Sendable, Equatable {
    /// Inserted into the focused app.
    case pasted
    /// Paste mode, but nothing landed: the text is on the clipboard for the user
    /// to paste. This is a notice, not an error.
    case copiedNotPasted
    /// Copy mode: the text is on the clipboard, as asked.
    case copied
}

/// Delivery could not put the text where it was meant to go (the clipboard write
/// failed). The dictation itself is already saved.
public struct DeliveryFailure: Error, Equatable, Sendable {
    public init() {}
}

/// What a delivery reports back to the controller.
public typealias DeliveryReport = Result<DeliveryResult, DeliveryFailure>

/// The app in front of the user, as the controller needs to know it.
public struct FrontmostApp: Equatable, Sendable {
    /// Stable identity (bundle id) used to tell whether the app changed.
    public let id: String?
    /// Localized name shown to the user.
    public let name: String?
    /// True when it is Useful Voice itself.
    public let isSelf: Bool

    public init(id: String?, name: String?, isSelf: Bool = false) {
        self.id = id
        self.name = name
        self.isSelf = isSelf
    }
}

/// A one-click fix the UI can attach to an error.
public enum DictationFix: Sendable, Equatable {
    case openMicrophoneSettings
    case openAccessibilitySettings
    case openEngineSettings
    case retry
}

/// A typed dictation failure. `message` is the user-facing text, unchanged from
/// when the state carried a bare string.
public struct DictationError: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A password field is focused.
        case secureField
        /// Recording could not start (no microphone, permission denied, no disk).
        case micUnavailable
        /// Recording could not start because the disk is full or not writable.
        case diskFull
        /// Recording could not start for another reason (unsupported audio
        /// format, a recording already running, a file error).
        case recordingFailed
        /// The text could not be put on the clipboard. The dictation is saved.
        case deliveryFailed
        /// Recording started but could not be finished.
        case stopFailed
        /// The recording, or the transcript, held no speech.
        case noSpeech
        /// The recording was too short to send.
        case tooShort
        /// No key and no model: nothing can transcribe.
        case noProvider
        /// The provider refused the key (HTTP 401 or 403).
        case keyRejected
        /// The provider account is out of credits.
        case outOfCredits
        /// No connection to the provider.
        case offline
        /// The provider did not answer in time.
        case timedOut
        /// Any other provider failure.
        case providerFailed
        /// The local engine failed.
        case engineFailed
    }

    public let kind: Kind
    public let message: String
    /// The one-click fix, if there is one. `.retry` is set only when the
    /// controller retained the audio (`DictationController.canRetry`).
    public let fix: DictationFix?

    public init(kind: Kind, message: String, fix: DictationFix? = nil) {
        self.kind = kind
        self.message = message
        self.fix = fix
    }

    /// The kind a failed transcription maps to. HTTP 401 and 403 are a rejected
    /// key. A transport error is "offline" only for the codes that mean there is
    /// no connection; a timeout is its own kind and any other URL error is a
    /// plain provider failure, so the UI never tells someone with a TLS problem
    /// that they are offline.
    static func kind(forTranscriptionFailure error: Error?) -> Kind {
        switch error {
        case let providerError as ProviderError:
            switch providerError {
            case .http(let status, _):
                return status == 401 || status == 403 ? .keyRejected : .providerFailed
            case .outOfCredits: return .outOfCredits
            case .badResponse: return .providerFailed
            case .notConfigured: return .noProvider
            case .timedOut: return .timedOut
            case .transport(let urlError): return kind(forURLError: urlError)
            case .engineFailed: return .engineFailed
            }
        case let urlError as URLError:
            return kind(forURLError: urlError)
        default:
            return .providerFailed
        }
    }

    private static func kind(forURLError error: URLError) -> Kind {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return .offline
        case .timedOut:
            return .timedOut
        default:
            return .providerFailed
        }
    }

    /// The error for a recording that would not start, typed by cause so the
    /// microphone fix is offered only when the microphone is the problem.
    static func startFailure(_ error: Error) -> DictationError {
        let message = "Couldn't start recording: \(error.localizedDescription)"
        let kind: Kind
        switch error {
        case let recorderError as AudioRecorderError:
            switch recorderError {
            case .noInputDevice, .inputDeviceLost: kind = .micUnavailable
            case .diskWriteFailed: kind = .diskFull
            case .formatUnsupported, .alreadyRecording, .notRecording: kind = .recordingFailed
            }
        case let cocoa as CocoaError:
            kind = cocoa.code == .fileWriteOutOfSpace ? .diskFull : .recordingFailed
        default:
            // The engine refusing to start is almost always the input device or
            // its permission.
            kind = .micUnavailable
        }
        return DictationError(kind: kind, message: message,
                              fix: kind == .micUnavailable ? .openMicrophoneSettings : nil)
    }

    /// The fix for a transcription failure. Retry is offered only where the fault
    /// is likely to pass; a rejected key, no credits or a missing engine need
    /// Settings first (the audio is still retained, so `canRetry` stays true).
    static func fix(forTranscriptionFailure kind: Kind) -> DictationFix? {
        switch kind {
        case .noProvider, .keyRejected, .outOfCredits: return .openEngineSettings
        case .offline, .timedOut, .providerFailed, .engineFailed: return .retry
        case .secureField, .micUnavailable, .diskFull, .recordingFailed, .deliveryFailed,
             .stopFailed, .noSpeech, .tooShort:
            return nil
        }
    }
}

/// What a finished dictation did. Published through
/// `DictationController.onOutcome`.
public enum DictationOutcome: Equatable, Sendable {
    /// Text was delivered. `words` counts whitespace-separated tokens of the
    /// delivered text. `appName` is the app that was frontmost when a hotkey
    /// dictation started, nil for a window dictation or a retry.
    case delivered(words: Int, mode: DeliveryResult, appName: String?)
    /// The user cancelled a recording.
    case cancelled

    /// Whitespace-separated tokens. No script-specific handling: Persian and
    /// German count the same way.
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// What the window and HUD keep showing after a dictation: an error with its fix,
/// or the notice that text was copied but not pasted.
public enum DictationIssue: Equatable, Sendable {
    case error(DictationError)
    case copiedNotPasted

    public var message: String {
        switch self {
        case .error(let error): return error.message
        case .copiedNotPasted: return "Copied. Press \u{2318}V to paste."
        }
    }

    /// The fix for the issue. A copied-not-pasted notice points at Accessibility,
    /// the usual reason the paste could not be posted.
    public var fix: DictationFix? {
        switch self {
        case .error(let error): return error.fix
        case .copiedNotPasted: return .openAccessibilitySettings
        }
    }
}

/// The issue and outcome the window shows, driven by the controller's state and
/// outcome events. Pure value logic, so the rules are testable without UI.
///
/// Rules: a recording, transcribing or delivering state clears both (a new
/// dictation, or a retry, supersedes the old result); an error state sets the
/// issue; a delivered-but-not-pasted outcome sets the notice; returning to idle
/// changes nothing, because the outcome event fires just before it.
public struct DictationFeedback: Equatable, Sendable {
    public private(set) var issue: DictationIssue?
    public private(set) var outcome: DictationOutcome?

    public init() {}

    public mutating func apply(state: DictationState) {
        switch state {
        case .recording, .transcribing, .delivering:
            issue = nil
            outcome = nil
        case .error(let error):
            issue = .error(error)
            outcome = nil
        case .idle:
            break
        }
    }

    public mutating func apply(outcome next: DictationOutcome) {
        outcome = next
        if case .delivered(_, .copiedNotPasted, _) = next {
            issue = .copiedNotPasted
        }
    }

    public mutating func dismissIssue() {
        issue = nil
    }
}
