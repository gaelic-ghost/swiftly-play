import Foundation

public enum ServiceStreamError: LocalizedError {
    case invalidFrameMagic
    case unknownRecordType(UInt8)
    case invalidControlPayload

    public var errorDescription: String? {
        switch self {
        case .invalidFrameMagic:
            return "Service stream frame header did not match the expected magic bytes."
        case let .unknownRecordType(rawValue):
            return "Service stream used unknown record type \(rawValue)."
        case .invalidControlPayload:
            return "Service stream control payload could not be decoded."
        }
    }
}

public struct ServiceStreamConfig: Codable, Equatable, Sendable {
    public var protocolVersion: Int = 1
    public var starvationTimeoutSeconds: Double? = nil
    public var expectedChunkCount: Int? = nil
    public var expectedSampleRate: Double? = nil
    public var expectedChannelCount: Int? = nil

    public init(
        protocolVersion: Int = 1,
        starvationTimeoutSeconds: Double? = nil,
        expectedChunkCount: Int? = nil,
        expectedSampleRate: Double? = nil,
        expectedChannelCount: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.starvationTimeoutSeconds = starvationTimeoutSeconds
        self.expectedChunkCount = expectedChunkCount
        self.expectedSampleRate = expectedSampleRate
        self.expectedChannelCount = expectedChannelCount
    }
}

public enum ServiceStreamRecord: Equatable, Sendable {
    case config(ServiceStreamConfig)
    case audioChunk(Data)
    case end
    case failed(String)
}

public struct ServiceStreamFramer {
    private static let magic = Data("STU1".utf8)
    private static let headerLength = 9

    private enum RecordType: UInt8 {
        case config = 1
        case audioChunk = 2
        case end = 3
        case failed = 4
    }

    private var storage = Data()

    public init() {}

    public var isEmpty: Bool {
        storage.isEmpty
    }

    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    public mutating func popNextRecord() throws -> ServiceStreamRecord? {
        guard storage.count >= Self.headerLength else {
            return nil
        }

        guard storage.prefix(4) == Self.magic else {
            throw ServiceStreamError.invalidFrameMagic
        }

        let rawType = storage.readUInt8(at: 4)
        guard let recordType = RecordType(rawValue: rawType) else {
            throw ServiceStreamError.unknownRecordType(rawType)
        }

        let payloadLength = Int(storage.readUInt32LE(at: 5))
        let frameLength = Self.headerLength + payloadLength
        guard storage.count >= frameLength else {
            return nil
        }

        let payload = storage.slice(at: Self.headerLength, length: payloadLength)
        storage.removeFirst(frameLength)

        switch recordType {
        case .config:
            let config = try JSONDecoder().decode(ServiceStreamConfig.self, from: payload)
            return .config(config)
        case .audioChunk:
            return .audioChunk(payload)
        case .end:
            guard payload.isEmpty else {
                throw ServiceStreamError.invalidControlPayload
            }
            return .end
        case .failed:
            guard let message = String(data: payload, encoding: .utf8) else {
                throw ServiceStreamError.invalidControlPayload
            }
            return .failed(message)
        }
    }
}

private extension DataProtocol {
    func readUInt8(at offset: Int) -> UInt8 {
        let index = self.index(startIndex, offsetBy: offset)
        return self[index]
    }
}
