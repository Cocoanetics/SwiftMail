import Foundation
import NIOCore

/**
 Command to initiate sending email data
 */
struct DataCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    typealias HandlerType = DataHandler
	
	/// Default timeout in seconds
	let timeoutSeconds: Int = 30
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        return "DATA"
    }
} 
