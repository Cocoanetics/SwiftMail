import Foundation
import NIOCore
import SwiftMailCore

/**
 Command to specify the sender of an email
 */
public struct MailFromCommand: SMTPCommand {
    /// The result type is a simple success Boolean
    public typealias ResultType = Bool
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = MailFromHandler
    
    /// The email address of the sender
    private let senderAddress: String
	
	/// Default timeout in seconds
	public let timeoutSeconds: Int = 30
    
    /**
     Initialize a new MAIL FROM command
     - Parameter senderAddress: The email address of the sender
     */
    public init(senderAddress: String) throws {
        // Validate email format
        guard senderAddress.isValidEmail() else {
            throw SMTPError.invalidEmailAddress("Invalid sender address: \(senderAddress)")
        }
        
        self.senderAddress = senderAddress
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
    public func toCommandString() -> String {
        return "MAIL FROM:<\(senderAddress)>"
    }
    
    /**
     Validate that the sender address is valid
     */
    public func validate() throws {
        guard !senderAddress.isEmpty else {
            throw SMTPError.sendFailed("Sender address cannot be empty")
        }
        
        // Simple regex to check email format
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        guard emailPredicate.evaluate(with: senderAddress) else {
            throw SMTPError.sendFailed("Invalid sender email format: \(senderAddress)")
        }
    }
    
    func validateResponse(_ response: SMTPResponse) throws {
        guard response.code == SMTPResponseCode.commandOK.rawValue else {
            throw SMTPError.unexpectedResponse(response)
        }
    }
} 
