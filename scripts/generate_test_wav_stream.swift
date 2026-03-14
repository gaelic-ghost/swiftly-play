#!/usr/bin/env swift

import Foundation

struct ToneSpec {
    let frequency: Double
    let duration: Double
}

let sampleRate = 24_000.0
let amplitude = 0.35
let tones = [
    ToneSpec(frequency: 440, duration: 0.22),
    ToneSpec(frequency: 660, duration: 0.22),
    ToneSpec(frequency: 880, duration: 0.22),
]

let stdout = FileHandle.standardOutput

for tone in tones {
    let wav = makePCM16Wave(
        frequency: tone.frequency,
        duration: tone.duration,
        sampleRate: sampleRate,
        amplitude: amplitude
    )
    try stdout.write(contentsOf: wav)
    fflush(stdout._filePointer)
    usleep(80_000)
}

private func makePCM16Wave(
    frequency: Double,
    duration: Double,
    sampleRate: Double,
    amplitude: Double
) -> Data {
    let frameCount = Int(duration * sampleRate)
    let bytesPerSample = 2
    let channelCount: UInt16 = 1
    let blockAlign = Int(channelCount) * bytesPerSample
    let byteRate = Int(sampleRate) * blockAlign

    var pcmData = Data(capacity: frameCount * blockAlign)

    for frame in 0..<frameCount {
        let position = Double(frame) / sampleRate
        let envelope = min(1.0, Double(frame) / 240.0, Double(frameCount - frame) / 240.0)
        let value = sin(2.0 * .pi * frequency * position) * amplitude * envelope
        let sample = Int16(max(-1.0, min(1.0, value)) * Double(Int16.max)).littleEndian
        withUnsafeBytes(of: sample) { pcmData.append(contentsOf: $0) }
    }

    let riffChunkSize = UInt32(36 + pcmData.count)
    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    appendLE(riffChunkSize, to: &data)
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)
    appendLE(UInt32(16), to: &data)
    appendLE(UInt16(1), to: &data)
    appendLE(channelCount, to: &data)
    appendLE(UInt32(sampleRate), to: &data)
    appendLE(UInt32(byteRate), to: &data)
    appendLE(UInt16(blockAlign), to: &data)
    appendLE(UInt16(16), to: &data)
    data.append("data".data(using: .ascii)!)
    appendLE(UInt32(pcmData.count), to: &data)
    data.append(pcmData)
    return data
}

private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private extension FileHandle {
    var _filePointer: UnsafeMutablePointer<FILE> {
        fdopen(fileDescriptor, "w")
    }
}
