import ArgumentParser
import Foundation
import WAVBufferCore

private enum StderrOutput {
    static func logError(_ error: Error) {
        let details = describe(error)
        writeLine("wavbuffer event=error \(details)")
    }

    private static func describe(_ error: Error) -> String {
        if let playbackError = error as? PlaybackError, let details = playbackError.logDetails {
            return details
        }

        let nsError = error as NSError
        var fields = [
            field("type", String(describing: type(of: error))),
            field("domain", nsError.domain),
            "code=\(nsError.code)",
            field("description", nsError.localizedDescription),
        ]

        if let failureReason = nsError.localizedFailureReason {
            fields.append(field("reason", failureReason))
        }

        if let recoverySuggestion = nsError.localizedRecoverySuggestion {
            fields.append(field("recovery", recoverySuggestion))
        }

        return fields.joined(separator: " ")
    }

    private static func writeLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func field(_ key: String, _ value: String) -> String {
        "\(key)=\(quote(value))"
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

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

    @Option(
        name: .long,
        help: "Queue at least this many WAV buffers before starting playback."
    )
    var prerollBuffers: Int?

    @Option(
        name: .long,
        help: "Queue at least this many seconds of audio before starting playback."
    )
    var prerollSeconds: Double?

    mutating func validate() throws {
        guard queueDepth > 0 else {
            throw ValidationError("--queue-depth must be greater than zero.")
        }

        if let prerollBuffers, prerollBuffers <= 0 {
            throw ValidationError("--preroll-buffers must be greater than zero.")
        }

        if let prerollSeconds, prerollSeconds <= 0 {
            throw ValidationError("--preroll-seconds must be greater than zero.")
        }

        if prerollBuffers != nil, prerollSeconds != nil {
            throw ValidationError("Use either --preroll-buffers or --preroll-seconds, not both.")
        }
    }

    mutating func run() throws {
        guard !FileHandle.standardInput.isTTY else {
            throw ValidationError("Pipe concatenated WAV buffers into stdin.")
        }

        let streamer = WAVStreamer(
            queueDepth: queueDepth,
            preroll: prerollConfiguration
        )
        // Apple documents that connected node formats must match, so the first WAV
        // chunk establishes the stream format and later chunks are validated against it.
        do {
            try streamer.playStandardInput()
        } catch {
            StderrOutput.logError(error)
            throw ExitCode.failure
        }
    }

    private var prerollConfiguration: WAVStreamer.Preroll {
        if let prerollBuffers {
            return .buffers(prerollBuffers)
        }

        if let prerollSeconds {
            return .seconds(prerollSeconds)
        }

        return .none
    }
}

private extension FileHandle {
    var isTTY: Bool {
        isatty(fileDescriptor) != 0
    }
}

WavBufferCommand.main()
