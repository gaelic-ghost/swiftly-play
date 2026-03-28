import AVFAudio
import Dispatch
import Foundation
import WAVBufferCore

enum PlaybackError: LocalizedError {
    case invalidBufferSize
    case inconsistentFormat(expected: String, got: String)
    case engineStartFailed(Error)
    case streamStarved(format: String)

    var errorDescription: String? {
        switch self {
        case .invalidBufferSize:
            return "Unable to allocate an AVAudioPCMBuffer for the incoming WAV data."
        case let .inconsistentFormat(expected, got):
            return "Incoming WAV buffer format \(got) does not match the active playback format \(expected)."
        case let .engineStartFailed(error):
            return "AVAudioEngine failed to start: \(error.localizedDescription)"
        case let .streamStarved(format):
            return "Playback drained all scheduled audio before more WAV data arrived for format \(format)."
        }
    }

    var logDetails: String? {
        switch self {
        case .invalidBufferSize, .inconsistentFormat, .streamStarved:
            return baseLogDetails
        case let .engineStartFailed(error):
            return [
                baseLogDetails,
                describeNSError(error as NSError),
            ].joined(separator: " ")
        }
    }

    private var baseLogDetails: String {
        switch self {
        case .invalidBufferSize:
            return "type=\"PlaybackError\" reason=\"invalid_buffer_size\" description=\"\(escape(errorDescription ?? "Unknown playback error."))\""
        case let .inconsistentFormat(expected, got):
            return [
                "type=\"PlaybackError\"",
                "reason=\"inconsistent_format\"",
                "expected=\"\(escape(expected))\"",
                "got=\"\(escape(got))\"",
                "description=\"\(escape(errorDescription ?? "Unknown playback error."))\"",
            ].joined(separator: " ")
        case let .engineStartFailed(error):
            return [
                "type=\"PlaybackError\"",
                "reason=\"engine_start_failed\"",
                "description=\"\(escape(errorDescription ?? "Unknown playback error."))\"",
                "underlying_type=\"\(escape(String(describing: type(of: error))))\"",
            ].joined(separator: " ")
        case let .streamStarved(format):
            return [
                "type=\"PlaybackError\"",
                "reason=\"stream_starved\"",
                "format=\"\(escape(format))\"",
                "description=\"\(escape(errorDescription ?? "Unknown playback error."))\"",
            ].joined(separator: " ")
        }
    }
}

enum StreamTerminationError: LocalizedError {
    case starvationTimeout(format: String, timeoutSeconds: Double)
    case streamFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case let .starvationTimeout(format, timeoutSeconds):
            return "Playback waited \(WAVStreamer.formatDecimal(timeoutSeconds)) seconds for more audio and timed out for format \(format)."
        case let .streamFailed(reason):
            return "Generation stream failed: \(reason)"
        }
    }

    var logDetails: String {
        switch self {
        case let .starvationTimeout(format, timeoutSeconds):
            return [
                "type=\"StreamTerminationError\"",
                "reason=\"starvation_timeout\"",
                "format=\"\(escape(format))\"",
                "timeout_seconds=\(WAVStreamer.formatDecimal(timeoutSeconds))",
                "description=\"\(escape(errorDescription ?? "Unknown stream termination error."))\"",
            ].joined(separator: " ")
        case let .streamFailed(reason):
            return [
                "type=\"StreamTerminationError\"",
                "reason=\"stream_failed\"",
                "failure_reason=\"\(escape(reason))\"",
                "description=\"\(escape(errorDescription ?? "Unknown stream termination error."))\"",
            ].joined(separator: " ")
        }
    }
}

// MARK: - Streamer

final class WAVStreamer: @unchecked Sendable {
    enum InputProtocol: Sendable {
        case wav
        case serviceV1
    }

    enum Preroll: Equatable, Sendable {
        case none
        case buffers(Int)
        case seconds(Double)

