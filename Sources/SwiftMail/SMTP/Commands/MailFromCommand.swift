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

    /// Optional RFC 1870 SIZE parameter value in octets
    private let messageSizeOctets: Int?
    
    /// Default timeout in seconds
	let timeoutSeconds: Int = 30
    
    /**
     Initialize a new MAIL FROM command
     - Parameters:
       - senderAddress: The email address of the sender
       - use8BitMIME: Whether to use 8BITMIME extension if available
       - messageSizeOctets: Optional SIZE extension value in octets
     */
	init(
        senderAddress: String,
        use8BitMIME: Bool = false,
        messageSizeOctets: Int? = nil
    ) throws {
        // Validate email format
        guard senderAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid sender address: \(senderAddress)")
        }
        
        self.senderAddress = senderAddress
        self.use8BitMIME = use8BitMIME
        self.messageSizeOctets = messageSizeOctets
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
	func toCommandString() -> String {
        var command = "MAIL FROM:<\(senderAddress)>"
        if use8BitMIME {
            command += " BODY=8BITMIME"
        }
        if let messageSizeOctets {
            command += " SIZE=\(messageSizeOctets)"
        }
        return command
    }
    
    /**
     Validate that the sender address is valid
     */
	func validate() throws {
        guard !senderAddress.isEmpty else {
            throw SMTPError.sendFailed("Sender address cannot be empty")
        }
        if let messageSizeOctets, messageSizeOctets < 0 {
            throw SMTPError.sendFailed("Message size cannot be negative")
        }
        
        // Use our cross-platform email validation method
        guard senderAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid sender address: \(senderAddress)")
        }
    }
} 
