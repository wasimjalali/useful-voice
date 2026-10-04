import Foundation

public enum WavReadError: Error, Equatable {
    /// Not a RIFF/WAVE file at all.
    case notWav
    /// A WAV with no `data` chunk (or a truncated header).
    case noDataChunk
    /// PCM format we do not decode (only 16-bit PCM is supported).
    case unsupportedFormat
    /// The recording is not mono — local transcription needs a single channel.
    case notMono
    /// Sample rate other than the 16 kHz the engine requires.
    case unsupportedSampleRate(Int)
}

/// Reads a RIFF/WAVE file into the `Float` PCM the local engine wants.
///
/// The app's `WavWriter` always produces 16 kHz mono 16-bit PCM, and the
/// provider health probe is written by the same code, so in practice this only
/// ever sees that shape. It still parses the header properly — a retained
/// recording could come from anywhere — and refuses rather than feeding the
/// engine misdecoded audio.
public enum WavReader {
    /// The sample rate whisper.cpp is built around.
    public static let requiredSampleRate = 16_000

    /// Decodes `url` to normalized float samples in [-1, 1] at 16 kHz mono.
    public static func readFloatSamples(from url: URL) throws -> [Float] {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw WavReadError.noDataChunk
        }
        return try readFloatSamples(from: data)
    }

    /// Decodes in-memory WAV bytes. Chunk-walks the RIFF rather than assuming a
    /// fixed 44-byte header, so files with extra chunks still read.
    public static func readFloatSamples(from data: Data) throws -> [Float] {
        guard data.count >= 12,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw WavReadError.notWav
        }

        var offset = 12
        var channels: UInt16 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var audioFormat: UInt16 = 0
        var pcmRange: Range<Int>?

        while offset + 8 <= data.count {
            let idEnd = offset + 4
            let chunkID = data[offset..<idEnd]
            let chunkSize = Int(littleEndianUInt32(data, at: offset + 4))
            let chunkStart = offset + 8
            guard chunkSize >= 0, chunkStart + chunkSize <= data.count else { break }

            if chunkID.elementsEqual("fmt ".utf8), chunkSize >= 16 {
                audioFormat = littleEndianUInt16(data, at: chunkStart)
                channels = littleEndianUInt16(data, at: chunkStart + 2)
                sampleRate = littleEndianUInt32(data, at: chunkStart + 4)
                bitsPerSample = littleEndianUInt16(data, at: chunkStart + 14)
            } else if chunkID.elementsEqual("data".utf8) {
                pcmRange = chunkStart..<(chunkStart + chunkSize)
            }

            // Chunks are word-aligned: an odd size is followed by a pad byte.
            offset = chunkStart + chunkSize + (chunkSize % 2)
        }

        guard let pcmRange else { throw WavReadError.noDataChunk }
        guard audioFormat == 1, bitsPerSample == 16 else {
            throw WavReadError.unsupportedFormat
        }
        guard channels == 1 else { throw WavReadError.notMono }
        guard sampleRate == Self.requiredSampleRate else {
            throw WavReadError.unsupportedSampleRate(Int(sampleRate))
        }

        let sampleCount = pcmRange.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0..<sampleCount {
                let little = raw.load(
                    fromByteOffset: pcmRange.lowerBound + i * 2, as: Int16.self)
                samples[i] = Float(Int16(littleEndian: little)) / 32768
            }
            _ = base
        }
        return samples
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
