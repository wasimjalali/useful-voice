import Foundation

/// Raw mic RMS to a 0...1 visual level, then smoothed. The mapping is in dB so
/// quiet speech still moves the meter: -52 dB (and below) is 0, -16 dB is 1.
enum MicLevel {
    static func normalized(_ rms: Float) -> Double {
        let db = 20 * log10(Double(max(rms, 1e-6)))
        return min(max((db + 52) / 36, 0), 1)
    }

    /// Attack and release smoothing of the mapped level, one step per frame.
    final class Smoother {
        private(set) var value: Double = 0
        private var last: Double?

        func step(rms: Float, at time: Double) -> Double {
            let target = MicLevel.normalized(rms)
            guard let previous = last else {
                last = time
                value = target
                return value
            }
            let dt = min(max(time - previous, 0), 0.1)
            last = time
            let tau = target > value ? 0.035 : 0.160
            value += (target - value) * (1 - exp(-dt / tau))
            return value
        }
    }
}
