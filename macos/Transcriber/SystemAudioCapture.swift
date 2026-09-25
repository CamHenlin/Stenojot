import AppKit
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
    private var excludedBundleIDs: Set<String> = []
    private var captureRunning = false
    private var capturedDisplayID: CGDirectDisplayID?
    private var filterGeneration = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    func start(excludingBundleIDs: Set<String>) async throws {
        stateLock.lock()
        stopped = false
        excludedBundleIDs = excludingBundleIDs
        pending.removeAll(keepingCapacity: false)
        readOffset = 0
        stateLock.unlock()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        stateLock.lock()
        let bundleIDs = excludedBundleIDs
        let cancelled = stopped
        stateLock.unlock()
        if cancelled { return }

        guard let display = content.displays.first else {
            throw AudioCaptureError(message: "No display is available for system audio.")
        }
        capturedDisplayID = display.displayID
        let excluded = Self.matchingApplications(content.applications, bundleIDs: bundleIDs)
        logExclusions(excluded, requested: bundleIDs)
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
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
        let aborted = stopped
        if !aborted {
            self.stream = stream
        }
        stateLock.unlock()
        if aborted { return }

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
        stateLock.lock()
        captureRunning = self.stream != nil && !stopped
        let applied = bundleIDs
        let latest = excludedBundleIDs
        stateLock.unlock()
        if captureRunning {
            observeRunningApps()
            if latest != applied {
                applyFilter()
            }
        }
    }

    /// Updates the apps left out of the mix. Takes effect immediately when capture is running.
    func updateExcludedBundleIDs(_ bundleIDs: Set<String>) {
        stateLock.lock()
        excludedBundleIDs = bundleIDs
        let running = captureRunning && stream != nil && !stopped
        stateLock.unlock()
        guard running else { return }
        applyFilter()
    }

    func stop() {
        stateLock.lock()
        stopped = true
        captureRunning = false
        let stream = self.stream
        self.stream = nil
        let observers = workspaceObservers
        workspaceObservers = []
        stateLock.unlock()
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
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

    private func observeRunningApps() {
        stateLock.lock()
        let alreadyWatching = !workspaceObservers.isEmpty || stopped
        stateLock.unlock()
        guard !alreadyWatching else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.refreshFilterIfIgnoredAppChanged(note)
            }
        }
        stateLock.lock()
        if stopped || !workspaceObservers.isEmpty {
            stateLock.unlock()
            for token in tokens {
                center.removeObserver(token)
            }
            return
        }
        workspaceObservers = tokens
        stateLock.unlock()
    }

    private func refreshFilterIfIgnoredAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        stateLock.lock()
        let ignored = excludedBundleIDs.contains(bundleID)
        let running = captureRunning && stream != nil && !stopped
        stateLock.unlock()
        guard ignored, running else { return }
        applyFilter()
    }

    private func applyFilter() {
        stateLock.lock()
        filterGeneration += 1
        let generation = filterGeneration
        let bundleIDs = excludedBundleIDs
        let stream = self.stream
        let displayID = capturedDisplayID
        stateLock.unlock()
        guard let stream else { return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                stateLock.lock()
                let stillCurrent = filterGeneration == generation && self.stream === stream && !stopped
                stateLock.unlock()
                guard stillCurrent else { return }
                let display = content.displays.first { $0.displayID == displayID } ?? content.displays.first
                guard let display else { return }
                let excluded = Self.matchingApplications(content.applications, bundleIDs: bundleIDs)
                let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                try await stream.updateContentFilter(filter)
                logExclusions(excluded, requested: bundleIDs)
            } catch {
                TranscriptionLog.error("Could not update ignored apps: \(error.localizedDescription)")
            }
        }
    }

    private static func matchingApplications(
        _ applications: [SCRunningApplication],
        bundleIDs: Set<String>
    ) -> [SCRunningApplication] {
        guard !bundleIDs.isEmpty else { return [] }
        var seen = Set<String>()
        return applications.filter { app in
            let id = app.bundleIdentifier
            guard bundleIDs.contains(id), seen.insert(id).inserted else { return false }
            return true
        }
    }

    private func logExclusions(_ excluded: [SCRunningApplication], requested: Set<String>) {
        guard !requested.isEmpty else { return }
        let names = excluded.map(\.applicationName).sorted()
        if names.isEmpty {
            TranscriptionLog.info("Ignored apps are not running, so none were left out of system audio.")
            return
        }
        TranscriptionLog.info("Ignoring system audio from \(names.joined(separator: ", ")).")
        let found = Set(excluded.map(\.bundleIdentifier))
        let missing = requested.subtracting(found).sorted()
        if !missing.isEmpty {
            TranscriptionLog.info("Ignored apps not available to capture yet: \(missing.joined(separator: ", ")).")
        }
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
