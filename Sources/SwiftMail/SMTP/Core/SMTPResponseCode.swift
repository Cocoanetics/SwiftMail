import Foundation

/// Standard SMTP response codes as defined in RFC 5321
public enum SMTPResponseCode: Int {
    // 2xx - Positive Completion
    case commandOK = 250              // Requested mail action okay, completed
    case systemStatus = 211           // System status, or system help reply
    case helpMessage = 214            // Help message
    case serviceReady = 220           // Service ready
    case closingChannel = 221         // Service closing transmission channel
    case authSuccessful = 235         // Authentication successful
    case userNotLocal = 251           // User not local; will forward
    case cannotVerify = 252          // Cannot verify user, but will accept message and attempt delivery
    
    // 3xx - Positive Intermediate
    case startMailInput = 354         // Start mail input; end with <CRLF>.<CRLF>
    case authChallenge = 334          // Server challenge (AUTH)
    
    // 4xx - Transient Negative Completion
    case serviceNotAvailable = 421    // Service not available, closing transmission channel
    case mailboxBusy = 450           // Requested mail action not taken: mailbox unavailable
    case localError = 451            // Requested action aborted: local error in processing
    case insufficientStorage = 452   // Requested action not taken: insufficient system storage
    case tempAuthFailure = 454       // Temporary authentication failure
    
    // 5xx - Permanent Negative Completion
    case syntaxError = 500           // Syntax error, command unrecognized
    case syntaxErrorParams = 501     // Syntax error in parameters or arguments
    case notImplemented = 502        // Command not implemented
    case badSequence = 503          // Bad sequence of commands
    case paramNotImplemented = 504   // Command parameter not implemented
    case authRequired = 530         // Authentication required
    case authFailed = 535          // Authentication failed
    case mailboxNotFound = 550     // Requested action not taken: mailbox unavailable
    case userNotLocal551 = 551     // User not local; please try <forward-path>
    case exceededStorage = 552     // Requested mail action aborted: exceeded storage allocation
    case mailboxNameNotAllowed = 553 // Requested action not taken: mailbox name not allowed
    case transactionFailed = 554   // Transaction failed
    
    /// Whether this response code indicates success (2xx)
    public var isSuccess: Bool {
        return (200...299).contains(rawValue)
    }
    
    /// Whether this response code indicates an intermediate state (3xx)
    public var isIntermediate: Bool {
        return (300...399).contains(rawValue)
    }
    
    /// Whether this response code indicates a temporary failure (4xx)
    public var isTemporaryFailure: Bool {
        return (400...499).contains(rawValue)
    }
    
    /// Whether this response code indicates a permanent failure (5xx)
    public var isPermanentFailure: Bool {
        return (500...599).contains(rawValue)
    }
}

// Conform to CustomStringConvertible for easy debugging
extension SMTPResponseCode: CustomStringConvertible {
    public var description: String {
        let detail = switch self {
        case .commandOK: "Command okay"
        case .systemStatus: "System status"
        case .helpMessage: "Help message"
        case .serviceReady: "Service ready"
        case .closingChannel: "Service closing transmission channel"
        case .authSuccessful: "Authentication successful"
        case .userNotLocal: "User not local; will forward"
        case .cannotVerify: "Cannot verify user"
        case .startMailInput: "Start mail input"
        case .authChallenge: "Server challenge"
        case .serviceNotAvailable: "Service not available"
        case .mailboxBusy: "Mailbox busy"
        case .localError: "Local error"
        case .insufficientStorage: "Insufficient storage"
        case .tempAuthFailure: "Temporary authentication failure"
        case .syntaxError: "Syntax error"
        case .syntaxErrorParams: "Syntax error in parameters"
        case .notImplemented: "Command not implemented"
        case .badSequence: "Bad sequence of commands"
        case .paramNotImplemented: "Parameter not implemented"
        case .authRequired: "Authentication required"
        case .authFailed: "Authentication failed"
        case .mailboxNotFound: "Mailbox not found"
        case .userNotLocal551: "User not local"
        case .exceededStorage: "Exceeded storage"
        case .mailboxNameNotAllowed: "Mailbox name not allowed"
        case .transactionFailed: "Transaction failed"
        }
        return "\(rawValue) - \(detail)"
    }
} 