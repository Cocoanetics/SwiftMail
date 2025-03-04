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
    
    /**
     Initialize a new RCPT TO command
     - Parameter recipientAddress: The email address of the recipient
     */
    public init(recipientAddress: String) {
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
        
        // Simple regex to check email format
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        guard emailPredicate.evaluate(with: recipientAddress) else {
            throw SMTPError.sendFailed("Invalid recipient email format: \(recipientAddress)")
        }
    }
} 