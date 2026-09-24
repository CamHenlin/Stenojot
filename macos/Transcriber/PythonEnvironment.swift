import Foundation
import TranscriberCore

struct PythonEnvironmentError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Creates the Application Support virtualenv from the Python runtime shipped in the app.
final class PythonEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func cancel() {
        lock.lock()
        process?.terminate()
        lock.unlock()
    }

    private func remember(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func ensureReady(progress: @escaping (String) -> Void) async throws {
        let python = BundledRuntime.pythonExecutable
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw PythonEnvironmentError(
                message: "The bundled Python runtime is missing. Rebuild the app so it can download Python."
            )
        }
        let requirements = BundledRuntime.requirements
        guard FileManager.default.fileExists(atPath: requirements.path) else {
            throw PythonEnvironmentError(message: "The sidecar requirements file is missing from the app.")
        }

        let venv = AppSupport.venvURL
        let venvPython = venv.appendingPathComponent("bin/python3")
        let baseMarker = venv.appendingPathComponent(".base-python")
        let depsMarker = venv.appendingPathComponent(".deps-installed")
        let requirementsText = try String(contentsOf: requirements, encoding: .utf8)
        let recordedBase = try? String(contentsOf: baseMarker, encoding: .utf8)
        let installed = (try? String(contentsOf: depsMarker, encoding: .utf8)) ?? ""
        let baseChanged = recordedBase?.trimmingCharacters(in: .whitespacesAndNewlines) != python.path
        let needsCreate = baseChanged || !FileManager.default.isExecutableFile(atPath: venvPython.path)

        if needsCreate {
            progress("Creating Python environment…")
            if FileManager.default.fileExists(atPath: venv.path) {
                try FileManager.default.removeItem(at: venv)
            }
            try AppSupport.ensureDirectory()
            try await run(python, arguments: ["-m", "venv", venv.path], progress: progress)
            try python.path.write(to: baseMarker, atomically: true, encoding: .utf8)
        }

        if needsCreate || installed != requirementsText {
            progress("Installing the transcription engine. The first run can take several minutes…")
            try await run(
                venvPython,
                arguments: ["-m", "pip", "install", "--disable-pip-version-check", "-r", requirements.path],
                progress: progress
            )
            try requirementsText.write(to: depsMarker, atomically: true, encoding: .utf8)
        }
    }

    private func run(_ executable: URL, arguments: [String], progress: @escaping (String) -> Void) async throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        remember(process)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let value = String(line)
                    if !value.isEmpty {
                        DispatchQueue.main.async {
                            progress(value)
                        }
                    }
                }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    gate.resume(continuation, result: .success(()))
                } else {
                    gate.resume(
                        continuation,
                        result: .failure(
                            PythonEnvironmentError(
                                message: "Python setup failed (\(finished.terminationStatus))."
                            )
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                gate.resume(continuation, result: .failure(error))
            }
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}

enum BundledRuntime {
    static var pythonExecutable: URL {
        Bundle.main.resourceURL!.appendingPathComponent("python/bin/python3")
    }

    static var sidecarScript: URL {
        Bundle.main.resourceURL!.appendingPathComponent("sidecar/transcriber.py")
    }

    static var requirements: URL {
        Bundle.main.resourceURL!.appendingPathComponent("sidecar/requirements-app.txt")
    }

    static var venvPython: URL {
        AppSupport.venvURL.appendingPathComponent("bin/python3")
    }
}
