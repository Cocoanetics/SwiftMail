import Foundation
import NIOCore


/**
 Command to send email content data
 */
struct SendContentCommand: SMTPCommand {
    /// The result type is Void since we rely on error throwing for failure cases
	typealias ResultType = Void
    
    /// The handler type that will process responses for this command
	typealias HandlerType = SendContentHandler
    
    /// The fully constructed MIME message content to send
    private let content: String
	
	/// Default timeout in seconds
	let timeoutSeconds: Int = 10
    
    /**
     Initialize a new SendContent command
     - Parameters:
        - content: The fully constructed MIME message content
     */
	init(content: String) {
        self.content = content
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        // Add terminating period on a line by itself
        return content + "\r\n."
    }
} 
