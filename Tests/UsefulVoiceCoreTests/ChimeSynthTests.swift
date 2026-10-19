import Testing
import Foundation
@testable import UsefulVoiceCore

/// How a cue can fail: a header the player rejects, a click at either edge, clipping or a
/// cue too quiet to hear, a first sound that lags the hotkey, a tail that drags on, start
/// and stop sounding the same, left and right swapped, or macOS drifting from Windows
/// (`Tests/Fixtures/chimes/cues.json` holds the shared recipe and a loudness fingerprint).
@Suite struct ChimeSynthTests {
    static let fixture: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/chimes/cues.json")
        let data = try! Data(contentsOf: url)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    /// Interleaved stereo frames from a cue's WAV data.
    static func frames(_ data: Data) -> [(left: Int, right: Int)] {
        let samples = data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Int(Int16(littleEndian: $0)) }
        }
        return stride(from: 0, to: samples.count - 1, by: 2).map { (samples[$0], samples[$0 + 1]) }
    }

    static let cues: [(name: String, data: Data)] = [
        ("start", ChimeSynth.startChime()), ("stop", ChimeSynth.stopChime()),
    ]

    @Test func testHeaderDescribesStereo16Bit44k() {
        for (_, data) in Self.cues {
            #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
            #expect(String(decoding: data.subdata(in: 8..<12), as: UTF8.self) == "WAVE")
            let u16 = { (at: Int) in Int(data[at]) | Int(data[at + 1]) << 8 }
            let u32 = { (at: Int) in u16(at) | u16(at + 2) << 16 }
            #expect(u16(22) == 2)                    // stereo
            #expect(u32(24) == 44_100)
            #expect(u32(28) == 44_100 * 4)           // byte rate
            #expect(u16(32) == 4)                    // block align
            #expect(u16(34) == 16)
            #expect(u32(40) == data.count - 44)
            #expect(u32(4) == data.count - 8)
        }
    }

    @Test func testNoClickAtEitherEdge() {
        for (name, data) in Self.cues {
            let frames = Self.frames(data)
            for frame in [frames.first!, frames.last!] {
                #expect(abs(frame.left) < 200 && abs(frame.right) < 200, "\(name) clicks")
            }
        }
    }

    @Test func testLevelIsAudibleAndNeverClips() {
        for (name, data) in Self.cues {
            let peak = Self.frames(data).map { max(abs($0.left), abs($0.right)) }.max()!
            #expect(peak > 2_600, "\(name) is too quiet")   // above -22 dBFS
            #expect(peak < 8_200, "\(name) is too loud")    // below -12 dBFS
        }
    }

    @Test func testSoundsPromptlyAndEndsSoon() {
        for (name, data) in Self.cues {
            let frames = Self.frames(data)
            let first = frames.firstIndex { max(abs($0.left), abs($0.right)) > 300 }!
            #expect(Double(first) / 44_100 < 0.025, "\(name) lags the hotkey")
            #expect(Double(frames.count) / 44_100 <= 0.7, "\(name) drags on")
        }
    }

    @Test func testStartAndStopDiffer() {
        #expect(ChimeSynth.startChime() != ChimeSynth.stopChime())
    }

    /// The start cue's main boop sits on the right and its echo on the left.
    @Test func testStartEchoesRightThenLeft() {
        let frames = Self.frames(ChimeSynth.startChime())
        func energy(_ from: Double, _ to: Double) -> (left: Double, right: Double) {
            let slice = frames[Int(from * 44_100)..<Int(to * 44_100)]
            return (slice.reduce(0) { $0 + Double($1.left * $1.left) },
                    slice.reduce(0) { $0 + Double($1.right * $1.right) })
        }
        let boop = energy(0.14, 0.19), echo = energy(0.27, 0.32)
        #expect(boop.right > boop.left * 4)
        #expect(echo.left > echo.right * 4)
    }

    @Test func testRecipesMatchSharedFixture() {
        let recipes = Self.fixture["recipes"] as! [String: [String: Any]]
        for (name, recipe) in [("start", ChimeSynth.start), ("stop", ChimeSynth.stop)] {
            let expected = recipes[name]!
            #expect(expected["thumpStart"] as? Double == recipe.thumpStart)
            #expect(expected["thumpEnd"] as? Double == recipe.thumpEnd)
            #expect(expected["thumpDecay"] as? Double == recipe.thumpDecay)
            #expect(expected["thumpAmp"] as? Double == recipe.thumpAmp)
            #expect(expected["clickAmp"] as? Double == recipe.clickAmp)
            #expect(expected["clickDecay"] as? Double == recipe.clickDecay)
            #expect(expected["hold"] as? Double == recipe.hold)
            #expect(expected["release"] as? Double == recipe.release)
            #expect(expected["boopAmp"] as? Double == recipe.boopAmp)
            let partials = expected["partials"] as! [[String: Any]]
            #expect(partials.count == recipe.partials.count)
            for (p, e) in zip(recipe.partials, partials) {
                #expect(e["ratio"] as? Double == p.ratio)
                #expect(e["weight"] as? Double == p.weight)
                #expect(e["darkens"] as? Bool == p.darkens)
            }
            let boops = expected["boops"] as! [[String: Any]]
            #expect(boops.count == recipe.boops.count)
            for (b, e) in zip(recipe.boops, boops) {
                #expect(e["time"] as? Double == b.time)
                #expect(e["frequency"] as? Double == b.frequency)
                #expect(e["gain"] as? Double == b.gain)
                #expect(e["pan"] as? Double == b.pan)
                #expect(e["brightness"] as? Double == b.brightness)
            }
        }
    }

    /// Loudness per 20 ms block and channel, within 1 dB of the fixture both platforms share.
    @Test func testRenderMatchesSharedFingerprint() {
        let fingerprint = Self.fixture["fingerprint"] as! [String: [String: [Double]]]
        for (name, data) in Self.cues {
            let frames = Self.frames(data)
            let block = 882
            let expected = fingerprint[name]!
            for (channel, pick) in [("left", { (f: (left: Int, right: Int)) in f.left }),
                                    ("right", { (f: (left: Int, right: Int)) in f.right })] {
                let levels = stride(from: 0, to: frames.count, by: block).map { start -> Double in
                    let slice = frames[start..<min(start + block, frames.count)]
                    let mean = slice.reduce(0.0) { $0 + pow(Double(pick($1)) / 32_768, 2) } / Double(slice.count)
                    return max(-90, 10 * log10(mean + 1e-12))
                }
                #expect(levels.count == expected[channel]!.count, "\(name) \(channel) length")
                for (index, (got, want)) in zip(levels, expected[channel]!).enumerated() {
                    #expect(abs(got - want) <= 1, "\(name) \(channel) block \(index): \(got) vs \(want)")
                }
            }
        }
    }
}
