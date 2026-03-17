#!/usr/bin/env swift

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let frequency = arguments.count > 0 ? Double(arguments[0]) ?? 440 : 440
let duration = arguments.count > 1 ? Double(arguments[1]) ?? 0.22 : 0.22

let wav = makePCM16Wave(
    frequency: frequency,
    duration: duration,
    sampleRate: 24_000.0,
    amplitude: 0.35
)

try FileHandle.standardOutput.write(contentsOf: wav)

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
        let envelope = min(1.0, Double(frame) / 120.0, Double(frameCount - frame) / 120.0)
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
