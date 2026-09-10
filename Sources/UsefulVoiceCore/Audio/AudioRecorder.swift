import AVFoundation
import Foundation

public protocol AudioRecording: AnyObject {
    func start(to url: URL) throws
    func stop() throws -> URL
    func cancel()
    var onLevel: ((Float) -> Void)? { get set }
    var onAutoStop: (() -> Void)? { get set }
    /// True when at least one buffer in the just-finished recording crossed the
    /// speech threshold. False means the user was silent the whole time, so the
    /// audio must not be transcribed: a silent clip can make a speech model echo
    /// its own prompt bias (the dictionary) back as a fake transcript. Valid to
    /// read after stop().
    var didCaptureSpeech: Bool { get }
    func updateSilenceTimeout(_ timeout: TimeInterval)
    /// A failure that ended capture early (the input device disappeared, audio
    /// could not be written). Nil when capture was healthy.
    var captureError: Error? { get }
}

public extension AudioRecording {
    func updateSilenceTimeout(_ timeout: TimeInterval) {}
    var captureError: Error? { nil }
}

public enum AudioRecorderError: Error, LocalizedError {
    case notRecording
    case formatUnsupported
    case alreadyRecording
    /// No usable microphone / input device is available.
    case noInputDevice
    /// The input device changed or disappeared mid-recording and capture could
    /// not be restarted.
    case inputDeviceLost
    /// Audio could not be written to disk (full volume, permissions).
    case diskWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Nothing was being recorded."
        case .formatUnsupported:
            return "This microphone's audio format isn't supported."
        case .alreadyRecording:
            return "Useful Voice is already recording."
        case .noInputDevice:
            return "No microphone was found. Check that one is connected and selected in Sound settings."
        case .inputDeviceLost:
            return "The microphone was disconnected while recording."
        case .diskWriteFailed(let detail):
            return "Audio couldn't be saved to disk, so the recording is incomplete. \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noInputDevice, .inputDeviceLost:
            return "Connect or reselect your microphone, then dictate again."
        case .diskWriteFailed:
            return "Free up disk space, then dictate again."
        case .formatUnsupported:
            return "Try a different input device in System Settings > Sound > Input."
        case .notRecording, .alreadyRecording:
            return nil
        }
    }
}

/// AVAudioEngine capture -> 16kHz mono Int16 WAV. UI-facing callbacks fire
/// on the real-time tap thread; the app layer hops to the main thread.
///
/// Threading: AVAudioEngine drives the input tap on a high-priority real-time
/// render thread. A synchronous FileHandle write there can glitch audio, so the
/// WavWriter is owned by a dedicated serial queue. The tap does only the cheap
/// work (RMS, watchdog, Int16 conversion) and hands the converted samples to the
/// queue. Everything that describes a *session* — the writer, the watchdog, the
/// speech latch, the session token, the start time — is likewise confined to
/// that queue, so a late buffer from a finished session cannot corrupt the
/// session that replaced it.
public final class AudioRecorder: AudioRecording, @unchecked Sendable {
    /// Everything in this struct is touched only on `writerQueue`.
    private struct Session {
        var writer: WavWriter?
        var watchdog: SilenceWatchdog
        var capturedSpeech = false
        var startedAt: Date?
        var autoStopFired = false
        var writeError: Error?
        /// Identity token so a buffer enqueued by an earlier session is ignored.
        var id = UUID()
    }

    private let engine = AVAudioEngine()
    private var session = Session(watchdog: SilenceWatchdog(timeout: 60))
    private var fileURL: URL?
    private var silenceTimeout: TimeInterval
    /// Hard cap on recording length. Spec section 8: 10 minutes.
    private let maxDuration: TimeInterval
    /// Peak absolute sample at or above which a buffer counts as containing
    /// speech. Deliberately gated on PEAK, not the buffer-averaged RMS the
    /// watchdog uses: a soft word's RMS can average below the watchdog's 0.01
    /// silence line and be washed out, but its voiced peaks still stand well
    /// clear of room tone. 0.02 sits in the gap, low enough to catch soft
    /// speakers and quiet mics, high enough to reject a truly silent clip.
    private static let speechPeakThreshold: Float = 0.02

    /// Serial queue that exclusively owns the WavWriter and all session state.
    /// All create/append/finish calls happen here so the real-time tap thread
    /// never blocks on file I/O.
    private let writerQueue = DispatchQueue(label: "ai.karko.usefulvoice.audiorecorder.writer")

