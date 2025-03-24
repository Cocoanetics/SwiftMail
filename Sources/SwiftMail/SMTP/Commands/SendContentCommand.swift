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
    
    /// The email to send
    private let email: Email
    
    /// Whether to use 8BITMIME if available
    private let use8BitMIME: Bool
	
	/// Default timeout in seconds
	let timeoutSeconds: Int = 10
    
    /**
     Initialize a new SendContent command
     - Parameters:
        - email: The email to send
        - use8BitMIME: Whether to use 8BITMIME encoding
     */
	init(email: Email, use8BitMIME: Bool = false) {
        self.email = email
        self.use8BitMIME = use8BitMIME
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        // Construct email content and add terminating period on a line by itself
        let content = email.constructContent(use8BitMIME: use8BitMIME)
        return content + "\r\n."
    }
} 