        var eventFields: [String] {
            switch self {
            case .none:
                return ["preroll=\"none\""]
            case let .buffers(count):
                return [
                    "preroll=\"buffers\"",
                    "target_buffers=\(count)",
                ]
            case let .seconds(seconds):
                return [
                    "preroll=\"seconds\"",
                    "target_seconds=\(formatDecimal(seconds))",
                ]
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queueSemaphore: DispatchSemaphore
    private let completionGroup = DispatchGroup()
    private let preroll: Preroll
    private let inputProtocol: InputProtocol
    private let state = NSCondition()
    private let stderrLock = NSLock()

    private var activeFormat: AVAudioFormat?
    private var activeFormatDescription = "uninitialized"
    private var expectedChunkCount: Int?
    private var expectedSampleRate: Double?
    private var expectedChannelCount: Int?
    private var starvationTimeoutSeconds: Double

    private var pendingFrames: [Data] = []
    private var readerError: Error?
    private var inputFinished = false
    private var queuedBuffers = 0
    private var queuedSeconds = 0.0
    private var isActivelyPlaying = false
    private var playbackHasStarted = false
    private var waitingForAudio = false
    private var starvationDeadline: Date?
    private var terminalFailure: StreamTerminationError?

    init(
        queueDepth: Int,
        preroll: Preroll,
        inputProtocol: InputProtocol,
        starvationTimeoutSeconds: Double
    ) {
        queueSemaphore = DispatchSemaphore(value: queueDepth)
        self.preroll = preroll
        self.inputProtocol = inputProtocol
        self.starvationTimeoutSeconds = starvationTimeoutSeconds
        engine.attach(player)
    }

    func playStandardInput() throws {
        defer {
            player.stop()
            engine.stop()
        }

        startReader()

        while let wavData = try nextFrame() {
            try schedule(wavData: wavData)
            startPlaybackIfNeeded(force: false, reason: "threshold_met")
        }

        startPlaybackIfNeeded(force: true, reason: "input_completed")

        completionGroup.wait()

        if let terminalFailure {
            throw terminalFailure
        }

        emitEvent("completed", extraFields: preroll.eventFields)
    }

    // MARK: Reader

    private func startReader() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readStandardInput()
        }
    }

    private func readStandardInput() {
        switch inputProtocol {
        case .wav:
            readStandardInputAsWAVChunks()
        case .serviceV1:
            readStandardInputAsServiceFrames()
        }
    }

    private func readStandardInputAsWAVChunks() {
        var framer = WAVStreamFramer()
        let stdin = FileHandle.standardInput

        do {
            while true {
                let chunk = stdin.availableData
                guard !chunk.isEmpty else {
                    break
                }

                framer.append(chunk)

                while let wavData = try framer.popNextFrame() {
                    state.lock()
                    pendingFrames.append(wavData)
                    state.signal()
                    state.unlock()
                }
            }

            if !framer.isEmpty {
                throw WAVStreamError.unsupportedContainer
            }

            state.lock()
            inputFinished = true
            state.broadcast()
            state.unlock()
        } catch {
            state.lock()
            readerError = error
            state.broadcast()
            state.unlock()
        }
    }

    private func readStandardInputAsServiceFrames() {
        var framer = ServiceStreamFramer()
        let stdin = FileHandle.standardInput

        do {
            while true {
                let chunk = stdin.availableData
                guard !chunk.isEmpty else {
                    break
                }

                framer.append(chunk)

                while let record = try framer.popNextRecord() {
                    try handleServiceRecord(record)
                }
            }

            if !framer.isEmpty {
                throw ServiceStreamError.invalidControlPayload
            }

            state.lock()
            if !inputFinished {
                inputFinished = true
            }
            state.broadcast()
            state.unlock()
        } catch {
            state.lock()
            readerError = error
            state.broadcast()
            state.unlock()
        }
    }

    private func handleServiceRecord(_ record: ServiceStreamRecord) throws {
        switch record {
        case let .config(config):
            state.lock()
            if let timeoutSeconds = config.starvationTimeoutSeconds, timeoutSeconds > 0 {
                starvationTimeoutSeconds = timeoutSeconds
            }
            expectedChunkCount = config.expectedChunkCount
            expectedSampleRate = config.expectedSampleRate
            expectedChannelCount = config.expectedChannelCount
            state.broadcast()
            state.unlock()
            var fields = ["protocol_version=\(config.protocolVersion)"]
            if let timeoutSeconds = config.starvationTimeoutSeconds {
                fields.append("starvation_timeout_seconds=\(Self.formatDecimal(timeoutSeconds))")
            }
            if let expectedChunkCount = config.expectedChunkCount {
                fields.append("expected_chunk_count=\(expectedChunkCount)")
            }
            if let expectedSampleRate = config.expectedSampleRate {
                fields.append("expected_sample_rate=\(Self.formatDecimal(expectedSampleRate))")
            }
            if let expectedChannelCount = config.expectedChannelCount {
                fields.append("expected_channel_count=\(expectedChannelCount)")
            }
            emitEvent("stream_config_received", extraFields: fields)
        case let .audioChunk(wavData):
            state.lock()
            pendingFrames.append(wavData)
            state.signal()
            state.unlock()
        case .end:
            state.lock()
            inputFinished = true
            state.broadcast()
            state.unlock()
            emitEvent("stream_end_received", extraFields: [])
        case let .failed(reason):
            state.lock()
            terminalFailure = .streamFailed(reason: reason)
            inputFinished = true
            state.broadcast()
            state.unlock()
            emitEvent("stream_failed", extraFields: ["reason=\"\(escape(reason))\""])
        }
    }

