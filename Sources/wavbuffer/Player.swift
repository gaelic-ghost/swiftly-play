import AVFAudio
import Dispatch
import Foundation
import WAVBufferCore

private enum PlaybackError: LocalizedError {
    case invalidBufferSize
    case inconsistentFormat(expected: String, got: String)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBufferSize:
            return "Unable to allocate an AVAudioPCMBuffer for the incoming WAV data."
        case let .inconsistentFormat(expected, got):
            return "Incoming WAV buffer format \(got) does not match the active playback format \(expected)."
        case let .engineStartFailed(message):
            return "AVAudioEngine failed to start: \(message)"
        }
    }
}

// MARK: - Streamer

final class WAVStreamer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queueSemaphore: DispatchSemaphore
    private let completionGroup = DispatchGroup()

    private var activeFormat: AVAudioFormat?

    init(queueDepth: Int) {
        queueSemaphore = DispatchSemaphore(value: queueDepth)
        engine.attach(player)
    }

    func playStandardInput() throws {
        var framer = WAVStreamFramer()
        let stdin = FileHandle.standardInput

        while let chunk = try stdin.read(upToCount: 64 * 1024), !chunk.isEmpty {
            framer.append(chunk)

            while let wavData = try framer.popNextFrame() {
                try schedule(wavData: wavData)
            }
        }

        if !framer.isEmpty {
            throw WAVStreamError.unsupportedContainer
        }

        completionGroup.wait()
        player.stop()
        engine.stop()
    }

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

        queueSemaphore.wait()
        let buffer = try parsed.makePCMBuffer(with: parsedFormat)
        completionGroup.enter()

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queueSemaphore.signal()
            self?.completionGroup.leave()
        }

        if !player.isPlaying {
            player.play()
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
            throw PlaybackError.engineStartFailed(error.localizedDescription)
        }

        activeFormat = format
        return format
    }

    private func describe(_ format: AVAudioFormat) -> String {
        "\(format.commonFormat) @ \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved)"
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
