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
    /// audio must not be transcribed: a silent clip makes Whisper echo its own
    /// prompt bias (the dictionary) back as a fake transcript. Valid to read
    /// after stop().
    var didCaptureSpeech: Bool { get }
    func updateSilenceTimeout(_ timeout: TimeInterval)
}

public extension AudioRecording {
    func updateSilenceTimeout(_ timeout: TimeInterval) {}
}

public enum AudioRecorderError: Error {
    case notRecording
    case formatUnsupported
    case alreadyRecording
}

/// AVAudioEngine capture -> 16kHz mono Int16 WAV. UI-facing callbacks fire
/// on the real-time tap thread; the app layer hops to the main thread.
///
/// Threading: AVAudioEngine drives the input tap on a high-priority real-time
/// render thread. A synchronous FileHandle write there can glitch audio, so the
/// WavWriter is owned by a dedicated serial queue. The tap does only the cheap
/// work (RMS, watchdog, Int16 conversion) and hands the converted samples to the
/// queue. The writer is created, appended to and finished only on that queue, so
/// there is no data race on it.
public final class AudioRecorder: AudioRecording {
    private let engine = AVAudioEngine()
    private var writer: WavWriter?
    private var fileURL: URL?
    private var watchdog: SilenceWatchdog
    private var startedAt: Date?
    /// Latch so onAutoStop fires at most once per session. Mutated only on the
    /// single AVAudioEngine tap thread (after start() assigns state before the
    /// tap is installed), so no synchronization is needed.
    private var autoStopFired = false
    private var silenceTimeout: TimeInterval
    /// Hard cap on recording length. Spec section 8: 10 minutes.
    private let maxDuration: TimeInterval
    /// Peak absolute sample at or above which a buffer counts as containing
    /// speech. Deliberately gated on PEAK, not the buffer-averaged RMS the
    /// watchdog uses: a soft word's RMS can average below the watchdog's 0.01
    /// silence line and be washed out, but its voiced peaks still stand well
    /// clear of room tone. 0.02 sits in the gap, low enough to catch soft
    /// speakers and quiet mics, high enough to reject a truly silent clip (the
    /// only case that makes Whisper echo its prompt bias back as a transcript).
    private static let speechPeakThreshold: Float = 0.02
    /// Latched true once any buffer crosses the speech threshold. Read/written
    /// only on writerQueue so the cross-thread read in didCaptureSpeech is safe.
    private var capturedSpeech = false

    /// Serial queue that exclusively owns the WavWriter. All create/append/finish
    /// calls happen here so the real-time tap thread never blocks on file I/O.
    private let writerQueue = DispatchQueue(label: "com.sadaa.audiorecorder.writer")

    public var onLevel: ((Float) -> Void)?
    /// Fires when silence timeout or max duration is hit; the app layer
    /// treats it exactly like a stop toggle.
    public var onAutoStop: (() -> Void)?

    /// Whether the just-finished recording contained any speech. Serialized
    /// through writerQueue, which stop() drains, so it reflects every buffer.
    public var didCaptureSpeech: Bool { writerQueue.sync { capturedSpeech } }

    public init(silenceTimeout: TimeInterval = 60,
                maxDuration: TimeInterval = 600) {
        self.silenceTimeout = silenceTimeout
        self.maxDuration = maxDuration
        self.watchdog = SilenceWatchdog(timeout: silenceTimeout)
    }

    public func updateSilenceTimeout(_ timeout: TimeInterval) {
        silenceTimeout = timeout
    }

    public func start(to url: URL) throws {
        guard fileURL == nil else { throw AudioRecorderError.alreadyRecording }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000, channels: 1,
                                               interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        else { throw AudioRecorderError.formatUnsupported }

        // Create the writer on the serial queue so it's owned there from birth.
        var writerError: Error?
        writerQueue.sync {
            do {
                self.writer = try WavWriter(url: url, sampleRate: 16_000)
                self.capturedSpeech = false   // fresh session: no speech heard yet
            } catch {
                writerError = error
            }
        }
        if let writerError { throw writerError }

        // Assign all session state BEFORE installing the tap so the tap thread
        // never observes stale watchdog/startedAt/latch from a prior session.
        fileURL = url
        watchdog = SilenceWatchdog(timeout: silenceTimeout)
        startedAt = Date()
        autoStopFired = false

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) {
            [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter,
                          targetFormat: targetFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // engine.start() failed after the tap and writer were created. Remove
            // the tap and tear down the half-created writer before rethrowing so
            // the recorder is left in a clean, restartable state.
            engine.inputNode.removeTap(onBus: 0)
            writerQueue.sync { try? writer?.finish() }
            if let url = fileURL { try? FileManager.default.removeItem(at: url) }
            writer = nil
            fileURL = nil
            startedAt = nil
            throw error
        }
    }

    public func stop() throws -> URL {
        guard let url = fileURL else { throw AudioRecorderError.notRecording }
        teardownEngine()
        // Appends enqueued before teardown drain on the serial queue before this
        // sync finish. A buffer still mid-process when the tap is removed may
        // enqueue after finish(); that tail (a few ms) is dropped, which is fine
        // for dictation.
        var finishError: Error?
        writerQueue.sync {
            do {
                try self.writer?.finish()
            } catch {
                finishError = error
            }
            self.writer = nil
        }
        fileURL = nil
        if let finishError { throw finishError }
        return url
    }

    public func cancel() {
        teardownEngine()
        let url = fileURL
        writerQueue.sync {
            try? self.writer?.finish()
            self.writer = nil
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func process(buffer: AVAudioPCMBuffer,
                         converter: AVAudioConverter,
                         targetFormat: AVAudioFormat) {
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

        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if !autoStopFired,
           watchdog.observe(rms: rms, at: elapsed) || elapsed > maxDuration {
            autoStopFired = true
            onAutoStop?()
        }

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
        // Hand the converted samples to the serial queue; the WavWriter append
        // (the only file I/O) runs there, never on the real-time tap thread. The
        // speech latch is set on the same queue so didCaptureSpeech is race-free.
        writerQueue.async { [weak self] in
            if isSpeech { self?.capturedSpeech = true }
            try? self?.writer?.append(samples: samples)
        }
    }
}
