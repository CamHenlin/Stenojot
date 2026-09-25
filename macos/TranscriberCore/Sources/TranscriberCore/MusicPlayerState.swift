import Foundation

/// Playback state reported by the Music app.
public enum MusicPlayerState: Equatable, Sendable {
    case playing
    case paused
    case stopped

    public var isPlaying: Bool { self == .playing }

    /// Accepts Music's notification values (`Playing`) and AppleScript values (`playing`).
    public init?(playbackDescription: String) {
        switch playbackDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "playing":
            self = .playing
        case "paused":
            self = .paused
        case "stopped":
            self = .stopped
        default:
            return nil
        }
    }
}
