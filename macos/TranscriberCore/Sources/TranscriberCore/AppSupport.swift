import Foundation

/// Files the Mac app keeps outside the bundle so a rebuild does not wipe them.
public enum AppSupport {
    public static let directoryName = "Stenojot"
    /// Folder used before the app was renamed. Moved once into `directoryName`.
    private static let previousDirectoryName = "Parakeet Transcriber"

    public static var directory: URL {
        applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var previousDirectory: URL {
        applicationSupport.appendingPathComponent(previousDirectoryName, isDirectory: true)
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path),
           fileManager.fileExists(atPath: previousDirectory.path) {
            try fileManager.moveItem(at: previousDirectory, to: directory)
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
