import Foundation
import NIOCore

/**
 Command to send QUIT and cleanly end the SMTP session
 */
struct QuitCommand: SMTPCommand {
    /// The result type is a simple success Boolean
	typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
	typealias HandlerType = QuitHandler
    
    /// Timeout in seconds for QUIT command (typically quick to respond)
	let timeoutSeconds: Int = 10
    
    /// Convert the command to a string that can be sent to the server
	func toCommandString() -> String {
        return "QUIT"
    }
} 
