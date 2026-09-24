import Foundation

public enum Speaker: String, Codable, Equatable, Sendable {
    case you
    case caller

    public var label: String {
        switch self {
        case .you:
            return "You"
        case .caller:
            return "Others"
        }
    }

    public static func label(for stored: String?) -> String {
        guard let stored else { return Speaker.caller.label }
        return Speaker(rawValue: stored)?.label ?? stored
    }
}
