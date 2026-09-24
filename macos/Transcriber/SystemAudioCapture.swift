import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

/// Captures audio other apps are playing and turns it into 16 kHz mono frames.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    var onFrame: ((Data, TimeInterval) -> Void)?
    var onStopped: ((String) -> Void)?

    private let queue = DispatchQueue(label: "transcriber.system-audio")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var stopped = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var sourceKey = ""
    private var pending = Data()
    private var readOffset = 0
    private var pendingStart: TimeInterval = 0
    private let frameBytes = 480 * MemoryLayout<Int16>.size

    func start() async throws {
        stateLock.lock()
        stopped = false
        pending.removeAll(keepingCapacity: false)
        readOffset = 0
        stateLock.unlock()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError(message: "No display is available for system audio.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)

        stateLock.lock()
        let cancelled = stopped
        if !cancelled {
            self.stream = stream
        }
        stateLock.unlock()
        if cancelled { return }

        do {
            try await stream.startCapture()
        } catch {
            stateLock.lock()
            if self.stream === stream {
                self.stream = nil
            }
            stateLock.unlock()
            throw error
        }

        stateLock.lock()
        if stopped, self.stream === stream {
            self.stream = nil
            stateLock.unlock()
            stream.stopCapture { _ in }
            return
        }
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        stopped = true
        let stream = self.stream
        self.stream = nil
        stateLock.unlock()
        queue.async { [weak self] in
            self?.pending.removeAll(keepingCapacity: false)
            self?.readOffset = 0
        }
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let stopped = self.stopped
        let current = self.stream
        stateLock.unlock()
        if stopped || current !== stream { return }
        let nsError = error as NSError
        // stopCapture reports SCStreamErrorUserStopped (-3817). That is not a failure.
        if nsError.domain == SCStreamErrorDomain && nsError.code == -3817 { return }
        onStopped?(error.localizedDescription)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        stateLock.lock()
        let stopped = self.stopped
        stateLock.unlock()
        if stopped { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let sampleRate = buffer.format.sampleRate
        let duration = sampleRate > 0 ? Double(buffer.frameLength) / sampleRate : 0
        guard let data = convert(buffer) else { return }
        enqueue(data, at: CACurrentMediaTime() - duration)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }
        var asbd = basic.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let format = buffer.format
        let key = "\(format.sampleRate)-\(format.channelCount)-\(format.commonFormat.rawValue)"
        if converter == nil || sourceKey != key {
            guard let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ), let converter = AVAudioConverter(from: format, to: target) else {
                return nil
            }
            self.targetFormat = target
            self.converter = converter
            self.sourceKey = key
        }
        guard let converter, let targetFormat else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else {
            return nil
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
        guard error == nil, let samples = converted.int16ChannelData else { return nil }
        let count = Int(converted.frameLength)
        guard count > 0 else { return nil }
        return Data(bytes: samples[0], count: count * MemoryLayout<Int16>.size)
    }

    private func enqueue(_ data: Data, at time: TimeInterval) {
        if pending.count == readOffset {
            pending.removeAll(keepingCapacity: true)
            readOffset = 0
            pendingStart = time
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
