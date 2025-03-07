import Foundation
import NIOCore
import SwiftMailCore

/**
 Command to send email content data
 */
public struct SendContentCommand: SMTPCommand {
    /// The result type is Void since we rely on error throwing for failure cases
    public typealias ResultType = Void
    
    /// The handler type that will process responses for this command
    public typealias HandlerType = SendContentHandler
    
    /// The email to send
    private let email: Email
    
    /// Whether to use 8BITMIME if available
    private let use8BitMIME: Bool
	
	/// Default timeout in seconds
	public let timeoutSeconds: Int = 10
    
    /**
     Initialize a new SendContent command
     - Parameters:
        - email: The email to send
        - use8BitMIME: Whether to use 8BITMIME encoding
     */
    public init(email: Email, use8BitMIME: Bool = false) {
        self.email = email
        self.use8BitMIME = use8BitMIME
    }
    
    /**
     Convert the command to a string that can be sent to the server
     */
    public func toCommandString() -> String {
        // Construct email content and add terminating period on a line by itself
        let content = email.constructContent(use8BitMIME: use8BitMIME)
        return content + "\r\n."
    }
    
    /**
     Validate that the email content can be constructed
     */
    public func validate() throws {
        // The email object cannot be invalid in itself due to Swift's type system,
        // but we could add additional validation here if needed in the future
    }
} 