    private func nextFrame() throws -> Data? {
        state.lock()
        defer { state.unlock() }

        while pendingFrames.isEmpty, readerError == nil, !inputFinished {
            if waitingForAudio {
                let deadline = starvationDeadline ?? Date().addingTimeInterval(starvationTimeoutSeconds)
                starvationDeadline = deadline
                if !state.wait(until: deadline), pendingFrames.isEmpty, readerError == nil, !inputFinished {
                    terminalFailure = .starvationTimeout(
                        format: activeFormatDescription,
                        timeoutSeconds: starvationTimeoutSeconds
                    )
                    inputFinished = true
                    state.broadcast()
                    break
                }
                continue
            }
            state.wait()
        }

        if let readerError {
            throw readerError
        }

        if pendingFrames.isEmpty {
            return nil
        }

        return pendingFrames.removeFirst()
    }

    // MARK: Scheduling

    private func schedule(wavData: Data) throws {
        let parsed = try ParsedWAV(data: wavData)
        let parsedFormat = try parsed.makeAVAudioFormat()
        let playbackFormat = try establishPlaybackFormat(for: parsedFormat)

        guard playbackFormat.isEqual(parsedFormat) else {
            throw PlaybackError.inconsistentFormat(
                expected: describe(playbackFormat),
                got: describe(parsedFormat)
            )
        }

        if let expectedSampleRate, parsedFormat.sampleRate != expectedSampleRate {
            throw PlaybackError.inconsistentFormat(
                expected: "service-config sampleRate=\(expectedSampleRate)",
                got: describe(parsedFormat)
            )
        }

        if let expectedChannelCount, Int(parsedFormat.channelCount) != expectedChannelCount {
            throw PlaybackError.inconsistentFormat(
                expected: "service-config channels=\(expectedChannelCount)",
                got: describe(parsedFormat)
            )
        }

        let bufferDuration = Double(parsed.frameCount) / playbackFormat.sampleRate

        queueSemaphore.wait()
        let buffer = try parsed.makePCMBuffer(with: parsedFormat)
        completionGroup.enter()

        state.lock()
        queuedBuffers += 1
        queuedSeconds += bufferDuration
        state.unlock()

        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.handleBufferConsumed(duration: bufferDuration)
        }
    }

    private func establishPlaybackFormat(for format: AVAudioFormat) throws -> AVAudioFormat {
        if let activeFormat {
            return activeFormat
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            throw PlaybackError.engineStartFailed(error)
        }

        activeFormat = format
        activeFormatDescription = describe(format)
        emitEvent(
            "engine_started",
            extraFields: [
                "format=\"\(escape(activeFormatDescription))\"",
            ] + preroll.eventFields
        )
        return format
    }

    private func startPlaybackIfNeeded(force: Bool, reason: String) {
        state.lock()
        defer { state.unlock() }

        guard !isActivelyPlaying else {
            return
        }

        guard queuedBuffers > 0 else {
            return
        }

        guard force || prerollSatisfied else {
            return
        }

        player.play()
        isActivelyPlaying = true
        waitingForAudio = false
        starvationDeadline = nil

        let fields = [
            "buffered_buffers=\(queuedBuffers)",
            "buffered_seconds=\(Self.formatDecimal(queuedSeconds))",
            "reason=\"\(force ? "forced_\(reason)" : reason)\"",
            "format=\"\(escape(activeFormatDescription))\"",
        ] + preroll.eventFields
        if playbackHasStarted {
            emitEvent("playback_resumed", extraFields: fields)
        } else {
            playbackHasStarted = true
            emitEvent("playback_started", extraFields: fields)
        }
    }

    private var prerollSatisfied: Bool {
        switch preroll {
        case .none:
            return queuedBuffers > 0
        case let .buffers(count):
            let effectiveCount: Int
            if let expectedChunkCount {
                if expectedChunkCount <= 2 {
                    effectiveCount = min(count, max(1, expectedChunkCount))
                } else {
                    effectiveCount = min(count, 2, expectedChunkCount)
                }
            } else {
                effectiveCount = count
            }
            return queuedBuffers >= effectiveCount
        case let .seconds(seconds):
            return queuedSeconds >= seconds
        }
    }

