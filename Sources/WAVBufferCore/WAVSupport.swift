import Foundation

public enum WAVStreamError: LocalizedError {
    case unsupportedContainer
    case unsupportedEncoding(UInt16, UInt16)
    case missingFormatChunk
    case missingDataChunk
    case truncatedFrame
    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer:
            return "Expected each stdin chunk to be a RIFF/WAVE buffer."
        case let .unsupportedEncoding(audioFormat, bitsPerSample):
            return "Unsupported WAV encoding format \(audioFormat) with \(bitsPerSample)-bit samples."
        case .missingFormatChunk:
            return "WAV buffer is missing a fmt chunk."
        case .missingDataChunk:
            return "WAV buffer is missing a data chunk."
        case .truncatedFrame:
            return "WAV data chunk does not contain a whole number of frames."
        }
    }
}

// MARK: - Framer

public struct WAVStreamFramer {
    private var storage = Data()

    public init() {}

    public var isEmpty: Bool {
        storage.isEmpty
    }

    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    public mutating func popNextFrame() throws -> Data? {
        let headerLength = 12

        while storage.count >= 4, storage.prefix(4) != Data("RIFF".utf8) {
            storage.removeFirst()
        }

        guard storage.count >= headerLength else {
            return nil
        }

        guard storage[8..<12] == Data("WAVE".utf8) else {
            throw WAVStreamError.unsupportedContainer
        }

        let payloadSize = Int(storage.readUInt32LE(at: 4))
        let totalSize = payloadSize + 8
        guard storage.count >= totalSize else {
            return nil
        }

        let frame = storage.prefix(totalSize)
        storage.removeFirst(totalSize)
        return Data(frame)
    }
}

// MARK: - WAV Parsing

public struct ParsedWAV {
    public let format: WAVPCMFormat
    public let frameCount: UInt32
    public let pcmData: Data

    public init(data: Data) throws {
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw WAVStreamError.unsupportedContainer
        }

        var cursor = 12
        var fmtChunk: WAVFormatChunk?
        var sampleData: Data?

        while cursor + 8 <= data.count {
            let chunkID = data[cursor..<(cursor + 4)]
            let chunkSize = Int(data.readUInt32LE(at: cursor + 4))
            let payloadStart = cursor + 8
            let paddedChunkSize = chunkSize + (chunkSize % 2)
            let payloadEnd = payloadStart + chunkSize
            let nextChunk = payloadStart + paddedChunkSize

            guard payloadEnd <= data.count else {
                throw WAVStreamError.unsupportedContainer
            }

            if chunkID == Data("fmt ".utf8) {
                fmtChunk = try WAVFormatChunk(data: data[payloadStart..<payloadEnd])
            } else if chunkID == Data("data".utf8) {
                sampleData = Data(data[payloadStart..<payloadEnd])
            }

            cursor = nextChunk
        }

        guard let fmtChunk else {
            throw WAVStreamError.missingFormatChunk
        }

        guard let sampleData else {
            throw WAVStreamError.missingDataChunk
        }

        let bytesPerFrame = Int(fmtChunk.blockAlign)
        guard bytesPerFrame > 0, sampleData.count % bytesPerFrame == 0 else {
            throw WAVStreamError.truncatedFrame
        }

        let frameCount = sampleData.count / bytesPerFrame
        self.frameCount = UInt32(frameCount)
        self.pcmData = sampleData
        self.format = try fmtChunk.makeAudioFormat()
    }
}

struct WAVFormatChunk {
    let audioFormat: UInt16
    let channelCount: UInt16
    let sampleRate: UInt32
    let blockAlign: UInt16
    let bitsPerSample: UInt16

    init(data: Data.SubSequence) throws {
        guard data.count >= 16 else {
            throw WAVStreamError.missingFormatChunk
        }

        audioFormat = data.readUInt16LE(at: 0)
        channelCount = data.readUInt16LE(at: 2)
        sampleRate = data.readUInt32LE(at: 4)
        blockAlign = data.readUInt16LE(at: 12)
        bitsPerSample = data.readUInt16LE(at: 14)
    }

    func makeAudioFormat() throws -> WAVPCMFormat {
        let encoding: WAVSampleEncoding

        switch (audioFormat, bitsPerSample) {
        case (1, 16):
            encoding = .pcm16
        case (1, 32):
            encoding = .pcm32
        case (3, 32):
            encoding = .float32
        default:
            throw WAVStreamError.unsupportedEncoding(audioFormat, bitsPerSample)
        }

        return WAVPCMFormat(
            encoding: encoding,
            sampleRate: Double(sampleRate),
            channelCount: channelCount,
            bitsPerSample: bitsPerSample,
            bytesPerFrame: Int(blockAlign)
        )
    }
}

public enum WAVSampleEncoding: Equatable, Sendable {
    case pcm16
    case pcm32
    case float32
}

public struct WAVPCMFormat: Equatable, Sendable, CustomStringConvertible {
    public let encoding: WAVSampleEncoding
    public let sampleRate: Double
    public let channelCount: UInt16
    public let bitsPerSample: UInt16
    public let bytesPerFrame: Int

    public init(
        encoding: WAVSampleEncoding,
        sampleRate: Double,
        channelCount: UInt16,
        bitsPerSample: UInt16,
        bytesPerFrame: Int
    ) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.bytesPerFrame = bytesPerFrame
    }

    public var description: String {
        "\(encoding) @ \(sampleRate) Hz, \(channelCount) ch, \(bitsPerSample)-bit"
    }
}

// MARK: - Data Helpers

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        let lower = UInt16(self[offset])
        let upper = UInt16(self[offset + 1]) << 8
        return lower | upper
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
