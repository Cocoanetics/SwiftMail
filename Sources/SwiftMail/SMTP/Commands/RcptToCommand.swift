import Foundation
import NIOCore


/**
 Command to specify a recipient of an email
 */
struct RcptToCommand: SMTPCommand {
    /// The result type is a simple success Boolean
	typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
	typealias HandlerType = RcptToHandler
    
    /// The email address of the recipient
    private let recipientAddress: String
	
	/// Default timeout in seconds
	let timeoutSeconds: Int = 10
    
    /**
     Initialize a new RCPT TO command
     - Parameter recipientAddress: The email address of the recipient
     */
	init(recipientAddress: String) throws {
        // Validate email format
        guard recipientAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid recipient address: \(recipientAddress)")
        }
        
        self.recipientAddress = recipientAddress
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        return "RCPT TO:<\(recipientAddress)>"
    }
    
    /**
     Validate that the recipient address is valid
     */
	func validate() throws {
        guard !recipientAddress.isEmpty else {
            throw SMTPError.sendFailed("Recipient address cannot be empty")
        }
        
        // Use our cross-platform email validation method
        guard recipientAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid recipient address: \(recipientAddress)")
        }
    }
} 
