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
        }
    }
} 