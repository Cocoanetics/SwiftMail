import Foundation
import NIOCore

/**
 Command to send QUIT and cleanly end the SMTP session
 */
public struct QuitCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = QuitHandler
    
    /// Timeout in seconds for QUIT command (typically quick to respond)
    public let timeoutSeconds: Int = 10
    
    /// Initialize a new QUIT command
    public init() {
        // No parameters needed for QUIT
    }
    
    /// Convert the command to a string that can be sent to the server
    public func toCommandString() -> String {
        return "QUIT"
    }
    
    /// Validation is not required for QUIT command
    public func validate() throws {
        // No validation needed for QUIT command
    }
} 