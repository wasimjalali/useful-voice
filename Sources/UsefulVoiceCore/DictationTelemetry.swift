import Combine
import Foundation

/// Live numbers from the dictation in flight, for the main window's dock.
///
/// A separate object on purpose: the level updates ~30 times a second, and it
/// must redraw only the views that observe it, not the whole window. Every
/// setter is guarded, so an unchanged value publishes nothing.
///
/// The state it follows is fed by `apply(state:)`, so the clearing rules live
/// here: telemetry never outlives the phase it belongs to, and a late tick or a
/// late partial (the callbacks hop threads) is dropped.
@MainActor
public final class DictationTelemetry: ObservableObject {
    /// Whole seconds since recording started.
    @Published public private(set) var elapsedSeconds: Int = 0
    /// Input level (RMS) while recording, 0 otherwise.
    @Published public private(set) var level: Float = 0
    /// Local Whisper partial text, only while transcribing.
    @Published public private(set) var localPartial: String?
    /// Whole seconds until the recording stops on silence. Nil unless 5 s or
    /// less remain.
    @Published public private(set) var silenceRemaining: Int?
    /// Whole seconds until the maximum recording length ends it. Nil unless 5 s
    /// or less remain.
    @Published public private(set) var maxRemaining: Int?

    private var phase: DictationState = .idle

    public init() {}

    /// Follows the controller. Recording starts from zero; leaving recording
    /// drops level and countdowns; delivering drops the partial (the record is
    /// already in history); idle and error clear everything.
    public func apply(state: DictationState) {
        phase = state
        switch state {
        case .recording:
            set(elapsed: 0, level: 0, partial: nil, silence: nil, max: nil)
        case .transcribing:
            set(elapsed: elapsedSeconds, level: 0, partial: nil, silence: nil, max: nil)
        case .delivering:
            set(elapsed: elapsedSeconds, level: 0, partial: nil, silence: nil, max: nil)
        case .idle, .error:
            set(elapsed: 0, level: 0, partial: nil, silence: nil, max: nil)
        }
    }

    /// One tick of the recording timer. Ignored unless a recording is in
    /// progress, so a tick that was already queued when recording stopped cannot
    /// bring the level or a countdown back.
    public func tick(elapsed: Int, level: Float, deadlines: AutoStopDeadlines, now: Date) {
        guard phase == .recording else { return }
        set(elapsed: elapsed, level: level, partial: nil,
            silence: AutoStopCountdown.seconds(until: deadlines.silence, now: now),
            max: AutoStopCountdown.seconds(until: deadlines.max, now: now),
            keepPartial: true)
    }

    /// Partial text from the local engine. Ignored unless transcribing.
    public func setPartial(_ text: String?) {
        guard phase == .transcribing else { return }
        if localPartial != text { localPartial = text }
    }

    private func set(elapsed: Int, level: Float, partial: String?,
                     silence: Int?, max: Int?, keepPartial: Bool = false) {
        if elapsedSeconds != elapsed { elapsedSeconds = elapsed }
        if self.level != level { self.level = level }
        if !keepPartial, localPartial != partial { localPartial = partial }
        if silenceRemaining != silence { silenceRemaining = silence }
        if maxRemaining != max { maxRemaining = max }
    }
}
