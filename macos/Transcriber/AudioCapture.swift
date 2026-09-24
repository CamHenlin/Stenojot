import AVFoundation
import Foundation
import QuartzCore

struct AudioCaptureError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Converts the default microphone to 16 kHz mono int16 frames of 30 ms.
final class AudioCapture {
    var onFrame: ((Data, TimeInterval) -> Void)?

    private let engine = AVAudioEngine()
    private let frameBytes = 480 * MemoryLayout<Int16>.size
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pending = Data()
    private var readOffset = 0
    private var pendingStart: TimeInterval = 0

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError(message: "Microphone is not available.")
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioCaptureError(message: "Could not create the 16 kHz audio format.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError(message: "Could not convert microphone audio to 16 kHz.")
        }
        self.converter = converter
        self.targetFormat = target
        pending.removeAll(keepingCapacity: true)
        readOffset = 0

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let sampleRate = buffer.format.sampleRate
            let duration = sampleRate > 0 ? Double(buffer.frameLength) / sampleRate : 0
            self?.consume(buffer, at: CACurrentMediaTime() - duration)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        pending.removeAll(keepingCapacity: false)
        readOffset = 0
        pendingStart = 0
    }

    private func consume(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
            return
        }

        var error: NSError?
        var didProvideInput = false
        converter.convert(to: converted, error: &error) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = converted.int16ChannelData else { return }

        let count = Int(converted.frameLength)
        guard count > 0 else { return }
        enqueue(Data(bytes: samples[0], count: count * MemoryLayout<Int16>.size), at: time)
    }

    private func enqueue(_ data: Data, at time: TimeInterval) {
        if pending.count == readOffset {
            pending.removeAll(keepingCapacity: true)
            readOffset = 0
            pendingStart = time
        } else if readOffset > 16_384 {
            pending.removeSubrange(0..<readOffset)
            readOffset = 0
        }
        pending.append(data)
        while pending.count - readOffset >= frameBytes {
            let start = readOffset
            let frame = pending.subdata(in: start..<(start + frameBytes))
            readOffset += frameBytes
            let frameTime = pendingStart
            pendingStart += 0.030
            onFrame?(frame, frameTime)
        }
    }
}