    private func handleBufferConsumed(duration: Double) {
        queueSemaphore.signal()
        completionGroup.leave()

        var emittedUnderrun = false

        state.lock()
        queuedBuffers = max(0, queuedBuffers - 1)
        queuedSeconds = max(0, queuedSeconds - duration)

        if isActivelyPlaying, queuedBuffers == 0, !inputFinished, terminalFailure == nil {
            isActivelyPlaying = false
            waitingForAudio = true
            starvationDeadline = Date().addingTimeInterval(starvationTimeoutSeconds)
            emittedUnderrun = true
        }

        state.broadcast()
        state.unlock()

        if emittedUnderrun {
            emitEvent(
                "underrun",
                extraFields: [
                    "buffered_buffers=0",
                    "buffered_seconds=\(Self.formatDecimal(0))",
                    "format=\"\(escape(activeFormatDescription))\"",
                ] + preroll.eventFields
            )
            emitEvent(
                "waiting_for_audio",
                extraFields: [
                    "timeout_seconds=\(Self.formatDecimal(starvationTimeoutSeconds))",
                    "format=\"\(escape(activeFormatDescription))\"",
                ] + preroll.eventFields
            )
        }
    }

    // MARK: Logging

    private func emitEvent(_ name: String, extraFields: [String]) {
        let fields = ["event=\(name)"] + extraFields
        writeStandardError("wavbuffer " + fields.joined(separator: " "))
    }

    private func writeStandardError(_ line: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func describe(_ format: AVAudioFormat) -> String {
        "\(format.commonFormat) @ \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved)"
    }

    static func formatDecimal(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

// MARK: - Parsed WAV Conversion

private extension ParsedWAV {
    func makeAVAudioFormat() throws -> AVAudioFormat {
        let commonFormat: AVAudioCommonFormat

        switch format.encoding {
        case .pcm16:
            commonFormat = .pcmFormatInt16
        case .pcm32:
            commonFormat = .pcmFormatInt32
        case .float32:
            commonFormat = .pcmFormatFloat32
        }

        guard let audioFormat = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: true
        ) else {
            throw WAVStreamError.unsupportedEncoding(0, format.bitsPerSample)
        }

        return audioFormat
    }

    func makePCMBuffer(with audioFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw PlaybackError.invalidBufferSize
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = audioBuffer.mData else {
            throw PlaybackError.invalidBufferSize
        }

        pcmData.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: pcmData.count)
        return buffer
    }
}

// MARK: - Error Detail Helpers

private func describeNSError(_ error: NSError) -> String {
    var fields = [
        "domain=\"\(escape(error.domain))\"",
        "code=\(error.code)",
        "description=\"\(escape(error.localizedDescription))\"",
    ]

    if let failureReason = error.localizedFailureReason {
        fields.append("reason_detail=\"\(escape(failureReason))\"")
    }

    if let recoverySuggestion = error.localizedRecoverySuggestion {
        fields.append("recovery=\"\(escape(recoverySuggestion))\"")
    }

    if error.domain == NSOSStatusErrorDomain {
        let status = Int32(error.code)
        if let fourCC = fourCCString(status) {
            fields.append("osstatus_fourcc=\"\(escape(fourCC))\"")
        }

        if let meaning = commonOSStatusMeaning(status) {
            fields.append("osstatus_hint=\"\(escape(meaning))\"")
        }
    }

    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        fields.append("underlying_domain=\"\(escape(underlying.domain))\"")
        fields.append("underlying_code=\(underlying.code)")
        fields.append("underlying_description=\"\(escape(underlying.localizedDescription))\"")
    }

    return fields.joined(separator: " ")
}

private func fourCCString(_ status: Int32) -> String? {
    let bigEndian = UInt32(bitPattern: status).bigEndian
    let bytes = withUnsafeBytes(of: bigEndian) { Array($0) }

    guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
        return nil
    }

    return String(decoding: bytes, as: UTF8.self)
}

private func commonOSStatusMeaning(_ status: Int32) -> String? {
    switch status {
    case -50:
        return "Invalid parameter."
    case -10868:
        return "Audio format or channel layout is not supported by the current graph or output device."
    case 561145187:
        return "The audio engine could not start because the output hardware is unavailable."
    case 2003334207:
        return "The audio file or stream data is malformed or unsupported."
    default:
        return nil
    }
}

private func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
