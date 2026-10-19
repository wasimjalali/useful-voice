import Foundation

/// Synthesizes the start/stop dictation cues and encodes them as in-memory
/// stereo WAV data. Pure and testable; playback lives in the app layer.
/// Each cue is a soft woody tap (a low thump gliding down plus a short airy
/// click), a rounded "boop", and quieter, darker echoes of the boop about
/// every 130 ms, panned between left and right. Start boops on C5; stop is
/// lower and quieter, on G3 and B3, and leans left.
/// `windows/src/core/audio/chimeSynth.ts` renders the same recipes; both are
/// checked against `Tests/Fixtures/chimes/cues.json`.
public enum ChimeSynth {
    static let sampleRate = 44_100.0
    static let seconds = 0.62
    /// When the tap starts. Keeps the first sample silent without delaying the cue.
    static let onset = 0.006

    struct Partial {
        let ratio: Double
        let weight: Double
        /// Scaled by each boop's brightness, so later echoes lose it first.
        let darkens: Bool
    }

    struct Boop {
        let time: Double
        let frequency: Double
        let gain: Double
        /// -1 is full left, 1 full right (constant power).
        let pan: Double
        let brightness: Double
    }

    struct Recipe {
        let thumpStart: Double
        let thumpEnd: Double
        let thumpDecay: Double
        let thumpAmp: Double
        let clickAmp: Double
        let clickDecay: Double
        let hold: Double
        let release: Double
        let boopAmp: Double
        let partials: [Partial]
        let boops: [Boop]
    }

    static let start = Recipe(
        thumpStart: 240, thumpEnd: 100, thumpDecay: 0.022, thumpAmp: 0.17,
        clickAmp: 0.032, clickDecay: 0.016, hold: 0.05, release: 0.007, boopAmp: 0.12,
        partials: [Partial(ratio: 1, weight: 1, darkens: false),
                   Partial(ratio: 2, weight: 0.02, darkens: false),
                   Partial(ratio: 4.03, weight: 0.32, darkens: true)],
        boops: [Boop(time: 0.014, frequency: 523.25, gain: 0.16, pan: -0.15, brightness: 1),
                Boop(time: 0.136, frequency: 523.25, gain: 1, pan: 0.65, brightness: 0.12),
                Boop(time: 0.266, frequency: 523.25, gain: 0.2, pan: -0.65, brightness: 0.04),
                Boop(time: 0.396, frequency: 523.25, gain: 0.03, pan: 0.65, brightness: 0.01)])

    static let stop = Recipe(
        thumpStart: 280, thumpEnd: 95, thumpDecay: 0.022, thumpAmp: 0.15,
        clickAmp: 0.03, clickDecay: 0.008, hold: 0.045, release: 0.008, boopAmp: 0.12,
        partials: [Partial(ratio: 1, weight: 1, darkens: false),
                   Partial(ratio: 2, weight: 0.35, darkens: false),
                   Partial(ratio: 3, weight: 0.05, darkens: true),
                   Partial(ratio: 4.3, weight: 0.04, darkens: true)],
        boops: [Boop(time: 0.014, frequency: 196.00, gain: 0.42, pan: -0.15, brightness: 1),
                Boop(time: 0.136, frequency: 246.94, gain: 0.2, pan: -0.4, brightness: 0.3),
                Boop(time: 0.266, frequency: 196.00, gain: 0.09, pan: -0.25, brightness: 0.1),
                Boop(time: 0.396, frequency: 246.94, gain: 0.05, pan: -0.4, brightness: 0.05)])

    public static func startChime() -> Data { wavData(stereo: render(start)) }

    public static func stopChime() -> Data { wavData(stereo: render(stop)) }