    /// Guard for the few fields that must be visible from both the app thread
    /// and the writer queue.
    private let stateLock = NSLock()
    private var _captureError: Error?

    public var onLevel: ((Float) -> Void)?
    /// Fires when the silence timeout or max duration is hit, or when capture
    /// fails and the recording must stop. The app layer treats it exactly like a
    /// stop toggle.
    public var onAutoStop: (() -> Void)?

    /// Whether the just-finished recording contained any speech. Serialized
    /// through writerQueue, which stop() drains, so it reflects every buffer.
    public var didCaptureSpeech: Bool { writerQueue.sync { session.capturedSpeech } }

    /// The first capture failure of the last session, if any. Reading it after
    /// stop() lets the pipeline report the real cause instead of transcribing a
    /// truncated file as if it were complete.
    public var captureError: Error? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _captureError
    }

    public init(silenceTimeout: TimeInterval = 60,
                maxDuration: TimeInterval = 600) {
        self.silenceTimeout = silenceTimeout
        self.maxDuration = maxDuration
        self.session = Session(watchdog: SilenceWatchdog(timeout: silenceTimeout))

        // The input device can change or disappear at any moment: AirPods
        // disconnect, a USB interface is unplugged, a headset switches profile,
        // or the user changes the default input. AVAudioEngine then stops
        // delivering buffers. Because the silence watchdog and the max-duration
        // cap are both evaluated inside the buffer callback, losing buffers
        // without noticing used to leave the app stuck in .recording forever,
        // with only a manual hotkey press as the way out.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func updateSilenceTimeout(_ timeout: TimeInterval) {
        silenceTimeout = timeout
        writerQueue.async { [weak self] in
            self?.session.watchdog = SilenceWatchdog(timeout: timeout)
        }
    }

    public func start(to url: URL) throws {
        guard fileURL == nil else { throw AudioRecorderError.alreadyRecording }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)

        // With no usable input device (no microphone, unplugged interface, or a
        // denied permission the system reports as a zeroed format) the hardware
        // format is 0 Hz / 0 channels. Building a converter from that and
        // installing a tap produces a silent, unusable recording that only fails
        // much later as a mysterious provider error, so reject it up front with
        // a message the user can act on.
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000, channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        else { throw AudioRecorderError.formatUnsupported }

        // Refuse to start when there is nowhere to put the audio. Recording into
        // a full disk used to fail silently and upload a truncated file.
        try checkFreeSpace(for: url)

        let sessionID = UUID()
        // Create the writer on the serial queue so it's owned there from birth.
        var writerError: Error?
        writerQueue.sync {
            do {
                self.session = Session(writer: try WavWriter(url: url, sampleRate: 16_000),
                                       watchdog: SilenceWatchdog(timeout: silenceTimeout),
                                       startedAt: Date(),
                                       id: sessionID)
            } catch {
                writerError = error
            }
        }
        if let writerError { throw writerError }

        stateLock.lock()
        _captureError = nil
        stateLock.unlock()
        fileURL = url

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter,
                          targetFormat: targetFormat, sessionID: sessionID)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // engine.start() failed after the tap and writer were created. Remove
            // the tap and tear down the half-created writer before rethrowing so
            // the recorder is left in a clean, restartable state.
            engine.inputNode.removeTap(onBus: 0)
            writerQueue.sync {
                try? self.session.writer?.finish()
                self.session.writer = nil
            }
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
            fileURL = nil
            throw error
        }
    }

    public func stop() throws -> URL {
        guard let url = fileURL else { throw AudioRecorderError.notRecording }
        teardownEngine()
        // Appends enqueued before teardown drain on the serial queue before this
        // sync finish. A buffer still mid-process when the tap is removed may
        // enqueue after finish(); the session token makes that tail a no-op
        // instead of a write into a closed file.
        var finishError: Error?
        writerQueue.sync {
            invalidateSessionLocked()
            do {
                try self.session.writer?.finish()
            } catch {
                finishError = error
            }
            self.session.writer = nil
        }
        fileURL = nil
        if let finishError { throw finishError }
        return url
    }

    public func cancel() {
        teardownEngine()
        let url = fileURL
        writerQueue.sync {
            invalidateSessionLocked()
            try? self.session.writer?.finish()
            self.session.writer = nil
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    /// Marks the current session dead so any buffer still in flight is ignored,
    /// and latches a write failure so stop() callers can see it.
    private func invalidateSessionLocked() {
        if let error = session.writeError {
            stateLock.lock()
            if _captureError == nil { _captureError = error }
            stateLock.unlock()
        }
        session.id = UUID()
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Rebuilds the tap and converter after the audio graph changes underneath
    /// us. Without this, unplugging the microphone mid-dictation froze the app in
    /// `.recording` because no further buffers arrived to drive the watchdog or
    /// the duration cap.
    @objc private func handleConfigurationChange(_ notification: Notification) {
        // Only meaningful while recording; the engine is idle otherwise.
        guard fileURL != nil else { return }
        writerQueue.async { [weak self] in
            guard let self, self.session.writer != nil else { return }
            let sessionID = self.session.id
            DispatchQueue.main.async {
                self.restartCapture(after: sessionID)
            }
        }
    }

    /// App-layer hop for the restart, because AVAudioEngine's nodes must be
    /// reconfigured from the thread that owns the engine's lifecycle.
    private func restartCapture(after sessionID: UUID) {
        guard let url = fileURL else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        let stillCurrent = writerQueue.sync { session.id == sessionID }
        guard stillCurrent else { return }

        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000, channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            // The device is gone and did not come back. End the recording cleanly
            // rather than hanging in .recording forever.
            failCapture(with: AudioRecorderError.inputDeviceLost)
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter,
                          targetFormat: targetFormat, sessionID: sessionID)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            failCapture(with: AudioRecorderError.inputDeviceLost)
        }
        _ = url
    }

    /// Latches a capture failure and asks the app layer to stop the recording.
    private func failCapture(with error: Error) {
        stateLock.lock()
        if _captureError == nil { _captureError = error }
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onAutoStop?() }
    }

    /// Fails fast when the destination volume cannot hold a minute of audio
    /// rather than silently truncating the recording later.
    private func checkFreeSpace(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return // Cannot determine: do not block recording on a missing API.
        }
        // ~1.9 MB per minute at 16 kHz mono 16-bit; demand a comfortable margin.
        let required: Int64 = 20 * 1_024 * 1_024
        if available < required {
            throw AudioRecorderError.diskWriteFailed(
                "Only \(available / 1_024 / 1_024) MB is free.")
        }
    }

    private func process(buffer: AVAudioPCMBuffer,
                         converter: AVAudioConverter,
                         targetFormat: AVAudioFormat,
                         sessionID: UUID) {
        // RMS (for HUD levels + the silence watchdog) and peak (for the speech
        // gate) from the float hardware buffer, in one pass.
        var rms: Float = 0
        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n {
                let sample = channel[i]
                sum += sample * sample
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
            }
            rms = (sum / Float(n)).squareRoot()
        }
        onLevel?(rms)

        // Convert to 16kHz mono Int16 on the tap thread (cheap, no file I/O).
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: capacity) else { return }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              let channel = out.int16ChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel,
                                                count: Int(out.frameLength)))
        let isSpeech = peak >= Self.speechPeakThreshold
        let maxDuration = self.maxDuration

        // Hand the converted samples to the serial queue; the WavWriter append
        // (the only file I/O) runs there, never on the real-time tap thread. All
        // session state — speech latch, watchdog, auto-stop latch — is evaluated
        // on that same queue, which is also where the session token lives, so a
        // stale buffer from a previous session cannot disturb this one.
        writerQueue.async { [weak self] in
            guard let self, self.session.id == sessionID else { return }
            if isSpeech { self.session.capturedSpeech = true }

            // Evaluate the stop conditions here, not on the render thread: this
            // is the only place with a consistent view of the session.
            let elapsed = Date().timeIntervalSince(self.session.startedAt ?? Date())
            let shouldStop = !self.session.autoStopFired
                && (self.session.watchdog.observe(rms: rms, at: elapsed)
                    || elapsed > maxDuration)

            do {
                try self.session.writer?.append(samples: samples)
            } catch {
                // First write failure wins: it is the one that explains the
                // truncated audio. Transcribing the rest as if it were complete
                // would hand the user a transcript that stops mid-sentence.
                if self.session.writeError == nil {
                    self.session.writeError = error
                    let wrapped = AudioRecorderError.diskWriteFailed(
                        error.localizedDescription)
                    self.stateLock.lock()
                    if self._captureError == nil { self._captureError = wrapped }
                    self.stateLock.unlock()
                    self.session.autoStopFired = true
                    DispatchQueue.main.async { [weak self] in self?.onAutoStop?() }
                    return
                }
            }

            if shouldStop {
                self.session.autoStopFired = true
                DispatchQueue.main.async { [weak self] in self?.onAutoStop?() }
            }
        }
    }
}
