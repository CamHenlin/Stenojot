import Foundation

struct SidecarEvent: Decodable {
    var type: String
    var message: String?
    var text: String?
    var rawOutput: String?
    var timestamp: String?
    var speaker: String?

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case text
        case timestamp
        case speaker
        case rawOutput = "raw_output"
    }
}

/// Runs transcriber.py and exchanges PCM frames for JSON lines.
final class SidecarProcess: @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onStderr: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let writeQueue = DispatchQueue(label: "transcriber.sidecar.write")
    private let stateLock = NSLock()
    private var stopped = false
    private var outputBuffer = Data()
    private var errorBuffer = Data()

    /// Xcode's Run action enables the Metal debug layer. MLX hits assertions
    /// under that layer (`setBytes: bytes argument cannot be nil`), so the
    /// sidecar must not inherit those variables.
    private func sidecarEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        // Bytecode written next to the bundled stdlib changes the signed app,
        // and macOS then omits it from Screen & System Audio Recording.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        let metalKeys = environment.keys.filter { $0.hasPrefix("MTL_") || $0.hasPrefix("METAL_") }
        for key in metalKeys {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    func start(python: URL, script: URL) throws {
        process.executableURL = python
        process.arguments = [script.path]
        process.environment = sidecarEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.currentDirectoryURL = script.deletingLastPathComponent()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isError: false)
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, isError: true)
        }
        process.terminationHandler = { [weak self] process in
            self?.output.fileHandleForReading.readabilityHandler = nil
            self?.error.fileHandleForReading.readabilityHandler = nil
            self?.onExit?(process.terminationStatus)
        }
        try process.run()
    }

    func writeFrame(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let stopped = self.stopped
            self.stateLock.unlock()
            if stopped { return }
            do {
                try self.input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                // The sidecar closed the pipe.
            }
        }
    }

    func stop() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let alreadyStopped = self.stopped
            self.stopped = true
            self.stateLock.unlock()
            if alreadyStopped { return }
            try? self.input.fileHandleForWriting.close()
        }
        if process.isRunning {
            process.terminate()
        }
    }

    private func consume(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        stateLock.lock()
        if isError {
            errorBuffer.append(data)
        } else {
            outputBuffer.append(data)
        }
        let chunk = isError ? errorBuffer : outputBuffer
        let lines = splitLines(chunk)
        if isError {
            errorBuffer = lines.remainder
        } else {
            outputBuffer = lines.remainder
        }
        stateLock.unlock()

        for line in lines.complete {
            if isError {
                onStderr?(line)
            } else {
                onLine?(line)
            }
        }
    }

    private func splitLines(_ data: Data) -> (complete: [String], remainder: Data) {
        var complete: [String] = []
        var remainder = data
        while let newline = remainder.firstIndex(of: 0x0A) {
            let lineData = remainder.prefix(upTo: newline)
            remainder.removeSubrange(0...newline)
            if let text = String(data: lineData, encoding: .utf8) {
                complete.append(text)
            }
        }
        return (complete, remainder)
    }
}