    /// Interleaved left/right samples.
    static func render(_ recipe: Recipe) -> [Int16] {
        let count = Int(seconds * sampleRate)
        var left = [Double](repeating: 0, count: count)
        var right = [Double](repeating: 0, count: count)
        let onsetIndex = Int(onset * sampleRate)

        // Thump: a sine gliding down from thumpStart to thumpEnd, with a 12 ms swell,
        // a 30 ms hold, a quick decay and a faint long tail so it never ends dry.
        var phase = 0.0
        for n in onsetIndex..<count {
            let t = Double(n - onsetIndex) / sampleRate
            let frequency = recipe.thumpEnd + (recipe.thumpStart - recipe.thumpEnd) * exp(-t / 0.006)
            if n > onsetIndex { phase += 2 * .pi * frequency / sampleRate }
            let swell = t < 0.012 ? 0.5 - 0.5 * cos(.pi * t / 0.012) : 1
            let after = max(t - 0.03, 0)
            let envelope = swell * (0.92 * exp(-after / recipe.thumpDecay) + 0.08 * exp(-after / 0.16))
            let value = 0.75 * recipe.thumpAmp * envelope * sin(phase)
            left[n] += value
            right[n] += value
        }

        // Click: seeded noise band-limited to about 1-6 kHz, so it reads as a tap, not a hiss.
        let lowpass = 1 - exp(-2 * .pi * 6_000 / sampleRate)
        let highpass = 1 - exp(-2 * .pi * 1_000 / sampleRate)
        var seed: UInt32 = 0x5EED
        var smooth = 0.0, slow = 0.0
        for i in 0..<min(Int(0.05 * sampleRate), count - onsetIndex) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let raw = Double(seed) / 2_147_483_648 - 1
            smooth += lowpass * (raw - smooth)
            slow += highpass * (smooth - slow)
            let t = Double(i) / sampleRate
            let envelope = min(t / 0.001, 1) * exp(-t / recipe.clickDecay)
            let value = 0.75 * recipe.clickAmp * envelope * (smooth - slow)
            left[onsetIndex + i] += value
            right[onsetIndex + i] += value
        }

        // Boops: a 3 ms rounded attack, a flat hold, then a short exponential release.
        let attack = 0.003
        for boop in recipe.boops {
            let first = Int(boop.time * sampleRate)
            guard first < count else { continue }
            let angle = (boop.pan + 1) * .pi / 4
            let gains = (left: cos(angle), right: sin(angle))
            let weights = recipe.partials.map { $0.darkens ? $0.weight * boop.brightness : $0.weight }
            for i in 0..<(count - first) {
                let t = Double(i) / sampleRate
                let envelope: Double
                if t < attack {
                    envelope = 0.5 - 0.5 * cos(.pi * t / attack)
                } else if t > attack + recipe.hold {
                    envelope = exp(-(t - attack - recipe.hold) / recipe.release)
                    if envelope < 1e-6 { break }
                } else {
                    envelope = 1
                }
                var tone = 0.0
                for (partial, weight) in zip(recipe.partials, weights) {
                    tone += weight * sin(2 * .pi * boop.frequency * partial.ratio * t)
                }
                let value = boop.gain * recipe.boopAmp * envelope * tone
                left[first + i] += value * gains.left
                right[first + i] += value * gains.right
            }
        }

        // A 30 ms fade so the last sample is silent.
        let fade = Int(0.03 * sampleRate)
        for i in 0..<fade {
            let gain = 0.5 + 0.5 * cos(.pi * Double(i) / Double(fade))
            left[count - fade + i] *= gain
            right[count - fade + i] *= gain
        }

        var samples = [Int16]()
        samples.reserveCapacity(count * 2)
        for n in 0..<count {
            samples.append(Int16((max(-1, min(1, left[n])) * 32_767).rounded()))
            samples.append(Int16((max(-1, min(1, right[n])) * 32_767).rounded()))
        }
        return samples
    }

    /// Standard 44-byte WAV header (PCM, stereo, 16-bit) plus interleaved samples.
    static func wavData(stereo samples: [Int16], sampleRate: Int = 44_100) -> Data {
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
        append16(2)                        // stereo
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 4))   // byte rate
        append16(4)                        // block align
        append16(16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(dataBytes)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
