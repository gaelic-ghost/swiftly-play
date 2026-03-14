import ArgumentParser
import Foundation
import WAVBufferCore

struct WavBufferCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wavbuffer",
        abstract: "Play a streaming stdin feed of concatenated WAV buffers with AVAudioEngine."
    )

    @Option(
        name: .long,
        help: "Maximum number of scheduled WAV buffers to keep queued ahead of playback."
    )
    var queueDepth = 8

    mutating func validate() throws {
        guard queueDepth > 0 else {
            throw ValidationError("--queue-depth must be greater than zero.")
        }
    }

    mutating func run() throws {
        guard !FileHandle.standardInput.isTTY else {
            throw ValidationError("Pipe concatenated WAV buffers into stdin.")
        }

        let streamer = WAVStreamer(queueDepth: queueDepth)
        // Apple documents that connected node formats must match, so the first WAV
        // chunk establishes the stream format and later chunks are validated against it.
        try streamer.playStandardInput()
    }
}

private extension FileHandle {
    var isTTY: Bool {
        isatty(fileDescriptor) != 0
    }
}

WavBufferCommand.main()
