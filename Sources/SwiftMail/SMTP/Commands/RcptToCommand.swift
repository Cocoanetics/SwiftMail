import Foundation
import NIOCore


/**
 Command to specify a recipient of an email
 */
public struct RcptToCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = RcptToHandler
    
    /// The email address of the recipient
    private let recipientAddress: String
	
	/// Default timeout in seconds
	public let timeoutSeconds: Int = 10
    
    /**
     Initialize a new RCPT TO command
     - Parameter recipientAddress: The email address of the recipient
     */
    public init(recipientAddress: String) throws {
        // Validate email format
        guard recipientAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid recipient address: \(recipientAddress)")
        }
        
        self.recipientAddress = recipientAddress
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
    public func toCommandString() -> String {
        return "RCPT TO:<\(recipientAddress)>"
    }
    
    /**
     Validate that the recipient address is valid
     */
    public func validate() throws {
        guard !recipientAddress.isEmpty else {
            throw SMTPError.sendFailed("Recipient address cannot be empty")
        }
        
        // Use our cross-platform email validation method
        guard recipientAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid recipient address: \(recipientAddress)")
        }
    }
    
    func validateResponse(_ response: SMTPResponse) throws {
        guard response.code == SMTPResponseCode.commandOK.rawValue else {
            throw SMTPError.unexpectedResponse(response)
        }
    }
} 
