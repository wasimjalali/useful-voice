import Foundation

/// Synthesizes the soft start/stop dictation cues and encodes them as
/// in-memory WAV data. Pure and testable; playback lives in the app layer.
/// Both cues are built from the same two notes a major third apart (C5 and
/// E5) so they read as one family: the start cue rises, the stop cue falls.
/// Tuned to soothe, not alert: a slow 35 ms swell instead of a percussive
/// attack, a long warm decay, and a faint detune chorus instead of a bright
/// harmonic.
public enum ChimeSynth {
    static let sampleRate = 44_100.0
    static let lowNote = 523.25    // C5
    static let highNote = 659.26   // E5

    public static func startChime() -> Data {
        wavData(samples: chime(frequencies: [lowNote, highNote]))
    }

    public static func stopChime() -> Data {
        wavData(samples: chime(frequencies: [highNote, lowNote], amplitude: 0.10))
    }

    /// Renders the notes in order, each with a soft swell and a long decay,
    /// overlapping generously so the pair reads as one smooth breath. Each
    /// note is two barely detuned sines, which gives a gentle chorus shimmer,
    /// plus a whisper of an octave harmonic for body.
    static func chime(frequencies: [Double],
                      noteDuration: Double = 0.26,
                      overlap: Double = 0.09,
                      amplitude: Double = 0.12) -> [Int16] {
        let noteSamples = Int(noteDuration * sampleRate)
        let stepSamples = Int((noteDuration - overlap) * sampleRate)
        let length = stepSamples * (frequencies.count - 1) + noteSamples
        var mix = [Double](repeating: 0, count: length)

        for (index, frequency) in frequencies.enumerated() {
            let offset = stepSamples * index
            for n in 0..<noteSamples {
                let t = Double(n) / sampleRate
                let value = 0.5 * sin(2 * .pi * frequency * t)
                          + 0.5 * sin(2 * .pi * frequency * 1.003 * t)
                          + 0.05 * sin(2 * .pi * frequency * 2 * t)
                mix[offset + n] += amplitude * envelope(at: t, duration: noteDuration) * value
            }
        }
        return mix.map { Int16(max(-1, min(1, $0)) * 32_767) }
    }

    /// 35 ms swell in, exponential decay, 20 ms fade out, so the cue never
    /// clicks on either edge and never sounds percussive.
    private static func envelope(at t: Double, duration: Double) -> Double {
        let rise = min(t / 0.035, 1)
        let fall = min(max(duration - t, 0) / 0.020, 1)
        return rise * fall * exp(-5 * t)
    }

    /// Standard 44-byte WAV header (PCM, mono, 16-bit) plus the samples.
    static func wavData(samples: [Int16], sampleRate: Int = 44_100) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataBytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // fmt chunk size
        append16(1)                        // PCM
        append16(1)                        // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))   // byte rate
        append16(2)                        // block align
        append16(16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(dataBytes)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
