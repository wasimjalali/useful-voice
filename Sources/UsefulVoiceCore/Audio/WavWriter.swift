import Foundation

/// Streams 16-bit mono PCM to a WAV file; finish() patches the RIFF sizes.
public final class WavWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    private let sampleRate: UInt32

    public init(url: URL, sampleRate: Int = 16000) throws {
        self.sampleRate = UInt32(sampleRate)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: self.sampleRate,
                                                 dataBytes: 0))
    }

    public func append(samples: [Int16]) throws {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        dataBytes += UInt32(data.count)
    }

    public func finish() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate,
                                                 dataBytes: dataBytes))
        try handle.close()
    }

    private static func header(sampleRate: UInt32, dataBytes: UInt32) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        append(&data, UInt32(36 + dataBytes))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append(&data, UInt32(16))
        append(&data, UInt16(1))
        append(&data, channels)
        append(&data, sampleRate)
        append(&data, byteRate)
        append(&data, blockAlign)
        append(&data, bitsPerSample)
        data.append(contentsOf: "data".utf8)
        append(&data, dataBytes)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
