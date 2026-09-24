import OSLog

/// Unified logging for the transcription engine. Visible in Console.app
/// under subsystem `com.parakeet.transcriber`.
enum TranscriptionLog {
    static let logger = Logger(subsystem: "com.parakeet.transcriber", category: "transcription")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
