import XCTest
@testable import wavbuffer

final class WavBufferCommandTests: XCTestCase {
    func testQueueDepthMustBePositive() {
        XCTAssertThrowsError(try WavBufferCommand.parseAsRoot(["--queue-depth", "0"]))
    }

    func testPrerollBuffersMustBePositive() {
        XCTAssertThrowsError(try WavBufferCommand.parseAsRoot(["--preroll-buffers", "0"]))
    }

    func testPrerollSecondsMustBePositive() {
        XCTAssertThrowsError(try WavBufferCommand.parseAsRoot(["--preroll-seconds", "0"]))
    }

    func testPrerollFlagsAreMutuallyExclusive() {
        XCTAssertThrowsError(
            try WavBufferCommand.parseAsRoot([
                "--preroll-buffers", "2",
                "--preroll-seconds", "0.5",
            ])
        )
    }

    func testAcceptsBufferPrerollWithoutSeconds() throws {
        XCTAssertNoThrow(
            try WavBufferCommand.parseAsRoot([
                "--queue-depth", "4",
                "--preroll-buffers", "2",
            ])
        )
    }

    func testAcceptsSecondsPrerollWithoutBuffers() throws {
        XCTAssertNoThrow(
            try WavBufferCommand.parseAsRoot([
                "--queue-depth", "4",
                "--preroll-seconds", "0.25",
            ])
        )
    }
}
