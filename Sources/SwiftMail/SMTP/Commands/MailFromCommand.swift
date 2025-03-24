import Foundation
import NIOCore


/**
 Command to specify the sender of an email
 */
struct MailFromCommand: SMTPCommand {
    /// The result type is a simple success Boolean
	typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
	typealias HandlerType = MailFromHandler
    
    /// The email address of the sender
    private let senderAddress: String
    
    /// Indicates if 8BITMIME is supported and should be used
    private let use8BitMIME: Bool
    
    /// Default timeout in seconds
	let timeoutSeconds: Int = 30
    
    /**
     Initialize a new MAIL FROM command
     - Parameters:
       - senderAddress: The email address of the sender
       - use8BitMIME: Whether to use 8BITMIME extension if available
     */
	init(senderAddress: String, use8BitMIME: Bool = false) throws {
        // Validate email format
        guard senderAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid sender address: \(senderAddress)")
        }
        
        self.senderAddress = senderAddress
        self.use8BitMIME = use8BitMIME
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        if use8BitMIME {
            // Add the BODY=8BITMIME parameter when 8BITMIME is supported
            return "MAIL FROM:<\(senderAddress)> BODY=8BITMIME"
        } else {
            // Standard MAIL FROM command
            return "MAIL FROM:<\(senderAddress)>"
        }
    }
    
    /**
     Validate that the sender address is valid
     */
	func validate() throws {
        guard !senderAddress.isEmpty else {
            throw SMTPError.sendFailed("Sender address cannot be empty")
        }
        
        // Use our cross-platform email validation method
        guard senderAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid sender address: \(senderAddress)")
        }
    }
} 
