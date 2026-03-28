import Foundation
import XCTest
@testable import WAVBufferCore

final class ServiceStreamFramerTests: XCTestCase {
    func testParsesConfigAudioAndTerminalFrames() throws {
        let configPayload = try JSONEncoder().encode(
            ServiceStreamConfig(
                protocolVersion: 1,
                starvationTimeoutSeconds: 45,
                expectedChunkCount: 3,
                expectedSampleRate: 24_000,
                expectedChannelCount: 1
            )
        )

        var data = Data()
        data.append(frame(type: 1, payload: configPayload))
        data.append(frame(type: 2, payload: Data([1, 2, 3])))
        data.append(frame(type: 4, payload: Data("broken".utf8)))

        var framer = ServiceStreamFramer()
        framer.append(data)

        XCTAssertEqual(
            try framer.popNextRecord(),
            .config(
                ServiceStreamConfig(
                    protocolVersion: 1,
                    starvationTimeoutSeconds: 45,
                    expectedChunkCount: 3,
                    expectedSampleRate: 24_000,
                    expectedChannelCount: 1
                )
            )
        )
        XCTAssertEqual(try framer.popNextRecord(), .audioChunk(Data([1, 2, 3])))
        XCTAssertEqual(try framer.popNextRecord(), .failed("broken"))
        XCTAssertNil(try framer.popNextRecord())
    }

    func testRejectsUnknownRecordType() {
        var framer = ServiceStreamFramer()
        framer.append(frame(type: 99, payload: Data()))
        XCTAssertThrowsError(try framer.popNextRecord())
    }

    private func frame(type: UInt8, payload: Data) -> Data {
        Data("STU1".utf8) + Data([type]) + withUnsafeBytes(of: UInt32(payload.count).littleEndian) {
            Data($0)
        } + payload
    }
}
