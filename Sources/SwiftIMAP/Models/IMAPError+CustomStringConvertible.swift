import Foundation

extension IMAPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .loginFailed(let reason):
            return "Login failed: \(reason)"
        case .selectFailed(let reason):
            return "Select mailbox failed: \(reason)"
        case .fetchFailed(let reason):
            return "Fetch failed: \(reason)"
        case .logoutFailed(let reason):
            return "Logout failed: \(reason)"
        case .timeout:
            return "Operation timed out"
        case .greetingFailed(let reason):
            return "Greeting failed: \(reason)"
        case .invalidArgument(let reason):
            return "Invalid argument: \(reason)"
        case .emptyIdentifierSet:
            return "Empty identifier set provided"
        case .commandFailed(let reason):
            return "Command failed: \(reason)"
        case .copyFailed(let reason):
            return "Copy failed: \(reason)"
        case .storeFailed(let reason):
            return "Store failed: \(reason)"
        case .expungeFailed(let reason):
            return "Expunge failed: \(reason)"
        case .moveFailed(let reason):
            return "Move failed: \(reason)"
        }
    }
} 