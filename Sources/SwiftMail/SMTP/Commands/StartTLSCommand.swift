import Foundation
import NIOCore


/**
 Command to initiate TLS/SSL encryption on the connection
 */
struct StartTLSCommand: SMTPCommand {
    /// The result type is a simple success Boolean
	typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
	typealias HandlerType = StartTLSHandler
    
    /// Default timeout in seconds
	let timeoutSeconds: Int = 10
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        return "STARTTLS"
    }
}
