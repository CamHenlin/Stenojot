import Foundation

/// Files the Mac app keeps outside the bundle so a rebuild does not wipe them.
public enum AppSupport {
    public static let directoryName = "Parakeet Transcriber"

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static var databaseURL: URL {
        directory.appendingPathComponent("transcriptions.db")
    }

    public static var configURL: URL {
        directory.appendingPathComponent("config.json")
    }

    /// Hugging Face cache for MLX weights. Files here survive quitting the app.
    public static var modelsDirectory: URL {
        directory.appendingPathComponent("models", isDirectory: true)
    }

    public static var venvURL: URL {
        directory.appendingPathComponent("venv", isDirectory: true)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
