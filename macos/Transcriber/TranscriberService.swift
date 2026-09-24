import AVFoundation
import Foundation
import TranscriberCore

/// Starts the sidecar after the model loads, then feeds it microphone and call audio.
@MainActor
final class TranscriberService {
    var onStatus: (String) -> Void = { _ in }
    var onStderr: (String) -> Void = { _ in }
    var onTranscription: (String, String, String, String) -> Void = { _, _, _, _ in }
    var onFailure: (String) -> Void = { _ in }

    private let microphone = AudioCapture()
    private let systemAudio = SystemAudioCapture()
    private let mixer = SpeakerMixer()
    private let mixQueue = DispatchQueue(label: "transcriber.mix")
    private let mixGate = MixGate()
    private var process: SidecarProcess?
    private var generation = 0
    private var didStartAudio = false
    private var announcedListening = false
    private var systemAudioFailure: String?

    func start(python: URL, script: URL) async {
        stop()
        let token = generation
        let granted = await Self.requestMicrophone()
        guard token == generation else { return }
        guard granted else {
            let message = "Microphone access is off. Enable it for Stenojot in System Settings."
            TranscriptionLog.error(message)
            onFailure(message)
            return
        }

        let process = SidecarProcess()
        process.onLine = { [weak self] line in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.handle(line, process: process)
            }
        }
        process.onStderr = { [weak self] line in
            TranscriptionLog.info(line)
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.onStderr(line)
            }
        }
        process.onExit = { [weak self] code in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.microphone.stop()
                self.systemAudio.stop()
                if code != 0 {
                    let message = "Transcriber exited (\(code))."
                    TranscriptionLog.error(message)
                    self.onFailure(message)
                } else {
                    TranscriptionLog.info("Transcriber stopped.")
                }
            }
        }

        do {
            TranscriptionLog.info("Starting sidecar \(python.path) \(script.path)")
            try process.start(python: python, script: script)
            self.process = process
            onStatus("Loading model…")
        } catch {
            TranscriptionLog.error("Failed to start sidecar: \(error.localizedDescription)")
            onFailure(error.localizedDescription)
        }
    }

    func stop() {
        generation += 1
        mixGate.advance()
        didStartAudio = false
        announcedListening = false
        systemAudioFailure = nil
        microphone.stop()
        systemAudio.stop()
        mixer.reset()
        process?.stop()
        process = nil
    }

    private func handle(_ line: String, process: SidecarProcess) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(SidecarEvent.self, from: data) else {
            return
        }
        switch event.type {
        case "status":
            let text = event.message ?? ""
            if text.hasPrefix("Listening") {
                announcedListening = true
                onStatus(listeningStatus(text))
            } else {
                onStatus(text)
            }
            // The sidecar no longer opens the microphone. It waits here for
            // frames, then calibrates as soon as they arrive.
            if text.contains("Waiting for audio") {
                startAudioIfNeeded(process: process)
            }
        case "transcription":
            if let text = event.text, let timestamp = event.timestamp {
                let speaker = event.speaker ?? Speaker.caller.rawValue
                onTranscription(text, event.rawOutput ?? "", timestamp, speaker)
            }
        case "error":
            let message = event.message ?? "Transcription error"
            TranscriptionLog.error(message)
            onFailure(message)
        default:
            TranscriptionLog.info(line)
        }
    }

    private func listeningStatus(_ text: String) -> String {
        systemAudioFailure ?? text
    }

    private func noteSystemAudioFailure(_ message: String) {
        guard systemAudioFailure == nil else { return }
        let status = Self.systemAudioStatus(for: message)
        systemAudioFailure = status
        TranscriptionLog.error("System audio capture failed: \(message)")
        if announcedListening {
            onStatus(status)
        }
    }

    /// Screen Recording is granted to a specific signature. A rebuilt binary can
    /// leave the Settings switch on and still be declined.
    static func systemAudioStatus(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("declined") || lowered.contains("tcc") || lowered.contains("authoriz") {
            return "Listening to you only. Turn Stenojot off and on in System Settings → Screen & System Audio Recording, then relaunch."
        }
        return "Listening to you only. System audio failed: \(message)"
    }

    private func startAudioIfNeeded(process: SidecarProcess) {
        guard !didStartAudio else { return }
        didStartAudio = true
        let token = mixGate.advance()
        let queue = mixQueue
        let mixer = mixer
        let gate = mixGate
        mixer.onFrame = { speaker, samples in
            process.writeFrame(Self.encode(speaker: speaker, samples: samples))
        }
        microphone.onFrame = { data, time in
            queue.async {
                guard gate.contains(token) else { return }
                mixer.append(data, from: .you, at: time)
            }
        }
        systemAudio.onFrame = { data, time in
            queue.async {
                guard gate.contains(token) else { return }
                mixer.append(data, from: .caller, at: time)
            }
        }
        systemAudio.onStopped = { [weak self] message in
            Task { @MainActor in
                self?.noteSystemAudioFailure(message)
            }
        }
        do {
            try microphone.start()
        } catch {
            TranscriptionLog.error("Microphone capture failed: \(error.localizedDescription)")
            onFailure(error.localizedDescription)
        }
        Task {
            do {
                try await systemAudio.start()
                TranscriptionLog.info("System audio capture started.")
            } catch {
                noteSystemAudioFailure(error.localizedDescription)
            }
        }
    }

    private static func encode(speaker: Speaker, samples: [Int16]) -> Data {
        var data = Data(capacity: 1 + samples.count * MemoryLayout<Int16>.size)
        data.append(speaker == .you ? 0 : 1)
        samples.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }
        return data
    }

    private static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private final class MixGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func advance() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }

    func contains(_ token: Int) -> Bool {
        lock.lock()
        let current = value
        lock.unlock()
        return current == token
    }
}
